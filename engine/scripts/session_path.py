"""Workspace-centric 路径推导工具（所有引擎脚本共用）。"""
import os

RUNTIME_BASE = "runtime"
WORKSPACES_DIR = os.path.join(RUNTIME_BASE, "workspaces")


def get_app_name(app_path):
    return os.path.basename(app_path.rstrip("/"))


def derive_ws_id(workspace_path):
    return os.path.basename(os.path.abspath(workspace_path.rstrip("/")))


def resolve_ws_base(ws_id):
    return os.path.join(WORKSPACES_DIR, ws_id)


def resolve_ws_state(ws_id):
    return os.path.join(resolve_ws_base(ws_id), "STATE.json")


def resolve_ws_process(ws_id):
    ws_root = read_workspace_root(ws_id)
    if ws_root:
        return os.path.join(ws_root, "process")
    return os.path.join(resolve_ws_base(ws_id), "process")


def read_app_ref(ws_id):
    app_ref_f = os.path.join(resolve_ws_base(ws_id), "APP_REF")
    if os.path.exists(app_ref_f):
        with open(app_ref_f, "r") as f:
            return f.read().strip()
    raise FileNotFoundError(f"workspace {ws_id} 没有 APP_REF")


def read_workspace_root(ws_id):
    ws_root_f = os.path.join(resolve_ws_base(ws_id), "WORKSPACE_ROOT")
    if os.path.exists(ws_root_f):
        with open(ws_root_f, "r") as f:
            return f.read().strip()
    return None


def resolve_app_path(ws_id=None, explicit=None):
    if explicit:
        return explicit
    if ws_id:
        return read_app_ref(ws_id)
    raise ValueError("需要 ws_id 或 explicit app_path")


def resolve_workspace_output(ws_id, relative_path, app_path=None, output_type="deliverable"):
    if output_type in ("process", "runtime"):
        return os.path.join(resolve_ws_process(ws_id), relative_path)
    if output_type == "knowledge" and app_path:
        return os.path.join(app_path, relative_path)
    ws_root = read_workspace_root(ws_id)
    if ws_root:
        return os.path.join(ws_root, relative_path)
    return os.path.join(resolve_ws_base(ws_id), relative_path)


def get_edge_targets(transitions, key):
    edge = transitions.get(key)
    if edge is None:
        return []
    if isinstance(edge, dict):
        return edge.get("targets", [])
    return []


def is_edge_backward(transitions, key):
    edge = transitions.get(key)
    if isinstance(edge, dict):
        return edge.get("type") == "backward"
    return False

