#!/usr/bin/env python3
"""组织层编排脚本 — 确定性状态机驱动。

三阶段调用，主 Agent 在阶段间执行 Task(role-executor) 和 BLOCKING。
所有控制流确定性，无 LLM 参与。

Usage:
  python engine/scripts/orchestrator.py --phase dispatch [--task-request <text>] [--app-path <path>]
  python engine/scripts/orchestrator.py --phase post_execute --results <json>
  python engine/scripts/orchestrator.py --phase post_confirm --decisions <json>
"""
import argparse, json, os, sys, subprocess, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path, resolve_workspace_output, get_edge_targets, is_edge_backward
from state_io import load_state, save_state, state_txn
from engine_common import output, output_error, now_iso, load_router_registry_cached

# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# v-longrun: 可配置超时，防止长程任务中大 STATE.json 导致误判
_SCRIPT_TIMEOUT = int(os.environ.get("STATE_OP_TIMEOUT", "30"))

def run_script(cmd):
    """运行子脚本，返回 (success, parsed_json_or_stderr)."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=_SCRIPT_TIMEOUT,
                                encoding="utf-8", errors="replace",
                                env={**os.environ, "PYTHONIOENCODING": "utf-8"})
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

# post_execute / post_confirm 不再调 router + cache，advance 后直接返回 next: dispatch，
# 由下一次 --next 统一从 pending_routes 走单一冷路径路由。

# ─── 状态转换统一 API ───

def mark_complete(state_path, app_path=None):
    """所有 complete 路径的唯一入口：写 terminal_state。

    完成判定由 orchestrator 全局决策：
    - 冷路径：所有 pending_routes 的 verdict 边都无 candidates（has_candidates=False）
      且无 dispatch 产出且无执行中步骤 → 全局终态。
    - 热路径：from_steps 的 verdict 边无 candidates → 路径终态。
    router.py 只提供 has_candidates 事实，不做终态判定。
    """
    with state_txn(state_path) as st:
        if st.get("terminal_state"):
            return  # 已终态，幂等
        st["terminal_state"] = "completed"

def load_router_and_registry(app_path):
    """加载 ROUTER.json 和 registry.json，返回 (router_steps, registry, reg_map, step_role_map)."""
    _cached = load_router_registry_cached(app_path)
    router_data = _cached.get("router", {})
    registry = _cached.get("registry", [])
    router_steps = router_data.get("steps", [])
    reg_map = {r["role_name"]: r for r in registry} if registry else {}
    step_role_map = {s["step"]: s["role"] for s in router_steps}
    return router_steps, registry, reg_map, step_role_map

# ─── Phase 1: dispatch（Fetch）───

def _get_pending_routes(st):
    """获取 pending_routes（瞬态路由信号，路由后清空）。"""
    return st.get("pending_routes", {})

def _clear_pending_routes(state_path):
    """清空 pending_routes（路由完成后调用）。
    使用 state_txn 读取最新 state 后清除，避免陈旧引用覆写子进程的并发更新。
    """
    with state_txn(state_path) as st:
        st["pending_routes"] = {}

def _dedup_dispatches(dispatches):
    """批内去重。JOIN 判断由 router.py 唯一负责（冗余的 _global_converge 已删除）。"""
    seen = set()
    unique = []
    for d in dispatches:
        key = d.get("step", "")
        if key not in seen:
            seen.add(key)
            unique.append(d)
    return unique

def _dispatch_from_pending_routes(state_path, app_path, workspace_id, task_request, st, pending_routes):
    """冷路径：从 pending_routes 出发逐路由由。

    逐条清除：只清除被成功路由产出 dispatch 的 route_step，
    JOIN 未满足的 route_step 保留（等待其他前驱到达）。
    """
    all_dispatches = []
    consumed_routes = []   # 已产出 dispatch 或无 candidates 的 route_step（将被清除）
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
        has_candidates = rt_result.get("has_candidates", True)
        rt_message = rt_result.get("message", "")
        if rt_dispatches:
            all_dispatches.extend(rt_dispatches)
            consumed_routes.append(route_step)    # 成功路由，标记消费
        elif rt_message == "route_failed":
            # from_step 不存在于 ROUTER.json — STATE 不一致，不消费，不判定终态
            pass
        elif not has_candidates:
            # verdict 边无 targets → 这条路径到终点，消费 route_step
            consumed_routes.append(route_step)
        # else: 有 candidates 但被 JOIN/executing 过滤 → 不消费，等待

    all_dispatches = _dedup_dispatches(all_dispatches)

    if not all_dispatches:
        # 全局终态判定：所有 route_step 都被消费（无 candidates）且无 dispatch 产出
        remaining_routes = set(pending_routes.keys()) - set(consumed_routes)
        if not remaining_routes:
            # 所有路径都到终点，确认无执行中步骤
            check_st = load_state(state_path)
            if not check_st.get("step_status"):
                _clear_selected_routes(state_path, consumed_routes)
                mark_complete(state_path, app_path)
                output({"status": "success", "next": "complete", "reason": "all_paths_terminated"})
        # 非终态 → 诊断等待原因
        _clear_selected_routes(state_path, consumed_routes)
        diag_st = load_state(state_path)
        reason, is_error = _diagnose_wait_reason(diag_st, app_path)
        next_val = "error" if is_error else "wait"
        if is_error:
            _clear_pending_routes(state_path)
            _mark_engine_error(state_path, reason)
        output({"status": "success", "next": next_val, "reason": reason})
    # 清除已消费的 route_step（成功路由产出 dispatch 的）
    _clear_selected_routes(state_path, consumed_routes)

    _process_dispatches(state_path, app_path, workspace_id, all_dispatches, [], task_request)


def _dispatch_from_steps(state_path, app_path, workspace_id, from_steps, on_result, task_request):
    """热路径：有 from_steps 或初始调度（无 pending_routes）。"""
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
    has_candidates = router_result.get("has_candidates", True)

    st = load_state(state_path)
    if dispatches and from_steps:
        dispatches = _dedup_dispatches(dispatches)

    if not dispatches:
        message = router_result.get("message", "")
        if message == "route_failed":
            # from_step 不存在于 ROUTER.json — STATE 不一致
            reason = router_result.get("reason", "route_failed")
            _mark_engine_error(state_path, reason)
            output({"status": "success", "next": "error", "reason": reason})
        if not has_candidates:
            # verdict 边无 targets → 这条路径到终点，确认无执行中步骤
            check_st = load_state(state_path)
            if not check_st.get("step_status"):
                mark_complete(state_path, app_path)
                output({"status": "success", "next": "complete", "reason": "path_terminated"})
            output({"status": "success", "next": "wait", "reason": "分支执行中"})
        else:
            diag_st = load_state(state_path)
            reason, is_error = _diagnose_wait_reason(diag_st, app_path)
            next_val = "error" if is_error else "wait"
            if is_error:
                _mark_engine_error(state_path, reason)
            output({"status": "success", "next": next_val, "reason": reason})

    _process_dispatches(state_path, app_path, workspace_id, dispatches, from_steps or [], task_request)


def phase_dispatch(state_path, app_path, workspace_id, from_steps, on_result, task_request):
    """单一路径调度入口。根据 pending_routes 是否非空分发到冷/热路径。"""
    st = load_state(state_path)
    pending_routes = _get_pending_routes(st)
    if not from_steps and pending_routes:
        _dispatch_from_pending_routes(state_path, app_path, workspace_id, task_request, st, pending_routes)
        return
    _dispatch_from_steps(state_path, app_path, workspace_id, from_steps, on_result, task_request)

def _clear_selected_routes(state_path, consumed_routes):
    """逐条清除已消费的 pending_routes（仅删除 consumed_routes 中的 key）。"""
    if not consumed_routes:
        return
    with state_txn(state_path) as st:
        pr = st.get("pending_routes", {})
        for step in consumed_routes:
            pr.pop(step, None)
        st["pending_routes"] = pr


def _find_last_good_step(st):
    """从 completed 中找到最后一个 confirmed verdict 的步骤名。

    用于在引擎报错时给用户建议 jump 目标。
    """
    completed = st.get("completed", {})
    if not completed:
        return None
    confirmed_steps = [
        (step, info.get("created_at", ""))
        for step, info in completed.items()
        if info.get("verdict") == "confirmed"
    ]
    if not confirmed_steps:
        all_steps = [(step, info.get("created_at", "")) for step, info in completed.items()]
        if not all_steps:
            return None
        return sorted(all_steps, key=lambda x: x[1])[-1][0]
    return sorted(confirmed_steps, key=lambda x: x[1])[-1][0]


def _mark_engine_error(state_path, reason):
    """引擎出错时在 STATE.json 中写入 error 标志位。

    用于：
    1. 排查问题：记录引擎最后一次出错的详细原因
    2. 快照联动：下次 advance 生成快照时会自动携带此标志，
       使快照同时具备 jump 还原和问题排查两个功能。
    """
    try:
        with state_txn(state_path) as st:
            st["engine_error"] = {
                "reason": reason,
                "timestamp": now_iso(),
                "last_good_step": _find_last_good_step(st),
            }
    except Exception:
        pass


def _diagnose_wait_reason(st, app_path):
    """当引擎无 dispatch 产出时，诊断具体原因。

    引擎是 STATE 合法性的唯一裁判。此函数将模糊的 no_dispatchable_steps
    转化为用户可理解的明确原因，替代外部 health_check 预测层。

    返回 (reason_str, is_error)。
    is_error=False 表示正常等待（JOIN 未满足），is_error=True 表示 STATE 可能不一致。
    """
    completed = set(st.get("completed", {}).keys()) | set(st.get("pending_routes", {}).keys())
    pending_routes = st.get("pending_routes", {})
    step_status = st.get("step_status", {})

    # 加载 ROUTER + registry
    try:
        _cached = load_router_registry_cached(app_path)
        router_steps = _cached.get("router", {}).get("steps", [])
        registry = _cached.get("registry", [])
    except Exception:
        router_steps = []
        registry = []

    role_input_groups = {r["role_name"]: r.get("input_groups", []) for r in (registry or [])}


    # Case 2: step_status 非空 → 有分支正在执行
    if step_status:
        steps = list(step_status.keys())
        return (f"分支执行中: {steps}", False)

    # Case 3: 扫描 JOIN 等待 — 存在步骤其部分前驱已完成但未全部满足
    join_waiters = []
    for step_data in router_steps:
        step_name = step_data.get("step", "")
        if step_name in completed:
            continue
        role = step_data.get("role", "")
        groups = role_input_groups.get(role, [])
        for group in groups:
            missing = [s for s in group if s not in completed]
            done = [s for s in group if s in completed]
            if missing and done:
                join_waiters.append(f"{step_name} 等待前驱完成: 缺 {missing} (已有 {done})")

    if join_waiters:
        return ("JOIN 等待: " + "; ".join(join_waiters), False)

    # Case 4: pending_routes 存在但路由无产出
    # 区分两种情况：
    #   (a) verdict 边有目标但被 JOIN/executing 过滤 → 正常等待（is_error=False）
    #   (b) verdict 边无匹配 transition → STATE 不一致（is_error=True）
    if pending_routes:
        steps_map_diag = {s.get("step", ""): s for s in router_steps}
        has_valid_targets = False
        for route_step, route_data in pending_routes.items():
            route_verdict = route_data.get("verdict", "confirmed")
            step_def = steps_map_diag.get(route_step, {})
            edge = step_def.get("transitions", {}).get(route_verdict, {})
            if isinstance(edge, dict) and edge.get("targets"):
                has_valid_targets = True
                break

        route_steps = list(pending_routes.keys())
        if has_valid_targets:
            # verdict 边有目标，只是 JOIN 未满足或被 executing 过滤
            return (f"JOIN 等待中: {route_steps} 有目标但未满足 JOIN 条件", False)

        # verdict 无匹配 transition → 真正的 STATE 不一致
        last_good = _find_last_good_step(st)
        suggest = f"建议 jump 到 '{last_good}'" if last_good else ""
        return (f"路由信号存在 ({route_steps}) 但 verdict 无匹配 transition。{suggest}", True)

    # Case 5: 无任何信号且未终态 → STATE 可能不一致
    last_good = _find_last_good_step(st)
    suggest = f"建议 jump 到 '{last_good}'" if last_good else ""
    dispatch_log = st.get("dispatch_log", [])
    log_summary = ""
    if dispatch_log:
        last_round = dispatch_log[-1]
        log_summary = f" 最后分发(round {last_round['round']}): {last_round['steps']}"
    return (f"无路由信号，已完成 {len(completed)} 步。{log_summary}{suggest}。", True)

def _process_dispatches(state_path, app_path, workspace_id, dispatches, from_steps, task_request):
    """统一处理 dispatch 列表。
    多 dispatch = 并行（主 Agent 同时发起多个 Task），单 dispatch = 单步。

    记录 dispatch_log 到 STATE.json，用于排查问题和还原并行批次。
    在同一 state_txn 内原子写入 step_status 和 active_dispatches，
    消除 set_status（子进程）与 active_dispatches 缓存之间的崩溃间隙。
    """
    with state_txn(state_path) as st:
        ss = st.setdefault("step_status", {})
        active = st.get("active_dispatches") or {}
        dispatch_steps = []
        for d in dispatches:
            entry = {
                "role": d["role"],
                "status": "executing",
                "dispatch_id": d["checkpoint_id"],
                "started_at": now_iso(),
            }
            if from_steps:
                entry["from_steps"] = from_steps
            ss[d["step"]] = entry
            active[d["step"]] = d
            dispatch_steps.append(d["step"])
        st["active_dispatches"] = active

        log = st.setdefault("dispatch_log", [])
        log.append({
            "round": len(log) + 1,
            "steps": dispatch_steps,
            "parallel": len(dispatches) > 1,
            "from_steps": from_steps or [],
            "timestamp": now_iso(),
        })

    output({
        "status": "success",
        "next": "execute",
        "dispatches": dispatches,
        "parallel": len(dispatches) > 1,
    })

def _check_required_files(app_path, role_name, workspace_id, state_path=None):
    """检查 schema.json 中声明的 _required_files 是否全部存在于磁盘。

    返回缺失文件列表 [{name, path}]。模板路径（含 {）跳过。
    """
    missing = []
    schema_dir = re.sub(r'[^\w\u4e00-\u9fff]', '_', role_name)
    schema_file = os.path.join(app_path, "roles", schema_dir, "schema.json")
    if not os.path.exists(schema_file):
        return missing
    try:
        with open(schema_file, "r", encoding="utf-8-sig") as f:
            schema = json.load(f)
    except (json.JSONDecodeError, ValueError):
        return missing

    required_files = schema.get("_required_files", [])
    if not required_files:
        return missing

    # workspace_id 为 None 时从 state_path 推导
    ws_id = workspace_id
    if not ws_id and state_path:
        ws_id = os.path.basename(os.path.dirname(state_path))

    for rf in required_files:
        # 支持 abs_path 绝对路径
        is_abs = bool(rf.get("abs_path"))
        rf_path = rf.get("abs_path") or rf.get("path", "")
        if not rf_path:
            continue
        # 跳过模板路径（如 app-v{iteration}.yaml）
        if "{" in rf_path:
            continue
        try:
            resolved = resolve_workspace_output(ws_id, rf_path, app_path, is_absolute=is_abs)
        except (FileNotFoundError, TypeError):
            continue
        if not os.path.exists(resolved):
            missing.append({"name": rf.get("name", ""), "path": rf_path})

    return missing


# ─── Phase 2: post_execute（Gate 校验 + 路由决策）───

def _check_envelope(step, envelope, state_path, app_path, failed, gate_results):
    """Phase 0: Gate Layer 0 信封校验。返回 True=通过/跳过, False=失败(已记录)。"""
    if not envelope:
        return True
    envelope_cmd = [
        sys.executable, "engine/scripts/gate.py",
        "--mode", "envelope",
        "--step", step,
        "--envelope", json.dumps(envelope, ensure_ascii=False),
        "--state-path", state_path,
        "--app-path", app_path,
    ]
    ok_env, env_result = run_script(envelope_cmd)
    env_verdict = env_result.get("verdict", "ENVELOPE_FAIL") if ok_env else "ENVELOPE_FAIL"
    if env_verdict == "ENVELOPE_FAIL":
        env_errors = env_result.get("errors", ["信封校验失败(无具体错误)"])
        # v8.5: 信封失败不再 BLOCKING，统一走 fail 边自动重试
        gate_results.append({
            "step": step,
            "output_path": "<envelope>",
            "verdict": "ENVELOPE_FAIL",
            "errors": env_errors,
        })
        return False
    return True


def _check_gate_files(step, output_paths, state_path, app_path, gate_results):
    """Phase A: Gate Layer 1 产出物文件校验。返回 (step_gate_entries, step_all_pass)。"""
    step_gate_entries = []
    step_all_pass = True
    for out_path in output_paths:
        if not out_path:
            continue
        gate_cmd = [
            sys.executable, "engine/scripts/gate.py",
            "--mode", "file",
            "--step", step,
            "--output-path", out_path,
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
        step_gate_entries.append(gate_entry)
        gate_results.append(gate_entry)
        if verdict != "PASS":
            step_all_pass = False
    return step_gate_entries, step_all_pass


def _decide_advance_or_set(step, _role, role_verdict, step_gate_entries, step_all_pass,
                           router_steps, reg_map, state_path,
                           pending, auto_confirmed, failed):
    """Phase C: 执行 verdict 路由与 advance/set_status 决策。"""
    if step_all_pass:
        semantic_verdict = role_verdict
        step_def = next((s for s in router_steps if s["step"] == step), None)
        transitions = step_def.get("transitions", {}) if step_def else {}

        if semantic_verdict and semantic_verdict == "fail":
            semantic_verdict = None
        effective_verdict = semantic_verdict or "confirmed"
        route_key = effective_verdict if effective_verdict in transitions else ("confirmed" if "confirmed" in transitions else None)
        if route_key is None:
            failed.append({"step": step, "reason": f"verdict={effective_verdict} 在 transitions 中无匹配边"})
            return

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
                "step": step, "output_path": step_gate_entries[0]["output_path"],
                "verdict": "PASS", "route_key": route_key,
                "errors": [],
            })
        else:
            set_cmd = [
                sys.executable, "engine/scripts/set_state.py",
                "--action", "set_status", "--step", step,
                "--status", "awaiting_confirmation",
                "--verdict", effective_verdict,
                "--state-path", state_path,
            ]
            run_script(set_cmd)
            pending.append({
                "step": step, "output_path": step_gate_entries[0]["output_path"],
                "verdict": "PASS",
                "errors": [],
            })
    else:
        advance_cmd = [
            sys.executable, "engine/scripts/set_state.py",
            "--action", "advance", "--step", step,
            "--role", _role, "--verdict", "fail",
            "--state-path", state_path,
        ]
        run_script(advance_cmd)
        all_errors = []
        for ge in step_gate_entries:
            all_errors.extend(ge.get("errors", []))
        auto_confirmed.append({
            "step": step, "output_path": step_gate_entries[0]["output_path"],
            "verdict": "FAIL", "route_key": "fail",
            "errors": all_errors,
        })


def _process_result_entry(r, router_steps, reg_map, step_role_map, state_path, app_path, workspace_id, pending, auto_confirmed, gate_results, failed):
    """处理单个执行结果：信封校验 → Gate 文件校验 → 必需文件检查 → advance/set_status 决策。"""
    step = r.get("step", "")
    envelope = r.get("envelope", {})
    output_paths = [o.get("path", "") for o in r.get("outputs", [])]
    role_verdict = r.get("verdict", "")
    _role = step_role_map.get(step, "")

    # Phase 0: 信封校验
    envelope_ok = _check_envelope(step, envelope, state_path, app_path, failed, gate_results)
    if not envelope_ok:
        # v8.5: 信封失败也走 fail 边（不再 BLOCKING，统一自动重试）
        env_entry = gate_results[-1]  # _check_envelope 刚追加的信封结果
        _decide_advance_or_set(step, _role, role_verdict, [env_entry], False,
                               router_steps, reg_map, state_path,
                               pending, auto_confirmed, failed)
        return

    # Phase A: Gate 文件校验
    step_gate_entries, step_all_pass = _check_gate_files(step, output_paths, state_path, app_path, gate_results)
    if not step_gate_entries:
        return

    # Phase B: 必需文件完整性校验
    missing_files = _check_required_files(app_path, _role, workspace_id, state_path)
    for mf in missing_files:
        gate_entry = {
            "step": step,
            "output_path": mf["path"],
            "verdict": "FAIL",
            "errors": [f"缺少必需产物: {mf['name']} ({mf['path']})"],
        }
        step_gate_entries.append(gate_entry)
        gate_results.append(gate_entry)
        step_all_pass = False

    # Phase C: advance/set_status 决策
    _decide_advance_or_set(step, _role, role_verdict, step_gate_entries, step_all_pass,
                           router_steps, reg_map, state_path,
                           pending, auto_confirmed, failed)


def _cleanup_failed_and_route(state_path, failed, pending, auto_confirmed, gate_results):
    """清理 failed 步骤的 step_status 并按优先级路由输出。"""
    for f in failed:
        _fstep = f["step"]
        with state_txn(state_path) as st:
            ss = st.get("step_status", {})
            if _fstep in ss:
                del ss[_fstep]

    if failed:
        output({"status": "success", "next": "error", "failed": failed, "gate_results": gate_results})

    if auto_confirmed and not pending:
        output({"status": "success", "next": "dispatch",
                "auto_confirmed": auto_confirmed, "gate_results": gate_results, "failed": failed})

    output({
        "status": "success",
        "next": "confirm",
        "pending": pending,
        "auto_confirmed": auto_confirmed,
        "gate_results": gate_results,
        "failed": failed,
    })


def phase_post_execute(state_path, app_path, workspace_id, results_json):
    """对每个执行结果调 gate.py → awaiting_confirmation / auto_confirm / rework / fail.
    统一逐个处理。
    """
    try:
        results = json.loads(results_json)
    except (json.JSONDecodeError, ValueError):
        output_error("OIC-E015", "--results 不是有效 JSON")

    if not isinstance(results, list):
        output_error("OIC-E015", "--results 必须是数组")

    router_steps, registry, reg_map, step_role_map = load_router_and_registry(app_path)

    pending = []
    auto_confirmed = []
    gate_results = []
    failed = []

    for r in results:
        _process_result_entry(r, router_steps, reg_map, step_role_map, state_path, app_path, workspace_id, pending, auto_confirmed, gate_results, failed)

    _cleanup_failed_and_route(state_path, failed, pending, auto_confirmed, gate_results)

# ─── Phase 3: post_confirm（Write-back）───

def phase_post_confirm(state_path, app_path, workspace_id, decisions_json):
    """confirmed → advance（写 completed + pending_routes）；直接返回 next: dispatch。

    统一路径重构：删除原 post_confirm 内的调 router + cache_dispatches 逻辑。
    advance 后由下一次 --next 从 pending_routes 走单一冷路径路由。
    """
    try:
        decisions = json.loads(decisions_json)
    except (json.JSONDecodeError, ValueError):
        output_error("OIC-E015", "--decisions 不是有效 JSON")

    if not isinstance(decisions, list):
        output_error("OIC-E015", "--decisions 必须是数组")

    router_steps, _, _, step_role_map = load_router_and_registry(app_path)

    # 预提取每个 step 的 original_verdict（避免循环内重复 load_state）
    st = load_state(state_path)
    pending_routes = st.get("pending_routes", {})
    step_status_map = st.get("step_status", {})
    step_verdicts = {}
    for d in decisions:
        step = d.get("step", "")
        original_verdict = pending_routes.get(step, {}).get("verdict")
        if not original_verdict:
            original_verdict = step_status_map.get(step, {}).get("verdict")
        step_verdicts[step] = original_verdict or "confirmed"

    advance_steps = []
    for d in decisions:
        step = d.get("step", "")
        decision = d.get("decision", "")
        _role = step_role_map.get(step, "")

        if decision == "fail":
            # 用户明确拒绝 → verdict = fail
            verdict = "fail"
        else:
            # 用户确认 → 保留 role 的原始 verdict
            verdict = step_verdicts.get(step, "confirmed")
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

    # 由下一次 --next 从 pending_routes 走单一冷路径路由。
    output({"status": "success", "next": "dispatch"})

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
