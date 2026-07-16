#!/usr/bin/env python3
"""fix.py — 扰动修复脚本（v5.0: jump 重写为 DAG 正向可达集清除）。
支持的操作：
  reset: 全量重置 STATE（清空所有进度，回到初始状态）
  jump:  回退到指定步骤重新执行（清除 target 及其后继，保留前序）

v5.0 jump 语义变更：
  - 旧版（v4.x）：线性数组前缀标记 completed + 无 verdict → 违反 INV-5/7
  - 新版（v5.0）：DAG 正向可达集清除，不创建任何 completed 条目
  - 只支持回退（target 已在 completed 或为 entry），不支持前进跳过

Usage: python scripts/fix.py --type <reset|jump> [--step <STEP_N>] [--state-path <path>]
"""
import argparse, json, os, sys, subprocess
from collections import deque
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path
from state_io import load_state, save_state

# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def output(data):
    print(json.dumps(data, ensure_ascii=False))
    sys.exit(0 if data.get("status") == "success" else 1)


def main():
    parser = argparse.ArgumentParser(description="扰动修复（v5.0: jump DAG 重写）")
    parser.add_argument("--type", required=True, choices=["reset", "jump"])
    parser.add_argument("--step", default=None, help="目标 STEP（jump 必填）")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--workspace-id", default=None, help="Session ID")
    args = parser.parse_args()
    # workspace-centric：state_path 从 ws_id 推导
    if not args.state_path:
        args.state_path = resolve_ws_state(args.workspace_id)
    app_path = resolve_app_path(args.workspace_id)

    # ── jump：DAG 正向可达集清除 ──
    if args.type == "jump":
        if not args.step:
            output({"status": "failure", "error_code": "OIC-E104", "message": "jump 需要 --step 参数", "new_state_snapshot": None})
        state = _do_jump(args.state_path, app_path, args.workspace_id, args.step)
        output({"status": "success", "error_code": None, "new_state_snapshot": state, "message": f"jumped to {args.step}"})

    # ── reset：全量重置 ──
    cmd = [sys.executable, "engine/scripts/set_state.py", "--action", "reset", "--step", "ALL", "--state-path", args.state_path]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10, encoding="utf-8", errors="replace", env={**os.environ, "PYTHONIOENCODING": "utf-8"})
        if result.returncode == 0:
            data = json.loads(result.stdout)
            output({"status": data.get("status", "failure"), "error_code": data.get("error_code"), "new_state_snapshot": data.get("new_state")})
        else:
            output({"status": "failure", "error_code": "OIC-E103", "message": f"set_state.py 退出码 {result.returncode}: {result.stderr}", "new_state_snapshot": None})
    except Exception as e:
        output({"status": "failure", "error_code": "OIC-E103", "message": f"set_state.py 调用异常: {e}", "new_state_snapshot": None})


def _build_forward_adjacency(router_steps):
    """构建正向邻接表（排除自环和 backward 边）。

    返回: {source_step: set(target_step1, target_step2, ...)}
    只包含 normal 类型边（forward 语义）。
    backward 边是回退语义（如 Gate FAIL 后重试），不算正向后继。
    """
    forward = {}
    for s in router_steps:
        sn = s.get("step", "")
        for verdict, t_info in s.get("transitions", {}).items():
            targets = t_info.get("targets", []) if isinstance(t_info, dict) else []
            t_type = t_info.get("type", "normal") if isinstance(t_info, dict) else "normal"
            if t_type == "backward":
                continue  # 排除 backward 边
            for tgt in targets:
                if tgt != sn:  # 排除自环
                    forward.setdefault(sn, set()).add(tgt)
    return forward


def _reachable_from(target, forward_adj):
    """正向 BFS：从 target 出发能到达的所有节点（含 target 自身）。"""
    visited = {target}
    queue = deque([target])
    while queue:
        node = queue.popleft()
        for tgt in forward_adj.get(node, set()):
            if tgt not in visited:
                visited.add(tgt)
                queue.append(tgt)
    return visited


def _find_direct_predecessors(target, router_steps):
    """找到 target 的直接前驱：谁的 normal 边指向 target。

    排除 backward 边（backward 边是回退语义，不是真正的前驱关系）。
    """
    direct_preds = set()
    for s in router_steps:
        sn = s.get("step", "")
        if sn == target:
            continue
        for verdict, t_info in s.get("transitions", {}).items():
            targets = t_info.get("targets", []) if isinstance(t_info, dict) else []
            t_type = t_info.get("type", "normal") if isinstance(t_info, dict) else "normal"
            if target in targets and t_type != "backward":
                direct_preds.add(sn)
                break
    return direct_preds


