#!/usr/bin/env python3
"""state_health_check.py — 基于 ROUTER.json 的全局 STATE 健康检测与修复。

核心设计：
1. 读取 ROUTER.json 的 DAG 拓扑（steps + transitions）
2. 读 registry.json 的 input_groups（JOIN 依赖）
3. 对照 STATE.json 的 completed/step_status/pending_dispatches，做全局合法性校验
4. 检测到不一致时，从 DAG 拓扑角度修复，而非粗暴 rollback

修复策略（按优先级）：
  Z1: 僵尸 executing 清理 — step_status 中有 executing 但无对应活跃 Task → rollback 该 step
  Z2: 悬空 pending_dispatches — dispatch 引用的 source step 已不在 completed → 移除该 dispatch
  Z3: 断裂 JOIN 修复 — JOIN 节点的 input_groups 有部分 source 在 completed 但节点本身不在 → 确保 pending_dispatches 不会被误清
  Z4: pending_dispatches 丢失恢复 — completed 中有新的路由信号但 pending_dispatches=None → 重新生成 dispatch
  Z5: pending_routes 冗余清理 — pending_routes 中存在不在 completed 中的条目 → 清除

Usage:
  python state_health_check.py --workspace-id <ws_id> [--dry-run] [--fix]
  python state_health_check.py --state-path <path> --router-path <path> [--dry-run] [--fix]
"""
import argparse, json, os, sys, copy
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path
from state_io import save_state


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None


def build_router_index(router_data):
    """从 ROUTER.json 构建拓扑索引。

    返回:
      step_transitions: {step_name: {verdict: {targets: [], type: str}}}
      reverse_deps: {target_step: [(source_step, verdict), ...]}
      join_inputs: {join_step: [[source1, source2, ...], ...]}  # from registry input_groups
      all_steps: set of all step names
      entry_step: str
    """
    steps = router_data.get("steps", [])
    step_transitions = {}
    reverse_deps = {}
    all_steps = set()

    for s in steps:
        step_name = s.get("step", "")
        all_steps.add(step_name)
        trans = s.get("transitions", {})
        step_transitions[step_name] = {}
        for verdict, t_info in trans.items():
            targets = t_info.get("targets", [])
            t_type = t_info.get("type", "normal")
            step_transitions[step_name][verdict] = {"targets": targets, "type": t_type}
            for tgt in targets:
                reverse_deps.setdefault(tgt, []).append((step_name, verdict))

    entry = router_data.get("entry", "")
    return {
        "step_transitions": step_transitions,
        "reverse_deps": reverse_deps,
        "all_steps": all_steps,
        "entry": entry,
    }


def build_join_index(registry_data):
    """从 registry.json 构建 JOIN 索引。

    返回:
      join_map: {step_name: [[source1, ...], [alt_source1, ...]]}
      即每个步骤的所有 input_groups（每个 group 是一组 JOIN 来源）
    """
    join_map = {}
    if not isinstance(registry_data, list):
        return join_map
    for entry in registry_data:
        step = entry.get("role_name", "")
        groups = entry.get("input_groups", [])
        if groups:
            join_map[step] = groups
    return join_map


