#!/usr/bin/env python3
"""workspace_index.py — 工作区注册表（唯一权威索引）。

v7.2: 工作区生命周期管理。
所有工作区的创建、活跃、终态、归档状态统一由本模块管理。

index.json 结构：
{
  "workspaces": {
    "ws_id": {
      "app": "apps/xxx",
      "status": "active | terminal | stale",
      "created_at": "...",
      "last_active_at": "...",
      "terminal_state": null,
      "completed_count": 0,
      "schema_version": "4.1",
      "has_snapshots": false
    }
  },
  "active_workspace": "ws_id"
}
"""
import json, os
from datetime import datetime, timezone

_PROJECT_ROOT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
)
_INDEX_PATH = os.path.join(_PROJECT_ROOT, "runtime", "workspaces", "index.json")


def _now():
    """返回本地时间（带时区偏移，ISO 8601）。"""
    return datetime.now().astimezone().isoformat(timespec='seconds')


def to_local_display(ts):
    """将 UTC 时间戳（'...Z'）转换为本地时间用于显示。

    - '2026-07-16T19:41:19Z' → '2026-07-17T03:41:19+08:00'
    - 已带时区偏移的或非时间字符串原样返回
    """
    if not ts or ts in ("?", "null", None):
        return ts
    try:
        if isinstance(ts, str) and ts.endswith("Z"):
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            return dt.astimezone().isoformat(timespec='seconds')
    except Exception:
        pass
    return ts


def _load():
    """加载 index.json，不存在则返回空结构。"""
    if os.path.exists(_INDEX_PATH):
        try:
            with open(_INDEX_PATH, "r", encoding="utf-8-sig") as f:
                return json.load(f)
        except (json.JSONDecodeError, ValueError):
            pass
    return {"workspaces": {}, "active_workspace": None}


def _save(index):
    """原子写入 index.json。"""
    os.makedirs(os.path.dirname(_INDEX_PATH), exist_ok=True)
    tmp = _INDEX_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
    os.replace(tmp, _INDEX_PATH)


def register(ws_id, app, schema_version="4.1"):
    """init 时调用：注册新工作区，设为 active。"""
    index = _load()
    index["workspaces"][ws_id] = {
        "app": app,
        "status": "active",
        "created_at": _now(),
        "last_active_at": _now(),
        "terminal_state": None,
        "completed_count": 0,
        "schema_version": schema_version,
        "has_snapshots": False,
    }
    index["active_workspace"] = ws_id
    _save(index)


def heartbeat(ws_id, completed_count=None, terminal_state=None, has_snapshots=None):
    """advance/submit 时调用：更新活跃时间。"""
    index = _load()
    ws = index["workspaces"].get(ws_id)
    if not ws:
        return
    ws["last_active_at"] = _now()
    if completed_count is not None:
        ws["completed_count"] = completed_count
    if terminal_state is not None:
        ws["terminal_state"] = terminal_state
        ws["status"] = "terminal"
    elif ws["status"] == "stale":
        ws["status"] = "active"
    if has_snapshots is not None:
        ws["has_snapshots"] = has_snapshots
    _save(index)


def set_active(ws_id):
    """switch 时调用：切换活跃工作区。"""
    index = _load()
    index["active_workspace"] = ws_id
    ws = index["workspaces"].get(ws_id)
    if ws and ws["status"] == "stale":
        ws["status"] = "active"
        ws["last_active_at"] = _now()
    _save(index)


def mark_reset(ws_id):
    """reset 时调用：重置状态。"""
    index = _load()
    ws = index["workspaces"].get(ws_id)
    if not ws:
        return
    ws["status"] = "active"
    ws["last_active_at"] = _now()
    ws["terminal_state"] = None
    ws["completed_count"] = 0
    ws["has_snapshots"] = False
    _save(index)


def get_active():
    """获取当前活跃工作区 ID。"""
    return _load().get("active_workspace")


def list_all():
    """列出所有工作区信息（供 --list-workspaces 使用）。"""
    return _load()


def sync_from_state(ws_id, state):
    """从 STATE.json 同步关键字段到 index（advance 后调用）。"""
    completed_count = len(state.get("completed", {}))
    terminal_state = state.get("terminal_state")
    ws_base = os.path.join(_PROJECT_ROOT, "runtime", "workspaces", ws_id)
    has_snapshots = os.path.exists(os.path.join(ws_base, "snapshots"))
    heartbeat(
        ws_id,
        completed_count=completed_count,
        terminal_state=terminal_state,
        has_snapshots=has_snapshots,
    )


def rebuild_index():
    """从现有 runtime/workspaces 目录重建 index.json。

    用于首次启用 index 机制时迁移已有工作区。
    """
    ws_root = os.path.join(_PROJECT_ROOT, "runtime", "workspaces")
    if not os.path.isdir(ws_root):
        return

    index = {"workspaces": {}, "active_workspace": None}

    for ws_id in sorted(os.listdir(ws_root)):
        ws_dir = os.path.join(ws_root, ws_id)
        if not os.path.isdir(ws_dir) or ws_id.startswith("_"):
            continue

        state_path = os.path.join(ws_dir, "STATE.json")
        app_ref_path = os.path.join(ws_dir, "APP_REF")

        # 读 APP_REF
        app = ""
        if os.path.exists(app_ref_path):
            try:
                with open(app_ref_path, "r", encoding="utf-8-sig") as f:
                    app = f.read().strip()
            except Exception:
                pass

        # 读 STATE
        if os.path.exists(state_path):
            try:
                with open(state_path, "r", encoding="utf-8-sig") as f:
                    st = json.load(f)
                terminal = st.get("terminal_state")
                completed_count = len(st.get("completed", {}))
                schema_ver = st.get("schema_version", "4.0")
                step_status = st.get("step_status", {})
            except Exception:
                terminal = None
                completed_count = 0
                schema_ver = "?"
                step_status = {}
        else:
            terminal = None
            completed_count = 0
            schema_ver = "?"
            step_status = {}

        has_snapshots = os.path.exists(os.path.join(ws_dir, "snapshots"))

        # 推断状态
        if terminal:
            status = "terminal"
        elif step_status:
            # 有 executing 但可能已死 → 标记 stale
            status = "stale"
        elif completed_count > 0:
            status = "active"
        else:
            status = "stale"

        index["workspaces"][ws_id] = {
            "app": app or "?",
            "status": status,
            "created_at": to_local_display(st.get("metadata", {}).get("started_at", "?")) if os.path.exists(state_path) else "?",
            "last_active_at": to_local_display(st.get("metadata", {}).get("last_advance_at", "?")) if os.path.exists(state_path) else "?",
            "terminal_state": terminal,
            "completed_count": completed_count,
            "schema_version": schema_ver,
            "has_snapshots": has_snapshots,
        }

    _save(index)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="工作区注册表管理")
    parser.add_argument("--rebuild", action="store_true", help="从现有目录重建 index.json")
    parser.add_argument("--list", action="store_true", help="列出所有工作区")
    args = parser.parse_args()

    if args.rebuild:
        rebuild_index()
        print("index.json 已重建")
    elif args.list:
        idx = list_all()
        active = idx.get("active_workspace")
        for ws_id, info in idx.get("workspaces", {}).items():
            marker = " ← active" if ws_id == active else ""
            print(f"  {ws_id}: status={info['status']} | app={info['app']} | completed={info['completed_count']} | snapshots={info['has_snapshots']}{marker}")
