#!/usr/bin/env python3
"""skill-builder 扰动修复脚本。
将扰动类型映射为 set_state.py 调用。
Usage: python scripts/fix.py --type <rework|reset|jump> [--step <STEP_N>] [--state-path <path>]
"""
import argparse, json, os, sys, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path

def output(data):
    print(json.dumps(data, ensure_ascii=False))
    sys.exit(0 if data.get("status") == "success" else 1)

MAPPING = {
    "rework": {"action": "rollback"},
    "reset": {"action": "reset"},
    "jump": {"action": "advance"},
}

def _build_subprocess_env():
    """构建子进程环境变量，确保 UTF-8 编码（Windows 兼容）。"""
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    return env

def main():
    parser = argparse.ArgumentParser(description="扰动修复")
    parser.add_argument("--type", required=True, choices=["rework", "reset", "jump"])
    parser.add_argument("--step", default=None, help="目标 STEP（jump/rework 均可指定）")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--workspace-id", default=None, help="Session ID")
    args = parser.parse_args()
    # workspace-centric：state_path 从 ws_id 推导
    if not args.state_path:
        args.state_path = resolve_ws_state(args.workspace_id)
    app_path = resolve_app_path(args.workspace_id)

    mapping = MAPPING.get(args.type)
    if not mapping:
        output({"status": "failure", "error_code": "OIC-E104", "message": f"无映射规则: {args.type}", "new_state_snapshot": None})

    # ── jump 特殊处理：标记前置步骤完成 + 缓存目标步骤 dispatch ──
    if args.type == "jump":
        if not args.step:
            output({"status": "failure", "error_code": "OIC-E104", "message": "jump 需要 --step 参数", "new_state_snapshot": None})
        state = _do_jump(args.state_path, app_path, args.workspace_id, args.step)
        output({"status": "success", "error_code": None, "new_state_snapshot": state, "message": f"jumped to {args.step}"})

    # 确定 --step 参数
    if args.type == "jump" and args.step:
        step = args.step
    elif args.type == "rework" and args.step:
        # v-longrun-R2: rework 支持显式指定 --step
        step = args.step
    elif args.type == "reset":
        step = "ALL"
    else:
        # rework: 从 STATE.json 读所有正在执行的 STEP
        if os.path.exists(args.state_path):
            try:
                with open(args.state_path, "r", encoding="utf-8-sig") as f:
                    state = json.load(f)
                step_status = state.get("step_status", {})
                if step_status:
                    # v-longrun-R2: 遍历所有 executing 步骤而非仅取第一个
                    executing_steps = [k for k, v in step_status.items() if v.get("status") == "executing"]
                    if executing_steps:
                        # 对每个 executing 步骤执行 rollback
                        steps_to_rollback = executing_steps
                    else:
                        steps_to_rollback = list(step_status.keys())
                    if len(steps_to_rollback) == 1:
                        step = steps_to_rollback[0]
                    else:
                        # 多个步骤：批量 rollback
                        # v-longrun-R3: 原子性修复——每个 rollback 后检查返回值，失败则停止
                        rollback_errors = []
                        for s in steps_to_rollback:
                            rollback_cmd = [sys.executable, "engine/scripts/set_state.py", "--action", "rollback", "--step", s, "--state-path", args.state_path]
                            run_result = subprocess.run(rollback_cmd, capture_output=True, text=True, timeout=10, encoding="utf-8", errors="replace", env=_build_subprocess_env())
                            if run_result.returncode != 0:
                                rollback_errors.append({"step": s, "error": run_result.stderr.strip()})
                        if rollback_errors:
                            output({"status": "failure", "error_code": "OIC-E105", "message": f"batch_rollback 部分失败: {rollback_errors}", "new_state_snapshot": state})
                        # 返回最后一个步骤的状态
                        output({"status": "success", "error_code": None, "new_state_snapshot": state, "message": f"batch_rollback: {steps_to_rollback}"})
                else:
                    # 无正在执行的 STEP：无需 rework，返回 success + no_op
                    output({"status": "success", "error_code": None, "new_state_snapshot": state, "message": "no_op: 无正在执行的 STEP，无需 rework"})
            except Exception as e:
                output({"status": "failure", "error_code": "OIC-E102", "message": f"STATE.json 读取失败: {e}", "new_state_snapshot": None})
        else:
            output({"status": "failure", "error_code": "OIC-E102", "message": "STATE.json 不存在", "new_state_snapshot": None})

    cmd = [sys.executable, "engine/scripts/set_state.py", "--action", mapping["action"], "--step", step, "--state-path", args.state_path]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10, encoding="utf-8", errors="replace", env=_build_subprocess_env())
        if result.returncode == 0:
            data = json.loads(result.stdout)
            output({"status": data.get("status", "failure"), "error_code": data.get("error_code"), "new_state_snapshot": data.get("new_state")})
        else:
            output({"status": "failure", "error_code": "OIC-E103", "message": f"set_state.py 退出码 {result.returncode}: {result.stderr}", "new_state_snapshot": None})
    except Exception as e:
        output({"status": "failure", "error_code": "OIC-E103", "message": f"set_state.py 调用异常: {e}", "new_state_snapshot": None})