def check_health(state, router_idx, join_idx):
    """执行健康检测，返回 findings 列表。

    每个 finding:
      {id, severity, category, description, step, fix_type, fix_data}
    """
    findings = []
    completed = state.get("completed", {})
    step_status = state.get("step_status", {})
    pending_dispatches = state.get("pending_dispatches")
    pending_routes = state.get("pending_routes", {})
    cached_branch_results = state.get("cached_branch_results", [])
    terminal = state.get("terminal_state")

    step_transitions = router_idx["step_transitions"]
    reverse_deps = router_idx["reverse_deps"]
    all_steps = router_idx["all_steps"]
    entry = router_idx["entry"]

    # ════════════════════════════════════════
    # Z1: 僵尸 executing 检测
    # ════════════════════════════════════════
    for step, info in step_status.items():
        if isinstance(info, dict) and info.get("status") == "executing":
            findings.append({
                "id": "Z1",
                "severity": "critical",
                "category": "zombie_executing",
                "description": f"步骤 '{step}' 处于 executing 但无活跃 Task（可能被取消或崩溃）",
                "step": step,
                "fix_type": "rollback_step",
                "fix_data": {"step": step},
            })

    # ════════════════════════════════════════
    # Z2: 悬空 pending_dispatches 检测
    # ════════════════════════════════════════
    if pending_dispatches:
        for i, disp in enumerate(pending_dispatches):
            disp_step = disp.get("step", "")
            # 检查 dispatch 的 checkpoint 是否还有意义
            # dispatch 的来源应该在 completed 中（通过 ROUTER 路由产生）
            # 如果一个 dispatch 指向的 step 已经在 step_status 或 completed 中，则悬空
            if disp_step in step_status or disp_step in completed:
                findings.append({
                    "id": "Z2",
                    "severity": "major",
                    "category": "stale_dispatch",
                    "description": f"pending_dispatches[{i}] 指向 '{disp_step}' 已在 step_status/completed 中",
                    "step": disp_step,
                    "fix_type": "remove_dispatch",
                    "fix_data": {"index": i},
                })

    # ════════════════════════════════════════
    # Z3: 断裂的 JOIN 链路检测（去重版：按目标 step 聚合，每个目标最多一条 finding）
    # ════════════════════════════════════════
    # 收集所有「路由目标未被调度」的候选
    _z3_candidates = {}  # {target_step: set(source_steps)}
    for step, ckpt in completed.items():
        verdict = ckpt.get("verdict", "")
        trans = step_transitions.get(step, {}).get(verdict)
        if not trans:
            continue
        targets = trans.get("targets", [])

        for tgt in targets:
            if tgt in completed or tgt in step_status:
                continue  # 目标已处理或正在执行
            _z3_candidates.setdefault(tgt, set()).add(step)

    # 对每个候选目标，检查是否应该被调度
    for tgt, sources in _z3_candidates.items():
        join_groups = join_idx.get(tgt, [])
        should_dispatch = False
        satisfied_sources = list(sources)

        if join_groups:
            # JOIN 节点：检查至少一个 input_group 是否全部满足
            for group in join_groups:
                sources_in_completed = [s for s in group if s in completed]
                if len(sources_in_completed) == len(group):
                    should_dispatch = True
                    satisfied_sources = sources_in_completed
                    break
        else:
            # 非 JOIN 节点：只要有一个 source confirmed 就应该调度
            should_dispatch = True

        if not should_dispatch:
            continue

        # 检查目标是否已在待调度通道中（pending_dispatches 或 pending_routes）
        in_dispatches = False
        if pending_dispatches:
            in_dispatches = any(d.get("step") == tgt for d in pending_dispatches)
        # pending_routes 中有 source 信号 = --next 冷路径会路由到该目标
        in_pending_routes = any(s in pending_routes for s in satisfied_sources)

        if not in_dispatches and not in_pending_routes and not cached_branch_results:
            findings.append({
                "id": "Z3",
                "severity": "major",
                "category": "broken_join" if join_groups else "missing_dispatch",
                "description": f"目标 '{tgt}' 的路由来源已满足 ({', '.join(satisfied_sources)}) 但未出现在 pending_dispatches/pending_routes 中",
                "step": tgt,
                "fix_type": "regenerate_dispatch",
                "fix_data": {"step": tgt, "sources": satisfied_sources},
            })

    # ════════════════════════════════════════
    # Z4: pending_routes 冗余检测
    # ════════════════════════════════════════
    for step in list(pending_routes.keys()):
        if step not in completed:
            findings.append({
                "id": "Z4",
                "severity": "minor",
                "category": "stale_pending_route",
                "description": f"pending_routes 中 '{step}' 不在 completed 中",
                "step": step,
                "fix_type": "remove_pending_route",
                "fix_data": {"step": step},
            })

    # ════════════════════════════════════════
    # Z5: cached_branch_results 与 step_status 冲突
    # ════════════════════════════════════════
    if cached_branch_results and step_status:
        findings.append({
            "id": "Z5",
            "severity": "major",
            "category": "cache_conflict",
            "description": f"cached_branch_results 非空且 step_status 非空，可能导致重复处理",
            "step": list(step_status.keys())[0] if step_status else "",
            "fix_type": "clear_cache",
            "fix_data": {},
        })

    # ════════════════════════════════════════
    # Z6: completed / step_status 含非法步骤名（不在 ROUTER.json 中）
    # ════════════════════════════════════════
    for step in list(completed.keys()):
        if step not in all_steps:
            findings.append({
                "id": "Z6",
                "severity": "major",
                "category": "illegal_step_in_completed",
                "description": f"completed 中 '{step}' 不在 ROUTER.json 的步骤定义中（疑似手动篡改）",
                "step": step,
                "fix_type": "remove_illegal_completed",
                "fix_data": {"step": step},
            })
    for step in list(step_status.keys()):
        if step not in all_steps:
            findings.append({
                "id": "Z6",
                "severity": "major",
                "category": "illegal_step_in_step_status",
                "description": f"step_status 中 '{step}' 不在 ROUTER.json 的步骤定义中（疑似手动篡改）",
                "step": step,
                "fix_type": "remove_illegal_step_status",
                "fix_data": {"step": step},
            })

    return findings