def _do_jump(state_path, app_path, workspace_id, target_step):
    """v5.0 jump 核心逻辑：DAG 正向可达集清除。

    语义：回退到 target_step 重新执行。
    1. 验证 target_step 合法（在 ROUTER 中，且是回退不是前进）
    2. 沿 DAG 正向边计算 target 及其后继集
    3. 从 completed/pending_routes 中清除 target 及后继
    4. 清除 step_status / pending_dispatches / cached_branch_results
    5. 将 target 的直接前驱写入 pending_routes（让 --next 重新 dispatch target）
    """
    # 读取 STATE.json
    state = load_state(state_path)
    if state is None:
        output({"status": "failure", "error_code": "OIC-E102", "message": "STATE.json 不存在或无法解析", "new_state_snapshot": None})

    # 读取 ROUTER.json
    router_path = os.path.join(app_path, "ROUTER.json")
    if not os.path.exists(router_path):
        output({"status": "failure", "error_code": "OIC-E104", "message": f"ROUTER.json 不存在: {router_path}", "new_state_snapshot": None})
    with open(router_path, "r", encoding="utf-8-sig") as f:
        router_data = json.load(f)
    router_steps = router_data.get("steps", [])
    entry_step = router_data.get("entry", "")

    all_step_ids = [s.get("step", "") for s in router_steps]
    if target_step not in all_step_ids:
        output({"status": "failure", "error_code": "OIC-E104", "message": f"--step {target_step} 不在路由表中，可用: {all_step_ids}", "new_state_snapshot": None})

    completed = state.get("completed", {})

    # 验证：不支持前进跳过（target 既不在 completed 也不是 entry）
    if target_step not in completed and target_step != entry_step:
        output({
            "status": "failure",
            "error_code": "OIC-E105",
            "message": f"jump 仅支持回退到已完成的步骤。'{target_step}' 尚未执行过（不在 completed 中），前进跳过不被支持。",
            "new_state_snapshot": None,
        })

    # 1. 确定要清除的步骤集
    # 使用 completed 中的 created_at 时间戳来确定后继：
    # target 及其在 completed 中时间戳 >= target 的步骤都需要清除。
    # 这避免了 DAG 中 "回退型 normal 边"（如 裁决审计者→架构执行者）导致的过度清除。
    target_ckpt = completed.get(target_step, {})
    target_time = target_ckpt.get("created_at", "") if isinstance(target_ckpt, dict) else ""

    to_clear = set()
    # target 本身
    to_clear.add(target_step)
    # completed 中时间戳 >= target 的步骤（即 target 之后执行的步骤）
    for step, ckpt in completed.items():
        if step == target_step:
            continue
        step_time = ckpt.get("created_at", "") if isinstance(ckpt, dict) else ""
        if step_time and target_time and step_time >= target_time:
            to_clear.add(step)

    # 如果 target 不在 completed（是 entry），清除全部 completed
    if target_step == entry_step and target_step not in completed:
        to_clear = set(completed.keys()) | {target_step}
        to_clear.discard(target_step)  # entry 不需要清除自己（它不在 completed 中）

    # 2. 从 completed/pending_routes 中清除 target 及后继
    pending_routes = state.get("pending_routes", {})
    cleared_completed = []
    cleared_routes = []
    for step in to_clear:
        if step in completed:
            del completed[step]
            cleared_completed.append(step)
        if step in pending_routes:
            del pending_routes[step]
            cleared_routes.append(step)

    state["completed"] = completed
    state["pending_routes"] = pending_routes

    # 3. 清除 step_status / pending_dispatches / cached_branch_results
    state["step_status"] = {}
    state["pending_dispatches"] = None
    state["cached_branch_results"] = []

    # 4. 将 target 的直接前驱写入 pending_routes
    # 让 --next 冷路径能从这些前驱出发重新 dispatch target
    direct_preds = _find_direct_predecessors(target_step, router_steps)
    restored_routes = []
    for pred in direct_preds:
        if pred in completed:
            pending_routes[pred] = completed[pred]
            restored_routes.append(pred)

    state["pending_routes"] = pending_routes

    # 5. 如果 target 是 entry（无前驱），清空 pending_routes 让 --next 走初始调度
    if target_step == entry_step and not restored_routes:
        state["pending_routes"] = {}

    # 6. 写入
    save_state(state_path, state)

    print(
        f"[fix v5.0] jump to {target_step}: "
        f"cleared {len(cleared_completed)} completed, "
        f"restored {len(restored_routes)} pending_routes",
        file=sys.stderr,
    )
    return state


if __name__ == "__main__":
    main()
