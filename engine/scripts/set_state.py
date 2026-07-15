#!/usr/bin/env python3
"""skill-builder STATE.json 唯一写者。
所有 STATE.json 修改都通过此脚本完成（跨平台文件锁保护）。
Usage: python3 scripts/set_state.py --action <action> --step <STEP_N> [options]
"""
import argparse, json, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state
from filelock import acquire_lock, release_lock
from datetime import datetime, timezone


class ValidationException(Exception):
    """验证失败异常，由 main() 捕获后统一释放锁并输出错误（v3.2：修复锁泄漏）。"""
    def __init__(self, error_code, message):
        self.error_code = error_code
        self.message = message
        super().__init__(message)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def _atomic_write_state(state_path, state):
    """v-longrun-R4: 原子写入 STATE.json——先写临时文件再 rename。
    防止写入过程中异常导致文件损坏（磁盘满、权限变更等）。
    """
    d = os.path.dirname(state_path)
    fd, tmp_path = tempfile.mkstemp(suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
        os.replace(tmp_path, state_path)  # 原子 rename
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

def output_success(state):
    print(json.dumps({"status": "success", "error_code": None, "new_state": state}, ensure_ascii=False))
    sys.exit(0)

def output_failure(error_code, message):
    print(json.dumps({"status": "failure", "error_code": error_code, "message": message, "new_state": None}, ensure_ascii=False))
    sys.exit(1)

def create_initial_state():
    return {
        "schema_version": "4.1",
        "project_id": os.path.basename(os.getcwd()),
        "step_status": {},
        "terminal_state": None,
        "completed": {},       # 持久：完成记录，_global_converge JOIN 判断的权威源
        "pending_routes": {},  # 瞬态：待路由信号，advance 写入，路由后清空
        "edge_counts": {},
        "pending_dispatches": None,
        "history": [],
        "metadata": {"started_at": now_iso(), "last_advance_at": None, "user_request": ""}
    }

def validate_action(state, action, step):
    # reset 豁免终态检查（reset 的设计意图就是清除终态）
    if state.get("terminal_state") is not None and action not in ("terminal", "reset"):
        raise ValidationException("OIC-E206", f"终态不可变：terminal_state={state['terminal_state']}")

def do_rollback(state, step):
    """v4.1: 回退清除 step_status + completed + pending_routes + pending_dispatches。
    pbc 不再需要手动清零——它从 step_status 派生，step_status 清空后 pbc 自然为 0。
    """
    ss = state.get("step_status", {})
    if step in ss:
        del ss[step]
    # 同步清理 completed 中的完成记录（消除缺陷3：拓扑不一致）
    completed = state.get("completed", {})
    if step in completed:
        del completed[step]
    # 清理瞬态路由信号
    pending_routes = state.get("pending_routes", {})
    if step in pending_routes:
        del pending_routes[step]
    state["pending_dispatches"] = None

def do_reset(state):
    state["step_status"] = {}
    state["completed"] = {}
    state["pending_routes"] = {}
    state["edge_counts"] = {}
    state["terminal_state"] = None
    state["pending_dispatches"] = None
    state["history"] = []

def do_advance(state, step, role, dispatch_id, verdict=None):
    """v4.1: 写入 completed（持久）+ pending_routes（瞬态路由信号）。
    completed: _global_converge 的 JOIN 判断权威源，整个执行期间保留。
    pending_routes: phase_dispatch 冷路径的路由信号，路由完成后清空。
    """
    ss = state.get("step_status", {})
    existing = ss.get(step, {})
    if not dispatch_id:
        dispatch_id = existing.get("dispatch_id", "")
    if not role:
        role = existing.get("role", "")
    if step in ss:
        del ss[step]
    result = {
        "id": dispatch_id or f"ckpt_{now_iso()}",
        "created_at": now_iso(),
        "role": role,
    }
    if verdict:
        result["verdict"] = verdict
    # 写入两个独立结构（消除多源冲突）
    state.setdefault("completed", {})[step] = result
    state.setdefault("pending_routes", {})[step] = result
    state["metadata"]["last_advance_at"] = now_iso()

def do_resume(state, step):
    completed = state.get("completed", {})
    if step not in completed:
        raise ValidationException("OIC-E205", f"无可恢复 completed：{step}")
    r = completed[step]
    state.setdefault("step_status", {})[step] = {
        "role": r.get("role", ""),
        "status": "executing",
        "dispatch_id": r.get("id", "")
    }

# do_loop 和 do_uncomplete 已删除

def do_set_status(state, step, status, role, dispatch_id, from_steps=None):
    ss = state.get("step_status", {})
    if status == "idle":
        if step in ss:
            del ss[step]
    else:
        entry = {"role": role or ss.get(step, {}).get("role", ""), "status": status, "dispatch_id": dispatch_id or ss.get(step, {}).get("dispatch_id", "")}
        # v-longrun-R2: executing 状态记录 started_at 时间戳，用于陈旧执行检测
        if status == "executing":
            entry["started_at"] = now_iso()
            if from_steps:
                entry["from_steps"] = from_steps
        ss[step] = entry
    state["step_status"] = ss


MAX_HISTORY_SIZE = 500  # v-longrun: FIFO 窗口上限，防止长程任务中 history 无限增长

def append_history(state, action, step, result):
    state.setdefault("history", []).append({
        "timestamp": now_iso(), "action": action, "step": step,
        "actor": "set_state.py", "result": result
    })
    # v-longrun: FIFO 窗口修剪，防止 STATE.json 膨胀
    if len(state["history"]) > MAX_HISTORY_SIZE:
        state["history"] = state["history"][-MAX_HISTORY_SIZE:]

def main():
    parser = argparse.ArgumentParser(description="STATE.json 唯一写者")
    parser.add_argument("--action", required=True, choices=["rollback", "reset", "advance", "resume", "terminal", "set_status"])
    parser.add_argument("--step", required=True, help="目标 STEP 编号（terminal 可用 ALL）")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--workspace-id", default=None, help="Session ID（默认从 QODER_SESSION_ID 环境变量读取）")
    parser.add_argument("--terminal-state", help="终态枚举")
    parser.add_argument("--terminal-reason", help="终态原因")
    parser.add_argument("--status", help="执行状态（set_status 专用）")
    parser.add_argument("--role", help="角色名（set_status+executing 专用）")
    parser.add_argument("--dispatch-id", help="dispatch checkpoint_id（set_status+executing 专用）")
    parser.add_argument("--verdict", default=None, help="角色裁决值（advance 时记录到 checkpoint）")
    parser.add_argument("--from-steps", default="", help="JSON array: dispatch 来源 step 列表（set_status+executing 专用）")
    args = parser.parse_args()

    # workspace-centric：state_path 从 ws_id 推导
    if not args.state_path:
        args.state_path = resolve_ws_state(args.workspace_id)

    state_dir = os.path.dirname(args.state_path)
    if state_dir:
        os.makedirs(state_dir, exist_ok=True)

    lock_path = args.state_path + ".lock"
    with open(lock_path, "w") as lock_file:
        if not acquire_lock(lock_file):
            output_failure("OIC-E202", "获取文件锁失败")

        # v3.2: try/except/finally 结构确保锁在任何情况下都被释放
        state = None
        try:
            if os.path.exists(args.state_path):
                try:
                    with open(args.state_path, "r", encoding="utf-8") as f:
                        state = json.load(f)
                except (json.JSONDecodeError, ValueError):
                    raise ValidationException("OIC-E203", "STATE.json 格式损坏")
            else:
                state = create_initial_state()

            target = state

            validate_action(target, args.action, args.step)

            if args.action == "rollback":
                do_rollback(target, args.step)
            elif args.action == "reset":
                do_reset(target)
            elif args.action == "advance":
                do_advance(target, args.step, args.role, args.dispatch_id, args.verdict)
            elif args.action == "resume":
                do_resume(target, args.step)
            elif args.action == "terminal":
                target["terminal_state"] = args.terminal_state or "COMPLETE"
            elif args.action == "set_status":
                if not args.status:
                    raise ValidationException("OIC-E201", "set_status 需要 --status 参数")
                from_steps = None
                if args.from_steps:
                    try:
                        from_steps = json.loads(args.from_steps)
                    except (json.JSONDecodeError, ValueError):
                        pass
                do_set_status(target, args.step, args.status, args.role, args.dispatch_id, from_steps)

            append_history(state, args.action, args.step, "success")

            # v-longrun-R4: 原子写入——先写临时文件再 rename
            _atomic_write_state(args.state_path, state)

            release_lock(lock_file)
            output_success(state)
        except ValidationException as ve:
            release_lock(lock_file)
            output_failure(ve.error_code, ve.message)
        except Exception as e:
            if state is not None:
                append_history(state, args.action, args.step, f"failure: {e}")
                _atomic_write_state(args.state_path, state)
            release_lock(lock_file)
            output_failure("OIC-E207", str(e))

if __name__ == "__main__":
    main()
