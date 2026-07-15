#!/usr/bin/env python3
"""组织层编排脚本 — 确定性状态机驱动。

三阶段调用，主 Agent 在阶段间执行 Task(role-executor) 和 BLOCKING。
所有控制流确定性，无 LLM 参与。

Usage:
  python engine/scripts/orchestrator.py --phase dispatch [--task-request <text>] [--app-path <path>]
  python engine/scripts/orchestrator.py --phase post_execute --results <json>
  python engine/scripts/orchestrator.py --phase post_confirm --decisions <json>
"""
import argparse, json, os, sys, subprocess, uuid
from datetime import datetime, timezone
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path, resolve_workspace_output, get_edge_targets, is_edge_backward
from state_io import load_state, save_state

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def output(data):
    print(json.dumps(data, ensure_ascii=False))
    sys.exit(0 if data.get("status") == "success" else 1)

def output_error(error_code, message):
    print(json.dumps({"status": "failure", "error_code": error_code, "message": message}, ensure_ascii=False))
    sys.exit(1)

# v-longrun: 可配置超时，防止长程任务中大 STATE.json 导致误判
_SCRIPT_TIMEOUT = int(os.environ.get("STATE_OP_TIMEOUT", "30"))


def _build_subprocess_env():
    """构建子进程环境变量，确保 UTF-8 编码（Windows 兼容）。"""
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    return env

