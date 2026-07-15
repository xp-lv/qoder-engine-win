#!/usr/bin/env python3
"""switch.py — 切换 workspace 绑定的应用

用法：
  python3 engine/scripts/switch.py --workspace-id <id> --app-path <目标应用包>
"""
import argparse, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_base, resolve_ws_state, read_app_ref


def main():
    parser = argparse.ArgumentParser(description="切换 workspace 绑定的应用")
    parser.add_argument("--workspace-id", required=True, help="workspace 编号")
    parser.add_argument("--app-path", required=True, help="目标应用包路径")
    args = parser.parse_args()

    ws_base = resolve_ws_base(args.workspace_id)
    if not os.path.isdir(ws_base):
        print(json.dumps({"status": "failure", "error": f"workspace {args.workspace_id} 不存在"}, ensure_ascii=False))
        sys.exit(1)

    # 读旧 APP_REF
    old_app = ""
    app_ref_f = os.path.join(ws_base, "APP_REF")
    if os.path.exists(app_ref_f):
        with open(app_ref_f) as f:
            old_app = f.read().strip()

    # 写新 APP_REF
    with open(app_ref_f, "w") as f:
        f.write(args.app_path)

    # 读取当前状态快照
    state_f = resolve_ws_state(args.workspace_id)
    state_snapshot = {}
    if os.path.exists(state_f):
        try:
            with open(state_f, "r", encoding="utf-8") as f:
                s = json.load(f)
            state_snapshot = {
                "executing": list(s.get("step_status", {}).keys()),
                "completed": list(s.get("completed", {}).keys()),
                "terminal": s.get("terminal_state"),
            }
        except Exception:
            state_snapshot = {"error": "STATE.json 读取失败"}
    else:
        state_snapshot = {"needs_init": True}

    print(json.dumps({
        "status": "success",
        "message": f"应用已切换: {old_app} -> {args.app_path}",
        "workspace_id": args.workspace_id,
        "app_path": args.app_path,
        "state_snapshot": state_snapshot,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
