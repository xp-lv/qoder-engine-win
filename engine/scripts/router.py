#!/usr/bin/env python3
"""DAG 有向图路由调度器（v5.0 — 统一 carries + 边级计数）。

从"当前位置 + 执行结果"出发，沿 ROUTER.json 的有向图边找到下一个 STEP。
通过 orchestrator 的 input_groups 检查确保汇聚节点正确等待。
通过边级 max_executions 控制回退/循环次数上限。

v5.0 变化：
- 边类型简化为 normal / backward（删除 forward 概念）
- 物料注入统一为 edge.carries（不区分 forward/backward）
- 边级 max_executions 替代步骤级 rework_counts

Usage:
  # 初始调度（无 --from = 返回入口 STEP）
  python engine/scripts/router.py [--workspace-id <id>] [--app-path <path>] [--task-request <text>]

  # 结果驱动调度（从已完成的 STEP + 结果出发）
  python engine/scripts/router.py --from '["STEP0"]' --on confirmed [--workspace-id <id>] [--app-path <path>]
"""
import argparse, json, os, re, sys, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path, resolve_workspace_output, get_edge_targets, is_edge_backward
from state_io import load_state as _io_load, save_state, state_txn
from engine_common import output, load_json_or_exit

def _source_points_to_target(src_step, src_verdict, target, steps_map):
    """检查 src_step 的当前 verdict 对应的边是否指向 target。

    核心思路：JOIN 的有效前驱不只是"在 completed 中"，而是
    "其当前 verdict 对应的边确实指向 JOIN 目标"。
    如果前驱给了其他 verdict（走了别的边），不算有效前驱。
    """
    src_def = steps_map.get(src_step, {})
    transitions = src_def.get("transitions", {})
    edge = transitions.get(src_verdict, {})
    if isinstance(edge, dict):
        targets = edge.get("targets", [])
        return target in targets
    return False

def _router_parse_args():
    """Parse router CLI arguments."""
    parser = argparse.ArgumentParser(description="DAG 有向图路由调度器 v4.0")
    parser.add_argument("--from", dest="from_steps", default="", help="JSON array: 刚完成的 STEP 列表")
    parser.add_argument("--on", default="confirmed", help="执行结果: confirmed / fail / 条件路由 key")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--app-path", default=None, help="应用包路径")
    parser.add_argument("--workspace-id", default=None, help="Session ID（默认从 QODER_SESSION_ID 环境变量读取）")
    parser.add_argument("--task-request", default="", help="用户原始需求文本")
    return parser.parse_args()


def _router_find_candidates(args, router, steps, steps_map, executing, finished):
    """Determine candidate target steps. Returns (candidates, missing_steps, from_steps)."""
    missing_steps = []
    from_steps = []
    if not args.from_steps:
        entry = router.get("entry", "")
        if entry and entry not in finished:
            candidates = [entry]
        else:
            candidates = []
            for s in steps:
                sid = s["step"]
                if sid not in finished and sid not in executing:
                    candidates = [sid]
                    break
    else:
        try:
            from_steps = json.loads(args.from_steps)
        except (json.JSONDecodeError, ValueError):
            output({"status": "failure", "error_code": "OIC-E307", "message": "--from 不是有效 JSON 数组", "dispatch_instructions": []})
        candidates = []
        for from_step in from_steps:
            step_def = steps_map.get(from_step)
            if not step_def:
                missing_steps.append(from_step)
                continue
            transitions = step_def.get("transitions", {})
            targets = get_edge_targets(transitions, args.on)
            for t in targets:
                if t not in candidates:
                    candidates.append(t)
    return candidates, missing_steps, from_steps


def _router_check_join_target(target, is_backward, is_initial_dispatch, steps_map,
                               role_input_groups, pending_routes, executing):
    """Check if a target passes JOIN requirements. Returns True if dispatchable.

    JOIN 权威源是 pending_routes（瞬态：已完成但尚未被路由消费的前驱信号）。
    不再读 completed（持久历史档案，不参与 JOIN 判定）。
    """
    if not is_backward and not is_initial_dispatch:
        target_def = steps_map.get(target, {})
        target_role = target_def.get("role", "")
        groups = role_input_groups.get(target_role, [])
        if groups:
            satisfied = False
            for group in groups:
                all_valid = True
                for src in group:
                    if src not in pending_routes:
                        all_valid = False
                        break
                    if src in executing:
                        all_valid = False
                        break
                    src_verdict = pending_routes[src].get("verdict", "confirmed")
                    if not _source_points_to_target(src, src_verdict, target, steps_map):
                        all_valid = False
                        break
                if all_valid:
                    satisfied = True
                    break
            if not satisfied:
                return False
    return True


