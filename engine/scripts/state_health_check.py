#!/usr/bin/env python3
"""state_health_check.py — 基于 ROUTER.json 的全局 STATE 健康检测（v7.0: 仅检测不修复）。

v7.0 变更：
  - 移除 apply_fixes 函数和 --fix 执行逻辑。
  - 健康检测退化为纯报告模式，不再自动修复 STATE。
  - 自动修复引入不确定性（合法瞬态窗口被误判），已全部删除。
  - --fix 参数保留但为 no-op（向后兼容 Hook② 调用）。

v5.0: 基于 state_invariants.py 不变量体系。
  - B/C/D 层不变量校验
  - Z1 僵尸 executing 启发式（仅报告）
  - Z3 断裂 JOIN 检测（仅报告）

Usage:
  python3 state_health_check.py --workspace-id <ws_id> [--dry-run] [--fix]
  python3 state_health_check.py --state-path <path> --router-path <path> [--dry-run] [--fix]
"""
import argparse, json, os, sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path
from state_invariants import (
    Violation, validate_all, build_join_map,
)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def build_router_index(router_data):
    """从 ROUTER.json 构建拓扑索引。"""
    steps = router_data.get("steps", [])
    step_transitions = {}
    all_steps = set()

    for s in steps:
        step_name = s.get("step", "")
        all_steps.add(step_name)
        trans = s.get("transitions", {})
        step_transitions[step_name] = {}
        for verdict, t_info in trans.items():
            targets = t_info.get("targets", [])
            t_type = t_info.get("type", "normal")
            step_transitions[step_name][verdict] = {"targets": targets, "type": t_type}

    return {
        "step_transitions": step_transitions,
        "all_steps": all_steps,
        "entry": router_data.get("entry", ""),
    }


# ═══════════════════════════════════════════════════════════════
# Z1: 僵尸 executing 启发式（v6.0: 并行安全，仅报告不修复）
# ═══════════════════════════════════════════════════════════════

def _z1_zombie_heuristic(state):
    """Z1: 僵尸 executing 检测（v6.0: 并行安全版，仅报告）。

    v6.0: 不再自动标记 executing 为僵尸。
    并行场景下 step_status 中有 N 个 executing 是合法常态。
    实际清理由 Hook② 在确定时机执行（_clear_zombie_executing）。
    """
    return []


# ═══════════════════════════════════════════════════════════════
# Z3: 断裂 JOIN 检测（仅报告）
# ═══════════════════════════════════════════════════════════════

def _z3_broken_join_detection(state, router_idx, join_idx):
    """Z3: 路由来源已满足但目标未出现在调度通道中（仅报告）。"""
    findings = []
    completed = state.get("completed", {})
    step_status = state.get("step_status", {})
    pending_dispatches = state.get("pending_dispatches")
    pending_routes = state.get("pending_routes", {})
    cached_branch_results = state.get("cached_branch_results", [])

    step_transitions = router_idx["step_transitions"]

    _z3_candidates = {}
    for step, ckpt in completed.items():
        verdict = ckpt.get("verdict", "")
        trans = step_transitions.get(step, {}).get(verdict)
        if not trans:
            continue
        targets = trans.get("targets", [])
        for tgt in targets:
            if tgt in completed or tgt in step_status:
                continue
            _z3_candidates.setdefault(tgt, set()).add(step)

    for tgt, sources in _z3_candidates.items():
        join_groups = join_idx.get(tgt, [])
        should_dispatch = False
        satisfied_sources = list(sources)

        if join_groups:
            for group in join_groups:
                sources_in_completed = [s for s in group if s in completed]
                if len(sources_in_completed) == len(group):
                    should_dispatch = True
                    satisfied_sources = sources_in_completed
                    break
        else:
            should_dispatch = True

        if not should_dispatch:
            continue

        in_dispatches = False
        if pending_dispatches:
            in_dispatches = any(d.get("step") == tgt for d in pending_dispatches)
        in_pending_routes = any(s in pending_routes for s in satisfied_sources)

        if not in_dispatches and not in_pending_routes and not cached_branch_results:
            findings.append({
                "id": "Z3",
                "severity": "major",
                "category": "broken_join" if join_groups else "missing_dispatch",
                "description": f"目标 '{tgt}' 的路由来源已满足 ({', '.join(satisfied_sources)}) 但未出现在 pending_dispatches/pending_routes 中",
                "step": tgt,
                "fix_type": "regenerate_dispatch",
                "fix_data": {"step": tgt, "sources": satisfied_sources},
                "auto_fixable": False,  # v7.0: 不再自动修复
            })
    return findings


