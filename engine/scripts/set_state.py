#!/usr/bin/env python3
"""set_state.py — STATE.json 状态操作 CLI。
所有修改通过 state_io.save_state() 统一写入。
Usage: python scripts/set_state.py --action <action> --step <STEP_N> [options]
"""
import argparse, json, os, sys, copy, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state
from state_io import load_state, save_state
from datetime import datetime, timezone


# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


class ValidationException(Exception):
    def __init__(self, error_code, message):
        self.error_code = error_code
        self.message = message
        super().__init__(message)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

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
        "completed": {},
        "pending_routes": {},
        "edge_counts": {},
        "pending_dispatches": None,
        "active_dispatches": {},
        "cached_branch_results": [],
        "engine_error": None,
        "history": [],
        "metadata": {"started_at": now_iso(), "last_advance_at": None, "user_request": ""}
    }

def validate_action(state, action, step):
    if state.get("terminal_state") is not None and action not in ("terminal", "reset"):
        raise ValidationException("OIC-E206", f"终态不可变：terminal_state={state['terminal_state']}")

# v4.2: do_rollback 已删除。僵尸 executing 清理由 state_health_check.py Z1 统一接管。

def do_reset(state):
    state["step_status"] = {}
    state["completed"] = {}
    state["pending_routes"] = {}
    state["edge_counts"] = {}
    state["terminal_state"] = None
    state["pending_dispatches"] = None
    state["active_dispatches"] = {}
    state["cached_branch_results"] = []
    state["engine_error"] = None
    state["history"] = []


def _save_snapshot(state_path, step, state):
    """v7.0: 在 advance 后保存快照，用于 jump 快速还原。

    快照保留路由字段（completed / pending_routes / edge_counts / terminal_state / history / metadata），
    清除运行时字段（step_status / pending_dispatches / cached_branch_results / active_dispatches）。
    """
    snapshot_dir = os.path.join(os.path.dirname(state_path), "snapshots")
    os.makedirs(snapshot_dir, exist_ok=True)
    snapshot_path = os.path.join(snapshot_dir, f"{step}.json")

    snapshot = copy.deepcopy(state)
    snapshot["step_status"] = {}
    snapshot["pending_dispatches"] = None
    snapshot["cached_branch_results"] = []
    snapshot["active_dispatches"] = {}

    with open(snapshot_path, "w", encoding="utf-8") as f:
        json.dump(snapshot, f, ensure_ascii=False, indent=2)


def _clear_snapshots(state_path):
    """v7.0: reset 时清理快照目录。"""
    snapshot_dir = os.path.join(os.path.dirname(state_path), "snapshots")
    if os.path.exists(snapshot_dir):
        shutil.rmtree(snapshot_dir)

def do_advance(state, step, role, dispatch_id, verdict=None):
    # v7.1: advance 成功 → 清除 engine_error 标志位
    state["engine_error"] = None
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
    state.setdefault("completed", {})[step] = result
    state.setdefault("pending_routes", {})[step] = result
    state["metadata"]["last_advance_at"] = now_iso()
    # v6.0: 清理 active_dispatches 中已完成 step 的 dispatch 缓存
    active = state.get("active_dispatches")
    if active and step in active:
        del active[step]

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

def do_set_status(state, step, status, role, dispatch_id, from_steps=None):
    ss = state.get("step_status", {})
    if status == "idle":
        if step in ss:
            del ss[step]
    else:
        entry = {"role": role or ss.get(step, {}).get("role", ""), "status": status, "dispatch_id": dispatch_id or ss.get(step, {}).get("dispatch_id", "")}
        if status == "executing":
            entry["started_at"] = now_iso()
            if from_steps:
                entry["from_steps"] = from_steps
        ss[step] = entry
    state["step_status"] = ss

MAX_HISTORY_SIZE = 500

def append_history(state, action, step, result):
    state.setdefault("history", []).append({
        "timestamp": now_iso(), "action": action, "step": step,
        "actor": "set_state.py", "result": result
    })
    if len(state["history"]) > MAX_HISTORY_SIZE:
        state["history"] = state["history"][-MAX_HISTORY_SIZE:]

def main():
    parser = argparse.ArgumentParser(description="STATE.json 状态操作 CLI")
    parser.add_argument("--action", required=True, choices=["reset", "advance", "resume", "terminal", "set_status"])
    parser.add_argument("--step", required=True, help="目标 STEP 编号（terminal 可用 ALL）")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--workspace-id", default=None)
    parser.add_argument("--terminal-state", help="终态枚举")
    parser.add_argument("--terminal-reason", help="终态原因")
    parser.add_argument("--status", help="执行状态（set_status 专用）")
    parser.add_argument("--role", help="角色名（set_status+executing 专用）")
    parser.add_argument("--dispatch-id", help="dispatch checkpoint_id")
    parser.add_argument("--verdict", default=None, help="角色裁决值")
    parser.add_argument("--from-steps", default="", help="JSON array: dispatch 来源 step 列表")
    args = parser.parse_args()

    if not args.state_path:
        args.state_path = resolve_ws_state(args.workspace_id)

    state = load_state(args.state_path)
    if state is None:
        state = create_initial_state()

    try:
        validate_action(state, args.action, args.step)

        if args.action == "reset":
            do_reset(state)
            _clear_snapshots(args.state_path)
        elif args.action == "advance":
            do_advance(state, args.step, args.role, args.dispatch_id, args.verdict)
            _save_snapshot(args.state_path, args.step, state)
        elif args.action == "resume":
            do_resume(state, args.step)
        elif args.action == "terminal":
            state["terminal_state"] = args.terminal_state or "COMPLETE"
        elif args.action == "set_status":
            if not args.status:
                raise ValidationException("OIC-E201", "set_status 需要 --status 参数")
            from_steps = None
            if args.from_steps:
                try:
                    from_steps = json.loads(args.from_steps)
                except (json.JSONDecodeError, ValueError):
                    pass
            do_set_status(state, args.step, args.status, args.role, args.dispatch_id, from_steps)

        append_history(state, args.action, args.step, "success")
        save_state(args.state_path, state)
        output_success(state)
    except ValidationException as ve:
        output_failure(ve.error_code, ve.message)
    except Exception as e:
        if state is not None:
            append_history(state, args.action, args.step, f"failure: {e}")
            try:
                save_state(args.state_path, state)
            except Exception:
                pass
        output_failure("OIC-E207", str(e))

if __name__ == "__main__":
    main()
