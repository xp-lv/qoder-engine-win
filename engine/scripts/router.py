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
  python3 engine/scripts/router.py [--workspace-id <id>] [--app-path <path>] [--task-request <text>]

  # 结果驱动调度（从已完成的 STEP + 结果出发）
  python3 engine/scripts/router.py --from '["STEP0"]' --on confirmed [--workspace-id <id>] [--app-path <path>]
"""
import argparse, json, os, re, sys, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path, resolve_workspace_output, get_edge_targets, is_edge_backward

def output(data):
    print(json.dumps(data, ensure_ascii=False))
    sys.exit(0 if data.get("status") == "success" else 1)

def load_json(path, error_code, error_msg):
    if not os.path.exists(path):
        output({"status": "failure", "error_code": error_code, "message": f"{error_msg}: {path}", "dispatch_instructions": []})
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, ValueError) as e:
        output({"status": "failure", "error_code": error_code, "message": f"{error_msg}: {e}", "dispatch_instructions": []})

def main():
    parser = argparse.ArgumentParser(description="DAG 有向图路由调度器 v4.0")
    parser.add_argument("--from", dest="from_steps", default="", help="JSON array: 刚完成的 STEP 列表")
    parser.add_argument("--on", default="confirmed", help="执行结果: confirmed / fail / 条件路由 key")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--app-path", default=None, help="应用包路径")
    parser.add_argument("--workspace-id", default=None, help="Session ID（默认从 QODER_SESSION_ID 环境变量读取）")
    parser.add_argument("--task-request", default="", help="用户原始需求文本")
    args = parser.parse_args()

    # 先解析 app_path，再用它推导 state_path（app 作用域）
    app_path = resolve_app_path(args.workspace_id, args.app_path)
    state_path = resolve_ws_state(args.workspace_id)

    state = load_json(state_path, "OIC-E301", "STATE.json 读取失败")
    router = load_json(f"{app_path}/ROUTER.json", "OIC-E304", "ROUTER.json 读取失败")
    registry = load_json(f"{app_path}/registry.json", "OIC-E306", "registry.json 读取失败")

    # v4.0: 直接读主线 STATE（无分支隔离）
    if state.get("terminal_state") is not None:
        output({"status": "failure", "error_code": "OIC-E302", "message": "已终态", "dispatch_instructions": []})

    steps = router.get("steps", [])
    steps_map = {s["step"]: s for s in steps}
    registry_map = {r["role_name"]: r for r in registry}
    executing = set(state.get("step_status", {}).keys())
    # v4.1: 读 completed（持久权威源）
    finished = set(state.get("completed", {}).keys())
    user_request = state.get("metadata", {}).get("user_request", "") or args.task_request

    # ─── 确定候选目标 STEP ───

    if not args.from_steps:
            # 初始调度：返回入口 STEP
            entry = router.get("entry", "")
            # entry 未完成 → 从 entry 开始
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
        # 结果驱动：沿有向图边查找
        try:
            from_steps = json.loads(args.from_steps)
        except (json.JSONDecodeError, ValueError):
            output({"status": "failure", "error_code": "OIC-E307", "message": "--from 不是有效 JSON 数组", "dispatch_instructions": []})

        candidates = []
        for from_step in from_steps:
            step_def = steps_map.get(from_step)
            if not step_def:
                continue
            transitions = step_def.get("transitions", {})
            # 精确匹配指定的 on 值
            targets = get_edge_targets(transitions, args.on)
            for t in targets:
                if t not in candidates:
                    candidates.append(t)

    # ─── 判定当前路径类型 ───
    # backward 边（fail/fail_*）：回退是强制行为，跳过 join
    is_backward = False
    if args.from_steps:
        for fs in from_steps:
            fs_def = steps_map.get(fs, {})
            fs_trans = fs_def.get("transitions", {})
            if is_edge_backward(fs_trans, args.on):
                is_backward = True
                break

    # ─── 过滤：边级计数检查 + 排除执行中 ───
    # sync 检查由 orchestrator 的汇集阶段统一处理（router 保持局部视角）
    is_initial_dispatch = not args.from_steps
    from_set = set(from_steps) if args.from_steps else set()
    edge_counts = state.get("edge_counts", {})
    edge_counts_changed = False

    dispatchable = []
    for target in candidates:
        # 排除正在执行的
        if target in executing:
            continue

        # 边级 max_executions 检查 + 递增（normal 和 backward 边均检查）
        if not is_initial_dispatch:
            for fs in from_set:
                fs_def = steps_map.get(fs, {})
                edge = fs_def.get("transitions", {}).get(args.on, {})
                if isinstance(edge, dict):
                    max_exec = edge.get("max_executions")
                    if max_exec is not None:
                        edge_key = f"{fs}.{args.on}"
                        current = edge_counts.get(edge_key, 0)
                        # current >= max_exec 表示已走完 max_exec 次，边掐断
                        if current >= max_exec:
                            continue  # 边已掐断，不再调度
                        edge_counts[edge_key] = current + 1
                        edge_counts_changed = True

        dispatchable.append(target)

    # 如果递增了 edge_counts，写回 STATE.json
    if edge_counts_changed:
        from filelock import acquire_lock, release_lock
        lock_path = state_path + ".lock"
        with open(lock_path, "w") as lock_file:
            if not acquire_lock(lock_file):
                output({"status": "failure", "error_code": "OIC-E013", "message": "获取锁失败", "dispatch_instructions": []})
            try:
                st = json.load(open(state_path, "r", encoding="utf-8"))
                st["edge_counts"] = edge_counts
                import tempfile
                fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state_path))
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(st, f, ensure_ascii=False, indent=2)
                os.replace(tmp, state_path)
            finally:
                release_lock(lock_file)

    # ─── 组装 dispatch_instructions ───

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
            inp_type = inp.get("type", "deliverable")
            resolved = resolve_workspace_output(args.workspace_id, inp["path"], app_path, inp_type)
            if resolved not in inputs:
                inputs.append(resolved)

        # 统一注入边声明的 carries（编译期确定，无论 forward/backward/custom）
        if args.from_steps:
            for fs in from_steps:
                fs_def = steps_map.get(fs, {})
                fs_trans = fs_def.get("transitions", {})
                edge = fs_trans.get(args.on, {})
                if isinstance(edge, dict):
                    for c in edge.get("carries", []):
                        c_type = c.get("type", "feedback")
                        resolved = resolve_workspace_output(args.workspace_id, c["path"], app_path, c_type)
                        if resolved not in inputs:
                            inputs.append(resolved)

        # 合并 output_targets（文档类）和 expected_outputs（schema）
        # outputs 路径按 type 分流：deliverable → workspace，runtime → ws process 目录
        output_targets = []
        for o in reg.get("outputs", []):
            o_copy = dict(o)
            output_type = o.get("type", "deliverable")
            o_copy["path"] = resolve_workspace_output(args.workspace_id, o["path"], app_path, output_type)
            output_targets.append(o_copy)
        expected_outputs = []
        checkpoint_id = f"ckpt_{uuid.uuid4().hex[:12]}"
        blocking_mode = reg.get("blocking_mode", "manual")

        # 读取 schema 约束（与 inputs 同源：registry/roles 目录）
        schema_constraints = {}
        schema_dir_name = re.sub(r'[^\w\u4e00-\u9fff]', '_', role)
        schema_file_path = os.path.join(app_path, "roles", schema_dir_name, "schema.json")
        if os.path.exists(schema_file_path):
            try:
                with open(schema_file_path, "r", encoding="utf-8") as f:
                    role_schema = json.load(f)
                req_top = role_schema.get("required", [])
                props = role_schema.get("properties", {})
                result_props = props.get("result", {}).get("properties", {})
                result_req = props.get("result", {}).get("required", [])
                verdict_enum = result_props.get("verdict", {}).get("enum")
                if req_top or result_req or verdict_enum:
                    schema_constraints = {
                        "required_top": req_top,
                        "result_required": result_req,
                        "verdict_enum": list(verdict_enum) if verdict_enum else [],
                    }
            except Exception:
                pass

        # 根据 edge_counts 动态过滤 verdict_enum：
        # 某个 verdict 对应的边已达到 max_executions → 从可选值中移除
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
                            continue  # 该 verdict 的边已掐断，从 enum 中移除
                filtered_enum.append(v)
            schema_constraints["verdict_enum"] = filtered_enum

        # 上下文感知 verdict 过滤（与 max_executions 过滤正交叠加）
        # 按 from_steps 查 verdict_context，限定目标 step 的 verdict 输出空间
        verdict_context = step_def.get("verdict_context")
        if verdict_context and schema_constraints.get("verdict_enum") and from_set:
            for fs in from_set:
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
            "principles": reg.get("principles", ""),
            "checkpoint_id": checkpoint_id
        })

    if not dispatchable:
        # 无可调度：检查是否全部完成
        if not executing:
            output({"status": "success", "error_code": None, "message": "all_complete", "dispatch_instructions": []})
        else:
            output({"status": "success", "error_code": None, "message": "no_dispatchable_steps", "dispatch_instructions": []})

    output({"status": "success", "error_code": None, "dispatch_instructions": dispatch_instructions})

if __name__ == "__main__":
    main()