def _do_jump(state_path, app_path, workspace_id, target_step):
    """jump 核心逻辑：
    1. 清理当前执行中的步骤
    2. 将目标步骤之前的所有步骤标记为已完成（finished）
    """
    import uuid
    from datetime import datetime, timezone
    import tempfile
    from filelock import acquire_lock, release_lock

    def now_iso():
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # 读取 STATE.json
    if not os.path.exists(state_path):
        output({"status": "failure", "error_code": "OIC-E102", "message": "STATE.json 不存在", "new_state_snapshot": None})
    with open(state_path, "r", encoding="utf-8-sig") as f:
        state = json.load(f)

    # 读取 ROUTER.json
    router_path = os.path.join(app_path, "ROUTER.json")
    registry_path = os.path.join(app_path, "registry.json")
    if not os.path.exists(router_path):
        output({"status": "failure", "error_code": "OIC-E104", "message": f"ROUTER.json 不存在: {router_path}", "new_state_snapshot": None})
    with open(router_path, "r", encoding="utf-8-sig") as f:
        router_data = json.load(f)
    router_steps = router_data.get("steps", [])

    all_step_ids = [s["step"] for s in router_steps]
    if target_step not in all_step_ids:
        output({"status": "failure", "error_code": "OIC-E104", "message": f"--step {target_step} 不在路由表中，可用: {all_step_ids}", "new_state_snapshot": None})
    target_idx = all_step_ids.index(target_step)
    predecessor_steps = all_step_ids[:target_idx]

    # 1. 清理当前执行中的步骤
    ss = state.get("step_status", {})
    if ss:
        for k in list(ss.keys()):
            del ss[k]

    # 2. 前置步骤标记为已完成（v4.1: 写入 completed + pending_routes）
    completed = state.setdefault("completed", {})
    pending_routes = state.setdefault("pending_routes", {})
    for i, sid in enumerate(predecessor_steps):
        if sid not in completed:
            entry = {
                "id": f"ckpt_jump_{sid}_{uuid.uuid4().hex[:8]}",
                "created_at": now_iso(),
                "role": router_steps[i].get("role", ""),
                "jumped_over": True
            }
            completed[sid] = entry
            pending_routes[sid] = entry

    # 3. 清除目标步骤及其所有下游步骤的 completed + pending_routes（jump 回退语义）
    downstream_steps = all_step_ids[target_idx:]
    for sid in downstream_steps:
        completed.pop(sid, None)
        pending_routes.pop(sid, None)

    # 4. 清理 pending_dispatches（让 --next 走正常 router 路径）
    state["pending_dispatches"] = None

    # 5. 原子写入
    lock_path = state_path + ".lock"
    with open(lock_path, "w") as lock_file:
        if not acquire_lock(lock_file):
            output({"status": "failure", "error_code": "OIC-E202", "message": "获取文件锁失败"})
        fd, tmp_path = tempfile.mkstemp(suffix=".tmp", dir=os.path.dirname(state_path))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(state, f, ensure_ascii=False, indent=2)
            os.replace(tmp_path, state_path)
        finally:
            release_lock(lock_file)

    print(f"[fix] jump to {target_step}: 跳过 {len(predecessor_steps)} 个前置步骤", file=sys.stderr)
    return state


if __name__ == "__main__":
    main()