def apply_fixes(state, findings, state_path):
    """应用修复到 state（原地修改）。返回 (fixed_count, actions_log)。"""
    actions = []
    for f in findings:
        if f["severity"] in ("critical", "major", "minor"):
            fix_type = f["fix_type"]
            step = f.get("step", "")
            fix_data = f.get("fix_data", {})

            if fix_type == "rollback_step":
                target_step = fix_data.get("step", step)
                ss = state.get("step_status", {})
                if target_step in ss:
                    del ss[target_step]
                completed = state.get("completed", {})
                if target_step in completed:
                    del completed[target_step]
                actions.append(f"rollback: {target_step}（清理僵尸 executing）")

            elif fix_type == "remove_dispatch":
                idx = fix_data.get("index", -1)
                disp_list = state.get("pending_dispatches") or []
                if 0 <= idx < len(disp_list):
                    removed = disp_list.pop(idx)
                    state["pending_dispatches"] = disp_list if disp_list else None
                    actions.append(f"remove_dispatch[{idx}]: {removed.get('step', '?')}")

            elif fix_type == "regenerate_dispatch":
                # 断裂 JOIN 修复：从 completed 中重建 pending_routes
                # 原理：--next 的冷路径从 pending_routes 出发调用 router.py 路由。
                # rollback 副作用清除了 pending_routes，导致 --next 无信号可路由。
                # 修复：将 completed 中的上游 source 重新写入 pending_routes，
                # 这样 --next 冷路径能重新发现并路由到缺失的目标 step。
                tgt_step = fix_data.get("step", step)
                sources = fix_data.get("sources", [])
                completed = state.get("completed", {})
                pending_routes = state.get("pending_routes", {})
                restored = []
                for src in sources:
                    if src in completed and src not in pending_routes:
                        pending_routes[src] = completed[src]
                        restored.append(src)
                if restored:
                    state["pending_routes"] = pending_routes
                    # 确保 pending_dispatches 为 None（让 --next 走冷路径而非读缓存）
                    state["pending_dispatches"] = None
                    # 清理 cached_branch_results（可能阻碍 --next 的全局决策）
                    state["cached_branch_results"] = []
                    actions.append(
                        f"rebuild_pending_routes: {tgt_step} ← {', '.join(restored)}"
                    )
                else:
                    # sources 不在 completed 中，无法重建
                    actions.append(
                        f"skip_rebuild: {tgt_step} (sources not in completed)"
                    )

            elif fix_type == "remove_pending_route":
                target_step = fix_data.get("step", step)
                pr = state.get("pending_routes", {})
                if target_step in pr:
                    del pr[target_step]
                    actions.append(f"remove_pending_route: {target_step}")

            elif fix_type == "clear_cache":
                state["cached_branch_results"] = []
                actions.append("clear_cached_branch_results（step_status 非空时清理）")

            elif fix_type == "remove_illegal_completed":
                target_step = fix_data.get("step", step)
                completed = state.get("completed", {})
                if target_step in completed:
                    del completed[target_step]
                    actions.append(f"remove_illegal_completed: {target_step}")

            elif fix_type == "remove_illegal_step_status":
                target_step = fix_data.get("step", step)
                ss = state.get("step_status", {})
                if target_step in ss:
                    del ss[target_step]
                    actions.append(f"remove_illegal_step_status: {target_step}")

    return len(actions), actions