def run_script(cmd):
    """运行子脚本，返回 (success, parsed_json_or_stderr)."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=_SCRIPT_TIMEOUT, encoding="utf-8", errors="replace", env=_build_subprocess_env())
        if result.returncode == 0:
            return True, json.loads(result.stdout)
        else:
            try:
                return False, json.loads(result.stdout)
            except (json.JSONDecodeError, ValueError):
                return False, {"error": result.stderr.strip() or f"exit code {result.returncode}"}
    except Exception as e:
        return False, {"error": str(e)}

# ─── 工具函数 ───
# v4.2: 所有 STATE.json 读写统一通过 state_io 模块（唯一入口）

def cache_dispatches(state_path, dispatches):
    """将 dispatches 缓存到 STATE.json，供 dispatch 阶段读取。
    
    v4.0.1 修复：追加而非覆盖。多个并行分支的 post_execute 可能先后缓存
    dispatches，覆盖写会导致先缓存的独立目标 dispatch 被后缓存的覆盖丢失。
    """
    st = load_state(state_path)
    existing = st.get("pending_dispatches") or []
    st["pending_dispatches"] = existing + dispatches
    save_state(state_path, st)

# ─── 状态转换统一 API ───

def mark_complete(state_path):
    """所有 complete 路径的唯一入口：写 terminal_state。"""
    st = load_state(state_path)
    if not st.get("terminal_state"):
        st["terminal_state"] = "completed"
        save_state(state_path, st)

def load_router_and_registry(app_path):
    """加载 ROUTER.json 和 registry.json，返回 (router_steps, registry, reg_map, step_role_map)."""
    router_path = os.path.join(app_path, "ROUTER.json")
    registry_path = os.path.join(app_path, "registry.json")
    router_steps = []
    registry = []
    if os.path.exists(router_path):
        with open(router_path, "r", encoding="utf-8-sig") as f:
            router_data = json.load(f)
        router_steps = router_data.get("steps", [])
    if os.path.exists(registry_path):
        with open(registry_path, "r", encoding="utf-8-sig") as f:
            registry = json.load(f)
    reg_map = {r["role_name"]: r for r in registry} if registry else {}
    step_role_map = {s["step"]: s["role"] for s in router_steps}
    return router_steps, registry, reg_map, step_role_map

# ─── Phase 1: dispatch（Fetch）───

def _get_completed(st):
    """获取 completed（JOIN 权威源，持久完成记录）。"""
    return st.get("completed", {})

def _get_pending_routes(st):
    """获取 pending_routes（瞬态路由信号，路由后清空）。"""
    return st.get("pending_routes", {})

def _clear_pending_routes(state_path, st):
    """清空 pending_routes（路由完成后调用）。"""
    st["pending_routes"] = {}
    save_state(state_path, st)

def _process_dispatch_pipeline(dispatches, st, app_path):
    """统一管道：converge → dedup → cross-state filter。
    所有 dispatch 生成路径必须经过此管道。
    """
    # Step 1: 全局汇集（JOIN 检查，读 completed）
    filtered = _global_converge(dispatches, st, app_path)

    # Step 2: 批内去重
    seen = set()
    unique = []
    for d in filtered:
        key = d.get("step", "")
        if key not in seen:
            seen.add(key)
            unique.append(d)

    # Step 3: 跨状态去重（排除已完成的步骤，防止重复 dispatch）
    completed_set = set(_get_completed(st).keys())
    unique = [d for d in unique if d.get("step", "") not in completed_set]

    return unique

def phase_dispatch(state_path, app_path, workspace_id, from_steps, on_result, task_request):
    """v4.1: 统一调度入口。优先读 pending_dispatches 缓存，无缓存时从 pending_routes 路由。

    v4.1 核心变更：
    - 路由信号从 pending_routes 读取（瞬态，路由后清空）
    - JOIN 判断从 completed 读取（持久，整个执行期间保留）
    - 这两个职责不再共享同一数据结构，消除多源冲突
    """

    st = load_state(state_path)

    # 1. 优先读取 pending_dispatches 缓存（零参数调度核心）
    pending = st.get("pending_dispatches")
    if pending:
        st["pending_dispatches"] = None
        save_state(state_path, st)
        dispatches = pending
        # 消费 pending_routes（瞬态信号，用完即清空）
        _clear_pending_routes(state_path, st)
        _process_dispatches(state_path, app_path, workspace_id, dispatches, from_steps or [], task_request, st)
        return

    # ── 冷路径：从 pending_routes（瞬态路由信号）出发路由 ──
    pending_routes = _get_pending_routes(st)
    if not from_steps and pending_routes:
        all_dispatches = []
        all_complete = False
        for route_step, route_data in pending_routes.items():
            route_verdict = route_data.get("verdict", "confirmed")
            router_cmd = [
                sys.executable, "engine/scripts/router.py",
                "--state-path", state_path, "--app-path", app_path,
                "--on", route_verdict,
                "--from", json.dumps([route_step]),
            ]
            if workspace_id:
                router_cmd += ["--workspace-id", workspace_id]
            if task_request:
                router_cmd += ["--task-request", task_request]
            ok, rt_result = run_script(router_cmd)
            if not ok:
                output_error("OIC-E010", f"router.py 失败: {rt_result}")
            rt_dispatches = rt_result.get("dispatch_instructions", [])
            if rt_dispatches:
                all_dispatches.extend(rt_dispatches)
            elif rt_result.get("message") == "all_complete":
                all_complete = True

        # 统一管道：converge → dedup
        all_dispatches = _process_dispatch_pipeline(all_dispatches, st, app_path)

        if not all_dispatches:
            # 清空 pending_routes（已路由完毕，无 dispatch 产出）
            _clear_pending_routes(state_path, st)
            if all_complete:
                mark_complete(state_path)
                output({"status": "success", "next": "complete", "reason": "all_complete"})
            else:
                output({"status": "success", "next": "wait", "reason": "no_dispatchable_steps"})

        # 清空 pending_routes（瞬态信号已消费完毕）
        _clear_pending_routes(state_path, st)

        _process_dispatches(state_path, app_path, workspace_id, all_dispatches, [], task_request, st)
        return

    # ── 热路径：有 from_steps 或初始调度（无 pending_routes）──
    router_cmd = [sys.executable, "engine/scripts/router.py", "--state-path", state_path, "--app-path", app_path, "--on", on_result]
    if workspace_id:
        router_cmd += ["--workspace-id", workspace_id]
    if from_steps:
        router_cmd += ["--from", json.dumps(from_steps)]
    if task_request:
        router_cmd += ["--task-request", task_request]
    ok, router_result = run_script(router_cmd)
    if not ok:
        output_error("OIC-E010", f"router.py 失败: {router_result}")

    dispatches = router_result.get("dispatch_instructions", [])
    message = router_result.get("message", "")

    # ── 全局汇集 + 去重（统一管道）──
    if dispatches and from_steps:
        dispatches = _process_dispatch_pipeline(dispatches, st, app_path)

    if not dispatches:
        if message == "all_complete":
            mark_complete(state_path)
            output({"status": "success", "next": "complete", "reason": "all_complete"})
        else:
            output({"status": "success", "next": "wait", "reason": message or "no_dispatchable_steps"})

    _process_dispatches(state_path, app_path, workspace_id, dispatches, from_steps or [], task_request, st)

def _global_converge(dispatches, st, app_path):
    """v4.1 全局汇集：读 registry 的 input_groups 判断每个候选是否满足执行条件。

    v4.1 核心变更：JOIN 判断从 completed（持久权威源）读取，而非 finished。
    completed 在整个执行期间保留，不被路由消费清除。

    规则：
    - input_groups 为空/不存在 → 无前置依赖 → 放行
    - 任一组的全部来源都在 completed 中 → 放行
    - 否则 → 等待
    """
    completed_set = set(_get_completed(st).keys())
    
    reg_path = os.path.join(app_path, "registry.json")
    if not os.path.exists(reg_path):
        return dispatches
    with open(reg_path, "r", encoding="utf-8-sig") as f:
        registry = json.load(f)
    
    # 构建 role_name → input_groups 映射，再通过 dispatch 的 role 查找
    role_input_groups = {r["role_name"]: r.get("input_groups", []) for r in registry}
    
    filtered = []
    for d in dispatches:
        groups = role_input_groups.get(d.get("role", ""), [])
        if not groups or any(set(g).issubset(completed_set) for g in groups):
            filtered.append(d)
    
    return filtered

def _process_dispatches(state_path, app_path, workspace_id, dispatches, from_steps, task_request, st=None):
    """v4.0: 统一处理 dispatch 列表。
    多 dispatch = 并行（主 Agent 同时发起多个 Task），单 dispatch = 单步。
    
    """
    if st is None:
        st = load_state(state_path)

    # 所有 dispatch 统一 set_status executing
    for d in dispatches:
        set_cmd = [
            sys.executable, "engine/scripts/set_state.py",
            "--action", "set_status",
            "--step", d["step"],
            "--status", "executing",
            "--role", d["role"],
            "--dispatch-id", d["checkpoint_id"],
            "--state-path", state_path,
        ]
        # 传递 from_steps 用于 verdict_context 运行时过滤
        if from_steps:
            set_cmd += ["--from-steps", json.dumps(from_steps)]
        ok_ss, ss_result = run_script(set_cmd)
        if not ok_ss:
            output_error("OIC-E012", f"set_state.py set_status 失败 (STEP {d['step']}): {ss_result}")

    output({
        "status": "success",
        "next": "execute",
        "dispatches": dispatches,
        "parallel": len(dispatches) > 1,
    })

# ─── Phase 2: post_execute（Gate 校验 + 路由决策）───

def phase_post_execute(state_path, app_path, workspace_id, results_json):
    """v4.0: 对每个执行结果调 gate.py → awaiting_confirmation / auto_confirm / rework / fail.
    统一逐个处理。
    """
    try:
        results = json.loads(results_json)
    except (json.JSONDecodeError, ValueError):
        output_error("OIC-E015", "--results 不是有效 JSON")

    if not isinstance(results, list):
        output_error("OIC-E015", "--results 必须是数组")

    # 加载配置
    router_steps, registry, reg_map, step_role_map = load_router_and_registry(app_path)

    pending = []
    auto_confirmed = []
    gate_results = []
    failed = []

    for r in results:
        step = r.get("step", "")
        status = r.get("status", "")
        output_paths = [o.get("path", "") for o in r.get("outputs", [])]
        # verdict 从 role-executor 返回值读取，不从产出物文件读
        role_verdict = r.get("verdict", "")

        
        if status != "confirmed":
            failed.append({"step": step, "reason": f"role-executor status={status}", "error": r.get("error")})
            continue

        for out_path in output_paths:
            if not out_path:
                continue
            # role-executor 返回的 path 已由 router 按 type 解析过，直接用
            resolved_out = out_path
            gate_cmd = [
                sys.executable, "engine/scripts/gate.py",
                "--step", step,
                "--output-path", resolved_out,
                "--state-path", state_path,
                "--app-path", app_path,
            ]
            ok_gate, gate_result = run_script(gate_cmd)
            verdict = gate_result.get("verdict", "FAIL") if ok_gate else "FAIL"

            gate_entry = {
                "step": step,
                "output_path": out_path,
                "verdict": verdict,
            }
            if gate_result.get("errors"):
                gate_entry["errors"] = gate_result["errors"]
            gate_results.append(gate_entry)

            if verdict == "PASS":
                # verdict 从 role-executor 返回值读取（与产出物格式分离）
                semantic_verdict = role_verdict

                step_def = next((s for s in router_steps if s["step"] == step), None)
                transitions = step_def.get("transitions", {}) if step_def else {}

                # fail 是系统保留词（Gate 专属），角色输出无效
                if semantic_verdict and semantic_verdict == "fail":
                    semantic_verdict = None
                effective_verdict = semantic_verdict or "confirmed"
                route_key = effective_verdict if effective_verdict in transitions else ("confirmed" if "confirmed" in transitions else None)
                if route_key is None:
                    failed.append({"step": step, "reason": f"verdict={effective_verdict} 在 transitions 中无匹配边"})
                    continue

                # 统一推进：gate PASS → advance（写入 finished + verdict）
                _role = step_role_map.get(step, "")
                blocking_mode = reg_map.get(_role, {}).get("blocking_mode", "manual")
                if blocking_mode == "auto":
                    advance_cmd = [
                        sys.executable, "engine/scripts/set_state.py",
                        "--action", "advance", "--step", step,
                        "--role", _role, "--verdict", effective_verdict,
                        "--state-path", state_path,
                    ]
                    run_script(advance_cmd)
                    auto_confirmed.append({
                        "step": step, "output_path": out_path,
                        "verdict": verdict, "route_key": route_key,
                        "errors": gate_result.get("errors", []),
                    })
                else:
                    set_cmd = [
                        sys.executable, "engine/scripts/set_state.py",
                        "--action", "set_status", "--step", step,
                        "--status", "awaiting_confirmation",
                        "--state-path", state_path,
                    ]
                    run_script(set_cmd)
                    pending.append({
                        "step": step, "output_path": out_path,
                        "verdict": verdict,
                        "errors": gate_result.get("errors", []),
                    })
            elif verdict == "FAIL":
                # Gate FAIL → advance（写入 finished），让 router 沿 fail 边找到回退目标
                _role = step_role_map.get(step, "")
                advance_cmd = [
                    sys.executable, "engine/scripts/set_state.py",
                    "--action", "advance", "--step", step,
                    "--role", _role, "--verdict", "fail",
                    "--state-path", state_path,
                ]
                run_script(advance_cmd)
                auto_confirmed.append({
                    "step": step, "output_path": out_path,
                    "verdict": "FAIL", "route_key": "fail",
                    "errors": gate_result.get("errors", []),
                })

    # v4.2: 清理 failed 步骤（Win版保留 rollback 委托方式，因 set_state.py 有 do_rollback 增强功能）
    # 僵尸 executing 的深度清理由 state_health_check.py Z1 统一接管
    for f in failed:
        reset_cmd = [
            sys.executable, "engine/scripts/set_state.py",
            "--action", "rollback",
            "--step", f["step"],
            "--state-path", state_path,
        ]
        run_script(reset_cmd)

    # error 最高优先级：只要有 failed 就报 error
    if failed:
        output({"status": "success", "next": "error", "failed": failed, "gate_results": gate_results})

    # 统一路径：所有 auto_confirmed 的 step → 调 router → _global_converge → 缓存
    if auto_confirmed and not pending:
        all_dispatches = []
        all_complete = False
        seen_steps = set()
        for ac in auto_confirmed:
            if ac["step"] in seen_steps:
                continue
            seen_steps.add(ac["step"])
            route_key = ac.get("route_key", "confirmed")
            router_cmd = [
                sys.executable, "engine/scripts/router.py",
                "--from", json.dumps([ac["step"]]),
                "--on", route_key,
                "--state-path", state_path,
                "--app-path", app_path,
            ]
            if workspace_id:
                router_cmd += ["--workspace-id", workspace_id]
            ok_rt, rt_result = run_script(router_cmd)
            rt_dispatches = rt_result.get("dispatch_instructions", [])
            rt_message = rt_result.get("message", "")
            if rt_dispatches:
                rt_st = load_state(state_path)
                rt_dispatches = _global_converge(rt_dispatches, rt_st, app_path)
            if rt_dispatches:
                all_dispatches.extend(rt_dispatches)
            elif rt_message == "all_complete":
                all_complete = True

        if all_dispatches:
            cache_dispatches(state_path, all_dispatches)
            output({"status": "success", "next": "dispatch",
                    "auto_confirmed": auto_confirmed, "gate_results": gate_results, "failed": failed})
        elif all_complete:
            mark_complete(state_path)
            output({"status": "success", "next": "complete",
                    "auto_confirmed": auto_confirmed, "gate_results": gate_results, "failed": failed})
        else:
            st = load_state(state_path)
            if st.get("terminal_state"):
                output({"status": "success", "next": "complete",
                        "reason": f"terminal_state={st['terminal_state']}",
                        "auto_confirmed": auto_confirmed, "gate_results": gate_results, "failed": failed})
            output({"status": "success", "next": "wait",
                    "reason": "no_dispatchable_steps",
                    "auto_confirmed": auto_confirmed, "gate_results": gate_results, "failed": failed})

    # 有 pending → BLOCKING
    output({
        "status": "success",
        "next": "confirm",
        "pending": pending,
        "auto_confirmed": auto_confirmed,
        "gate_results": gate_results,
        "failed": failed,
    })

# ─── Phase 3: post_confirm（Write-back）───

def phase_post_confirm(state_path, app_path, workspace_id, decisions_json):
    """v4.0: confirmed → advance；rejected → rollback → 缓存 dispatches.
    
    """
    try:
        decisions = json.loads(decisions_json)
    except (json.JSONDecodeError, ValueError):
        output_error("OIC-E015", "--decisions 不是有效 JSON")

    if not isinstance(decisions, list):
        output_error("OIC-E015", "--decisions 必须是数组")

    router_steps, _, _, step_role_map = load_router_and_registry(app_path)

    # 用户决策 = verdict：confirmed 走 advance，fail 也走 advance（统一推进）
    advance_steps = []
    for d in decisions:
        step = d.get("step", "")
        decision = d.get("decision", "")
        verdict = "confirmed" if decision == "confirmed" else "fail"
        _role = step_role_map.get(step, "")
        advance_cmd = [
            sys.executable, "engine/scripts/set_state.py",
            "--action", "advance", "--step", step,
            "--role", _role, "--verdict", verdict,
            "--state-path", state_path,
        ]
        run_script(advance_cmd)
        advance_steps.append({"step": step, "verdict": verdict})

    if not advance_steps:
        output({"status": "success", "next": "dispatch"})

    # 统一路径：所有 advance 的 step → 调 router → _global_converge → 缓存
    all_dispatches = []
    all_complete = False
    for a in advance_steps:
        router_cmd = [
            sys.executable, "engine/scripts/router.py",
            "--from", json.dumps([a["step"]]),
            "--on", a["verdict"],
            "--state-path", state_path,
            "--app-path", app_path,
        ]
        if workspace_id:
            router_cmd += ["--workspace-id", workspace_id]
        ok_rt, rt_result = run_script(router_cmd)
        rt_dispatches = rt_result.get("dispatch_instructions", [])
        rt_message = rt_result.get("message", "")
        if rt_dispatches:
            rt_st = load_state(state_path)
            rt_dispatches = _global_converge(rt_dispatches, rt_st, app_path)
        if rt_dispatches:
            all_dispatches.extend(rt_dispatches)
        elif rt_message == "all_complete":
            all_complete = True

    if all_dispatches:
        cache_dispatches(state_path, all_dispatches)
        output({"status": "success", "next": "dispatch"})
    elif all_complete:
        mark_complete(state_path)
        output({"status": "success", "next": "complete"})
    else:
        output({"status": "success", "next": "wait", "reason": "no_dispatchable_steps"})

# ─── main ───

def main():
    parser = argparse.ArgumentParser(description="组织层编排脚本（微码 v4.0 去 join 化）")
    parser.add_argument("--phase", required=True, choices=["dispatch", "post_execute", "post_confirm"])
    parser.add_argument("--from", dest="from_steps", default="", help="dispatch: JSON array of completed STEP IDs")
    parser.add_argument("--on", default="confirmed", help="dispatch: 路由 key")
    parser.add_argument("--task-request", default="", help="dispatch: 用户需求文本")
    parser.add_argument("--results", default="[]", help="post_execute: role-executor 执行结果 JSON")
    parser.add_argument("--decisions", default="[]", help="post_confirm: 用户决策 JSON")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--app-path", default=None, help="应用包路径")
    parser.add_argument("--workspace-id", default=None, help="Session ID")
    args = parser.parse_args()

    app_path = resolve_app_path(args.workspace_id, args.app_path)
    state_path = resolve_ws_state(args.workspace_id)

    if args.phase == "dispatch":
        from_list = json.loads(args.from_steps) if args.from_steps else None
        phase_dispatch(state_path, app_path, args.workspace_id, from_list, args.on, args.task_request)
    elif args.phase == "post_execute":
        phase_post_execute(state_path, app_path, args.workspace_id, args.results)
    elif args.phase == "post_confirm":
        phase_post_confirm(state_path, app_path, args.workspace_id, args.decisions)

if __name__ == "__main__":
    main()