def _router_update_edge_counts(target, is_initial_dispatch, from_set, steps_map,
                                on_verdict, edge_counts):
    """Check and increment edge counts. Returns whether any count changed."""
    if is_initial_dispatch:
        return False
    changed = False
    for fs in from_set:
        fs_def = steps_map.get(fs, {})
        edge = fs_def.get("transitions", {}).get(on_verdict, {})
        if isinstance(edge, dict):
            max_exec = edge.get("max_executions")
            if max_exec is not None:
                edge_key = f"{fs}.{on_verdict}"
                current = edge_counts.get(edge_key, 0)
                if current >= max_exec:
                    continue
                edge_counts[edge_key] = current + 1
                changed = True
    return changed


def _router_assemble_dispatches(dispatchable, steps_map, registry_map, args, app_path,
                                 from_steps, edge_counts, user_request):
    """Build dispatch_instructions for all dispatchable targets."""
    from_steps_set = set(from_steps)
    dispatch_instructions = []
    for step_id in dispatchable:
        step_def = steps_map.get(step_id)
        if not step_def:
            continue

        role = step_def["role"]
        if role not in registry_map:
            output({"status": "failure", "error_code": "OIC-E305", "message": f"role {role} 不在注册表中", "dispatch_instructions": []})

        reg = registry_map[role]

        # 收集 inputs：读 registry 显式 inputs 声明
        inputs = []
        explicit_inputs = reg.get("inputs", [])
        for inp in explicit_inputs:
            is_abs = bool(inp.get("abs_path"))
            raw_path = inp.get("abs_path") or inp["path"]
            inp_type = inp.get("type")
            resolved = resolve_workspace_output(args.workspace_id, raw_path, app_path, is_absolute=is_abs, output_type=inp_type)
            if resolved not in inputs:
                inputs.append(resolved)

        # 统一注入边声明的 carries
        if args.from_steps:
            for fs in from_steps:
                fs_def = steps_map.get(fs, {})
                fs_trans = fs_def.get("transitions", {})
                edge = fs_trans.get(args.on, {})
                if isinstance(edge, dict):
                    for c in edge.get("carries", []):
                        c_path = c if isinstance(c, str) else c["path"]
                        resolved = resolve_workspace_output(args.workspace_id, c_path, app_path)
                        if resolved not in inputs:
                            inputs.append(resolved)

        # output_targets（支持 abs_path 绝对路径）
        output_targets = []
        for o in reg.get("outputs", []):
            o_copy = dict(o)
            is_abs = bool(o.get("abs_path"))
            raw_path = o.get("abs_path") or o["path"]
            o_copy["path"] = resolve_workspace_output(args.workspace_id, raw_path, app_path, is_absolute=is_abs)
            output_targets.append(o_copy)
        expected_outputs = []
        checkpoint_id = f"ckpt_{uuid.uuid4().hex[:12]}"
        blocking_mode = reg.get("blocking_mode", "manual")

        # Gate Layer 0 直接从 transitions 校验
        schema_constraints = {}
        step_transitions = step_def.get("transitions", {})
        verdict_keys = sorted([k for k in step_transitions.keys() if k != "fail"])
        if verdict_keys:
            schema_constraints = {"verdict_enum": verdict_keys}

        # 根据 edge_counts 动态过滤 verdict_enum
        if schema_constraints.get("verdict_enum"):
            step_transitions = step_def.get("transitions", {})
            filtered_enum = []
            for v in schema_constraints["verdict_enum"]:
                edge = step_transitions.get(v, {})
                if isinstance(edge, dict):
                    max_exec = edge.get("max_executions")
                    if max_exec is not None:
                        edge_key = f"{step_id}.{v}"
                        current_count = edge_counts.get(edge_key, 0)
                        if current_count >= max_exec:
                            continue
                filtered_enum.append(v)
            schema_constraints["verdict_enum"] = filtered_enum

        # 上下文感知 verdict 过滤（与 max_executions 过滤正交叠加）
        verdict_context = step_def.get("verdict_context")
        if verdict_context and schema_constraints.get("verdict_enum") and from_steps_set:
            for fs in from_steps_set:
                if fs in verdict_context:
                    valid_set = set(verdict_context[fs])
                    schema_constraints["verdict_enum"] = [
                        v for v in schema_constraints["verdict_enum"] if v in valid_set
                    ]
                    break

        dispatch_instructions.append({
            "step": step_id,
            "role": role,
            "skill": reg.get("skill_path", ""),
            "parameters": step_def.get("parameters", {}),
            "inputs": inputs,
            "output_targets": output_targets,
            "schema_constraints": schema_constraints,
            "task_context": {
                "user_request": user_request,
                "source": "user_input" if user_request else "system_init",
                "blocking_mode": blocking_mode
            },
            "expected_outputs": expected_outputs,
            "checkpoint_id": checkpoint_id
        })
    return dispatch_instructions