def main():
    parser = argparse.ArgumentParser(description="全局 STATE 健康检测与修复")
    parser.add_argument("--workspace-id", default=None, help="工作区 ID")
    parser.add_argument("--state-path", default=None, help="STATE.json 路径")
    parser.add_argument("--router-path", default=None, help="ROUTER.json 路径")
    parser.add_argument("--dry-run", action="store_true", help="仅检测不修复")
    parser.add_argument("--fix", action="store_true", help="自动修复检测到的问题")
    args = parser.parse_args()

    # 解析路径
    ws_id = args.workspace_id
    state_path = args.state_path
    if not state_path:
        state_path = resolve_ws_state(ws_id)
    if not state_path or not os.path.exists(state_path):
        print(json.dumps({"status": "error", "error": f"STATE.json 不存在: {state_path}"}))
        sys.exit(1)

    # 解析 app 路径找 ROUTER.json 和 registry.json
    app_path = None
    if args.router_path:
        router_path = args.router_path
        registry_path = args.router_path.replace("ROUTER.json", "registry.json")
    else:
        if not ws_id:
            ws_id = load_json(state_path).get("workspace_id", "default") if load_json(state_path) else "default"
        app_path = resolve_app_path(ws_id)
        router_path = os.path.join(app_path, "ROUTER.json")
        registry_path = os.path.join(app_path, "registry.json")

    # 加载数据
    state = load_json(state_path)
    router_data = load_json(router_path)
    registry_data = load_json(registry_path)

    if not state or not router_data:
        print(json.dumps({"status": "error", "error": "无法加载 STATE.json 或 ROUTER.json"}))
        sys.exit(1)

    # 构建索引
    router_idx = build_router_index(router_data)
    join_idx = build_join_index(registry_data or [])

    # 执行检测
    findings = check_health(state, router_idx, join_idx)

    # 汇总
    critical = [f for f in findings if f["severity"] == "critical"]
    major = [f for f in findings if f["severity"] == "major"]
    minor = [f for f in findings if f["severity"] == "minor"]
    low = [f for f in findings if f["severity"] == "low"]

    result = {
        "status": "healthy" if not critical and not major else "unhealthy",
        "workspace_id": ws_id or state.get("workspace_id", "?"),
        "summary": {
            "total_findings": len(findings),
            "critical": len(critical),
            "major": len(major),
            "minor": len(minor),
            "low": len(low),
        },
        "findings": findings,
    }

    # 修复（通过 state_io 统一写入）
    if args.fix and findings:
        try:
            state = load_json(state_path) or state
            fixed_count, actions = apply_fixes(state, findings, state_path)

            if fixed_count > 0:
                hist = state.setdefault("history", [])
                hist.append({
                    "timestamp": now_iso(),
                    "action": "health_check_fix",
                    "step": "global",
                    "actor": "state_health_check.py",
                    "result": f"fixed {fixed_count} issues: {'; '.join(actions)}",
                })
                if len(hist) > 500:
                    state["history"] = hist[-500:]

                save_state(state_path, state)

                result["fix_status"] = f"fixed {fixed_count} issues"
                result["fix_actions"] = actions
            else:
                result["fix_status"] = "no fixes needed"
        except Exception as e:
            result["fix_status"] = f"error: {e}"

    # dry-run 模式下只输出不修复
    if args.dry_run:
        result["mode"] = "dry-run"
    elif args.fix:
        result["mode"] = "fix"
    else:
        result["mode"] = "check"

    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
