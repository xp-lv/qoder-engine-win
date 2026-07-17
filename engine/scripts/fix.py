#!/usr/bin/env python3
"""fix.py — 扰动修复脚本（v7.0: jump 改为快照还原）。

支持的操作：
  reset: 全量重置 STATE（清空所有进度，回到初始状态）
  jump:  回退到指定步骤重新执行（还原该步骤完成时的快照）

v7.0 jump 语义变更：
  - v5.0 使用时间戳比较确定清除集——backward 重执行导致时间戳错序时断裂。
  - v6.0 改为 DAG 正向 BFS：沿 normal 边从 target 出发，清除全部正向后继。
    问题：交叉边（FRONTEND_BLOCKING/BACKEND_BLOCKING）污染可达集，
    edge_counts 被重置导致 JOIN 条件断裂，pending_routes 无法恢复 fork 点信号。
  - v7.0 改为快照还原：advance 时保存 STATE 快照，jump 时直接还原。
    快照天然保留路由字段（completed / pending_routes / edge_counts），
    无需计算清除集，无交叉边污染，无 edge_counts 丢失。

Usage: python3 scripts/fix.py --type <reset|jump> [--step <STEP_N>] [--state-path <path>]
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path
from state_io import load_state, save_state, state_txn


def output(data):
    print(json.dumps(data, ensure_ascii=False))
    sys.exit(0 if data.get("status") == "success" else 1)


def main():
    parser = argparse.ArgumentParser(description="扰动修复（v7.0: jump 快照还原）")
    parser.add_argument("--type", required=True, choices=["reset", "jump"])
    parser.add_argument("--step", default=None, help="目标 STEP（jump 必填）")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--workspace-id", default=None, help="Session ID")
    args = parser.parse_args()

    if not args.state_path:
        args.state_path = resolve_ws_state(args.workspace_id)

    # ── jump：快照还原 ──
    if args.type == "jump":
        if not args.step:
            output({"status": "failure", "error_code": "OIC-E104",
                    "message": "jump 需要 --step 参数", "new_state_snapshot": None})
        state = _do_jump(args.state_path, args.step)
        # v7.2: 更新工作区索引
        try:
            from workspace_index import sync_from_state
            sync_from_state(args.workspace_id or "default", state)
        except Exception:
            pass
        output({"status": "success", "error_code": None,
                "new_state_snapshot": state, "message": f"jumped to {args.step}"})

    # ── reset：全量重置 ──
    cmd = [sys.executable, "engine/scripts/set_state.py", "--action", "reset",
           "--step", "ALL", "--state-path", args.state_path]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            data = json.loads(result.stdout)
            output({"status": data.get("status", "failure"),
                    "error_code": data.get("error_code"),
                    "new_state_snapshot": data.get("new_state")})
        else:
            output({"status": "failure", "error_code": "OIC-E103",
                    "message": f"set_state.py 退出码 {result.returncode}: {result.stderr}",
                    "new_state_snapshot": None})
    except Exception as e:
        output({"status": "failure", "error_code": "OIC-E103",
                "message": f"set_state.py 调用异常: {e}", "new_state_snapshot": None})


def _do_jump(state_path, target_step):
    """v7.0 jump 核心逻辑：快照还原。

    语义：回退到 target_step 重新执行。
    1. 验证 target_step 合法（在 completed 中，是回退不是前进）
    2. 加载该步骤 advance 时保存的快照
    3. 原子写入 STATE.json

    快照保留了 advance 时刻的完整路由状态：
    - completed: 该步骤及其前序步骤的 checkpoint
    - pending_routes: 路由信号（含 fork 点信号）
    - edge_counts: JOIN 计数
    - terminal_state / history / metadata

    快照清除了运行时状态：
    - step_status: executing 分支已失效
    - pending_dispatches: 由 --next 重新生成
    - cached_branch_results: Hook② 私有缓存
    - active_dispatches: dispatch 运行时缓存
    """
    # 1. 验证 target 合法
    st_check = load_state(state_path)
    if st_check is None:
        output({"status": "failure", "error_code": "OIC-E102",
                "message": "STATE.json 不存在或无法解析", "new_state_snapshot": None})

    completed_check = st_check.get("completed", {})
    if target_step not in completed_check:
        output({
            "status": "failure",
            "error_code": "OIC-E105",
            "message": f"jump 仅支持回退到已完成的步骤。'{target_step}' 尚未执行过（不在 completed 中），前进跳过不被支持。",
            "new_state_snapshot": None,
        })

    # 2. 加载快照
    snapshot_path = os.path.join(os.path.dirname(state_path), "snapshots", f"{target_step}.json")
    if not os.path.exists(snapshot_path):
        output({"status": "failure", "error_code": "OIC-E106",
                "message": f"快照不存在: {snapshot_path}。该工作区可能创建于 v7.0 之前。",
                "new_state_snapshot": None})

    with open(snapshot_path, "r", encoding="utf-8") as f:
        snapshot = json.load(f)

    # 3. 原子写入（state_txn 保证锁 + 不变量校验）
    with state_txn(state_path) as st:
        st.clear()
        st.update(snapshot)

        # v7.3: 恢复并行兄弟分支
        # 快照中 step_status/active_dispatches 含有 jump 时刻正在执行的兄弟分支
        # 时间回退后没有实际 agent 在跑，需将它们的 dispatch 指令转入 pending_dispatches 重新分发
        snap_ss = st.get("step_status", {})
        snap_active = st.get("active_dispatches", {})

        sibling_dispatches = []
        for step_name, entry in snap_ss.items():
            if step_name == target_step:
                continue
            if entry.get("status") == "executing" and step_name in snap_active:
                sibling_dispatches.append(snap_active[step_name])

        if sibling_dispatches:
            existing_pd = st.get("pending_dispatches") or []
            st["pending_dispatches"] = existing_pd + sibling_dispatches
            sibling_names = [d.get("step", "?") for d in sibling_dispatches]
            print(
                f"[fix v7.3] jump to {target_step}: "
                f"restored {len(sibling_dispatches)} sibling branch(es): {sibling_names}",
                file=sys.stderr,
            )

        # 清除僵尸 step_status 和 active_dispatches（已转入 pending_dispatches 或无需恢复）
        st["step_status"] = {}
        st["active_dispatches"] = {}
    cleared_count = len(completed_check) - len(snapshot.get("completed", {}))
    print(
        f"[fix v7.3] jump to {target_step}: "
        f"restored snapshot (cleared {cleared_count} downstream checkpoints)",
        file=sys.stderr,
    )
    return load_state(state_path)


if __name__ == "__main__":
    import subprocess  # reset 路径需要
    main()