# ═══════════════════════════════════════════════════════════════
# 统一检测入口（仅检测，不修复）
# ═══════════════════════════════════════════════════════════════

def check_health(state, router_steps, join_map, entry_step=""):
    """执行健康检测，返回 findings 列表（仅报告，不修复）。"""
    findings = []

    violations = validate_all(state, router_steps, join_map, entry_step)
    for v in violations:
        findings.append({
            "id": v.inv_id,
            "severity": v.severity,
            "category": v.fix_type,
            "description": v.message,
            "step": v.step,
            "fix_type": v.fix_type,
            "fix_data": v.fix_data,
            "auto_fixable": False,  # v7.0: 全部标记为不可自动修复
        })

    findings.extend(_z1_zombie_heuristic(state))

    router_idx = build_router_index({"steps": router_steps, "entry": entry_step})
    findings.extend(_z3_broken_join_detection(state, router_idx, join_map))

    return findings


# ═══════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="全局 STATE 健康检测（v7.0: 仅检测不修复）")
    parser.add_argument("--workspace-id", default=None, help="工作区 ID")
    parser.add_argument("--state-path", default=None, help="STATE.json 路径")
    parser.add_argument("--router-path", default=None, help="ROUTER.json 路径")
    parser.add_argument("--dry-run", action="store_true", help="仅检测不修复（v7.0 后为默认行为）")
    parser.add_argument("--fix", action="store_true", help="已废弃（v7.0: 不再自动修复，等同于 --dry-run）")
    args = parser.parse_args()

    ws_id = args.workspace_id
    state_path = args.state_path
    if not state_path:
        state_path = resolve_ws_state(ws_id)
    if not state_path or not os.path.exists(state_path):
        print(json.dumps({"status": "error", "error": f"STATE.json 不存在: {state_path}"}))
        sys.exit(1)

    if args.router_path:
        router_path = args.router_path
        registry_path = args.router_path.replace("ROUTER.json", "registry.json")
    else:
        if not ws_id:
            ws_id = load_json(state_path).get("workspace_id", "default") if load_json(state_path) else "default"
        app_path = resolve_app_path(ws_id)
        router_path = os.path.join(app_path, "ROUTER.json")
        registry_path = os.path.join(app_path, "registry.json")

    state = load_json(state_path)
    router_data = load_json(router_path)
    registry_data = load_json(registry_path)

    if not state or not router_data:
        print(json.dumps({"status": "error", "error": "无法加载 STATE.json 或 ROUTER.json"}))
        sys.exit(1)

    router_steps = router_data.get("steps", [])
    entry_step = router_data.get("entry", "")
    join_map = build_join_map(registry_data or [])

    findings = check_health(state, router_steps, join_map, entry_step)

    critical = [f for f in findings if f["severity"] == "critical"]
    major = [f for f in findings if f["severity"] == "major"]
    minor = [f for f in findings if f["severity"] == "minor"]

    result = {
        "status": "healthy" if not critical and not major else "unhealthy",
        "workspace_id": ws_id or state.get("workspace_id", "?"),
        "summary": {
            "total_findings": len(findings),
            "critical": len(critical),
            "major": len(major),
            "minor": len(minor),
        },
        "findings": findings,
        "mode": "check",  # v7.0: 永远是 check 模式
    }

    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
