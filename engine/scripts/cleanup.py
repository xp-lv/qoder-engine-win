#!/usr/bin/env python3
"""cleanup.py — 清理 workspace 运行数据

用法：
  python engine/scripts/cleanup.py                  # 预览（dry-run）
  python engine/scripts/cleanup.py --execute        # 实际执行清理

清理规则：
  1. WORKSPACE_ROOT 指向的目录不存在 → 删整个 ws 目录
  2. terminal_state=completed 的 ws → 删 STATE.json（保留外部产出物）
"""
import argparse
import json
import os
import shutil

WORKSPACES_DIR = os.path.join("runtime", "workspaces")


def main():
    parser = argparse.ArgumentParser(description="清理 workspace 运行数据")
    parser.add_argument("--execute", action="store_true", help="实际执行清理（默认 dry-run）")
    parser.add_argument("--workspace-id", default=None, help="只清理指定 workspace")
    args = parser.parse_args()

    mode = "执行" if args.execute else "预览（dry-run）"
    print(f"=== 清理{mode} ===\n")

    if not os.path.isdir(WORKSPACES_DIR):
        print("无 workspace 目录。")
        return

    cleaned = []

    for ws_id in sorted(os.listdir(WORKSPACES_DIR)):
        if args.workspace_id and ws_id != args.workspace_id:
            continue

        ws_dir = os.path.join(WORKSPACES_DIR, ws_id)
        if not os.path.isdir(ws_dir):
            continue

        state_f = os.path.join(ws_dir, "STATE.json")
        ws_root_f = os.path.join(ws_dir, "WORKSPACE_ROOT")

        # 读 WORKSPACE_ROOT
        ws_root = ""
        if os.path.exists(ws_root_f):
            with open(ws_root_f) as f:
                ws_root = f.read().strip()

        # 读 STATE.json
        terminal = None
        if os.path.exists(state_f):
            try:
                with open(state_f, "r", encoding="utf-8-sig") as f:
                    st = json.load(f)
                terminal = st.get("terminal_state")
            except Exception:
                pass

        # 规则 1：WORKSPACE_ROOT 指向的目录不存在 → 删整个 ws
        if ws_root and not os.path.isdir(ws_root):
            cleaned.append({
                "type": "orphan_workspace",
                "target": ws_dir,
                "reason": f"WORKSPACE_ROOT 指向的目录不存在: {ws_root}",
                "delete_state_only": False,
            })
            continue

        # 规则 2：已完成 → 删 STATE.json
        if terminal == "completed":
            cleaned.append({
                "type": "completed",
                "target": state_f,
                "reason": f"terminal_state=completed",
                "delete_state_only": True,
            })

    if not cleaned:
        print("无需清理。")
        return

    print(f"待清理 {len(cleaned)} 项：")
    for c in cleaned:
        print(f"  [{c['type']}] {c['target']}")
        print(f"    原因: {c['reason']}")

    if not args.execute:
        print(f"\n（dry-run 模式，加 --execute 实际清理）")
        return

    print("\n执行清理...")
    for c in cleaned:
        target = c["target"]
        if c["delete_state_only"]:
            if os.path.exists(target):
                os.remove(target)
                print(f"  ✅ 删除 {target}")
        else:
            if os.path.exists(target):
                shutil.rmtree(target)
                print(f"  ✅ 删除 {target}")
    print("清理完成。")


if __name__ == "__main__":
    main()