def main():
    args = _router_parse_args()

    app_path = resolve_app_path(args.workspace_id, args.app_path)
    state_path = resolve_ws_state(args.workspace_id)

    state = load_json_or_exit(state_path, "OIC-E301", "STATE.json 读取失败", extra_fields={"dispatch_instructions": []})
    router = load_json_or_exit(f"{app_path}/ROUTER.json", "OIC-E304", "ROUTER.json 读取失败", extra_fields={"dispatch_instructions": []})
    registry = load_json_or_exit(f"{app_path}/registry.json", "OIC-E306", "registry.json 读取失败", extra_fields={"dispatch_instructions": []})

    if state.get("terminal_state") is not None:
        output({"status": "failure", "error_code": "OIC-E302", "message": "已终态", "dispatch_instructions": []})

    steps = router.get("steps", [])
    steps_map = {s["step"]: s for s in steps}
    registry_map = {r["role_name"]: r for r in registry}
    executing = set(state.get("step_status", {}).keys())
    pending_routes = state.get("pending_routes", {})
    completed_raw = state.get("completed", {})
    finished = set(completed_raw.keys()) | set(pending_routes.keys())
    user_request = state.get("metadata", {}).get("user_request", "") or args.task_request

    # ── 确定候选目标 STEP ──
    candidates, missing_steps, from_steps = _router_find_candidates(
        args, router, steps, steps_map, executing, finished)

    # ── 判定当前路径类型 ──
    is_backward = False
    if args.from_steps:
        for fs in from_steps:
            fs_def = steps_map.get(fs, {})
            fs_trans = fs_def.get("transitions", {})
            if is_edge_backward(fs_trans, args.on):
                is_backward = True
                break

    # ── 过滤：边级计数检查 + 排除执行中 + per-target JOIN 检查 ──
    is_initial_dispatch = not args.from_steps
    from_set = set(from_steps) if args.from_steps else set()
    edge_counts = state.get("edge_counts", {})
    edge_counts_changed = False
    role_input_groups = {r["role_name"]: r.get("input_groups", []) for r in registry}

    dispatchable = []
    for target in candidates:
        if target in executing:
            continue
        if not _router_check_join_target(target, is_backward, is_initial_dispatch,
                                          steps_map, role_input_groups, pending_routes, executing):
            continue
        if _router_update_edge_counts(target, is_initial_dispatch, from_set,
                                      steps_map, args.on, edge_counts):
            edge_counts_changed = True
        dispatchable.append(target)

    if edge_counts_changed:
        with state_txn(state_path) as st:
            st["edge_counts"] = edge_counts

    # ── 组装 dispatch_instructions ──
    dispatch_instructions = _router_assemble_dispatches(
        dispatchable, steps_map, registry_map, args, app_path,
        from_steps, edge_counts, user_request)

    # router 只报告事实，不做终态判定。终态判定由 orchestrator 全局决策。
    result = {
        "status": "success",
        "error_code": None,
        "dispatch_instructions": dispatch_instructions,
        "has_candidates": len(candidates) > 0,
    }
    if not dispatchable and args.from_steps and missing_steps:
        result["message"] = "route_failed"
        result["reason"] = f"from_step 不存在于 ROUTER.json: {missing_steps}（STATE 与 ROUTER 可能版本不一致）"

    output(result)

if __name__ == "__main__":
    main()
