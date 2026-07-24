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


# v9.2: resolve_ws_process 已删除（process 目录机制已废弃）


def read_app_ref(ws_id):
    app_ref_f = os.path.join(resolve_ws_base(ws_id), "APP_REF")
    if os.path.exists(app_ref_f):
        with open(app_ref_f, "r", encoding="utf-8-sig") as f:
            return f.read().strip()
    raise FileNotFoundError(f"workspace {ws_id} 没有 APP_REF")


def read_workspace_root(ws_id):
    ws_root_f = os.path.join(resolve_ws_base(ws_id), "WORKSPACE_ROOT")
    if os.path.exists(ws_root_f):
        with open(ws_root_f, "r", encoding="utf-8-sig") as f:
            return f.read().strip()
    return None


def resolve_app_path(ws_id=None, explicit=None):
    if explicit:
        return explicit
    if ws_id:
        return read_app_ref(ws_id)
    raise ValueError("需要 ws_id 或 explicit app_path")


def resolve_workspace_output(ws_id, path, app_path=None, output_type=None, is_absolute=False):
    """将 app.yaml 中的路径 resolve 为绝对路径。

    三种路径模式：
    1. knowledge 类型（output_type="knowledge"）→ app_path + path（app 内置资产）
    2. abs_path（is_absolute=True）→ 直接返回（工作区外部路径）
    3. path（相对路径）→ WORKSPACE_ROOT + path（工作区内产物）

    参数 output_type 用于区分 knowledge 资产（路由到 app 包）与普通产物（路由到工作区）。
    """
    # knowledge 类型路由到 app 包（app 内置资产，不跟随工作区）
    if output_type == "knowledge" and app_path:
        return os.path.join(app_path, path)

    # 显式声明的绝对路径，直接返回
    if is_absolute:
        return path

    # 相对路径：以 WORKSPACE_ROOT 为基准
    ws_root = read_workspace_root(ws_id)
    if not ws_root:
        raise FileNotFoundError(
            f"WORKSPACE_ROOT 不存在（ws_id={ws_id}）。"
            f"工作区可能未正确初始化，请检查 init.py 是否执行。"
        )
    return os.path.join(ws_root, path)


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

