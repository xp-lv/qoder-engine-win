#!/usr/bin/env python3
"""state_health_check.py — 基于 ROUTER.json 的全局 STATE 健康检测与修复。

v5.0: 基于 state_invariants.py 不变量体系重构。
  - INV-1 ~ INV-9 替代原 Z2-Z6 散落检查
  - Z1 僵尸 executing 保留为独立启发式（不是不变量，是运行时推断）
  - Z3 断裂 JOIN 检测保留（INV 体系不覆盖"应调度但未调度"的逆向检测）
  - Z1 rollback 修复：只删 SS 不删 CP（重执行场景保护）

Usage:
  python state_health_check.py --workspace-id <ws_id> [--dry-run] [--fix]
  python state_health_check.py --state-path <path> --router-path <path> [--dry-run] [--fix]
"""
import argparse, json, os, sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path
from state_io import save_state
from state_invariants import (
    Violation, validate_all, build_join_map, check_basic,
    check_structural, check_causal,
)


# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None


def build_router_index(router_data):
    """从 ROUTER.json 构建拓扑索引（Z3 专用，INV 体系自带图遍历）。"""
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
# Z1: 僵尸 executing 启发式（保留，独立于不变量体系）
# ═══════════════════════════════════════════════════════════════

def _z1_zombie_heuristic(state):
    """Z1: 僵尸 executing 检测（运行时推断，非不变量）。

    推断依据：health_check 在 stability-analyzer 返回时运行，
    此时如果有 executing 状态，说明上一个 role-executor 已经结束（正常返回或被取消），
    其 executing 状态是残留的。

    v5.0 修复：rollback 只删 step_status，不删 completed。
    重执行场景下 CP 中的记录是上一轮的合法完成记录，不应被清理。
    """
    findings = []
    ss = state.get("step_status", {})
    for step, info in ss.items():
        if isinstance(info, dict) and info.get("status") == "executing":
            findings.append({
                "id": "Z1",
                "severity": "critical",
                "category": "zombie_executing",
                "description": f"步骤 '{step}' 处于 executing 但无活跃 Task（可能被取消或崩溃）",
                "step": step,
                "fix_type": "clear_zombie_executing",
                "fix_data": {"step": step},
                "auto_fixable": True,
            })
    return findings


# ═══════════════════════════════════════════════════════════════
# Z3: 断裂 JOIN 检测（保留，INV 体系不覆盖此逆向检测）
# ═══════════════════════════════════════════════════════════════

def _z3_broken_join_detection(state, router_idx, join_idx):
    """Z3: 路由来源已满足但目标未出现在调度通道中。

    这不是 STATE 不变量违反，而是"STATE 应该有但没有"的缺失检测。
    INV 体系检查"STATE 中有的东西是否合法"，Z3 检查"STATE 是否缺了应有东西"。
    """
    findings = []
    completed = state.get("completed", {})
    step_status = state.get("step_status", {})
    pending_dispatches = state.get("pending_dispatches")
    pending_routes = state.get("pending_routes", {})
    cached_branch_results = state.get("cached_branch_results", [])

    step_transitions = router_idx["step_transitions"]

    # 收集所有「路由目标未被调度」的候选
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
                "auto_fixable": True,
            })
    return findings


# ═══════════════════════════════════════════════════════════════
# 统一检测入口
# ═══════════════════════════════════════════════════════════════

def check_health(state, router_steps, join_map, entry_step=""):
    """v5.0: 执行健康检测 = 不变量校验 + Z1 启发式 + Z3 缺失检测。

    返回 findings 列表，格式与旧版兼容：
      {id, severity, category, description, step, fix_type, fix_data, auto_fixable}
    """
    findings = []

    # 1. 不变量校验（INV-1 ~ INV-9）
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
            "auto_fixable": v.auto_fixable,
        })

    # 2. Z1 僵尸 executing 启发式
    findings.extend(_z1_zombie_heuristic(state))

    # 3. Z3 断裂 JOIN 检测
    router_idx = build_router_index({"steps": router_steps, "entry": entry_step})
    findings.extend(_z3_broken_join_detection(state, router_idx, join_map))

    return findings


# ═══════════════════════════════════════════════════════════════
# 修复引擎
# ═══════════════════════════════════════════════════════════════

def apply_fixes(state, findings):
    """应用修复到 state（原地修改）。返回 (fixed_count, actions_log)。

    只修复 auto_fixable=True 的 finding。
    """
    actions = []
    for f in findings:
        if not f.get("auto_fixable", False):
            continue

        fix_type = f["fix_type"]
        step = f.get("step", "")
        fix_data = f.get("fix_data", {})

        # ── Z1: 清理僵尸 executing（v5.0: 只删 SS，不删 CP）──
        if fix_type == "clear_zombie_executing":
            target_step = fix_data.get("step", step)
            ss = state.get("step_status", {})
            if target_step in ss:
                del ss[target_step]
                actions.append(f"clear_zombie: {target_step}（仅清 step_status，保留 completed）")

        # ── INV-1: 删除非法步骤引用 ──
        elif fix_type == "remove_illegal_step_status":
            target_step = fix_data.get("step", step)
            ss = state.get("step_status", {})
            if target_step in ss:
                del ss[target_step]
                actions.append(f"remove_illegal_step_status: {target_step}")

        elif fix_type == "remove_illegal_completed":
            target_step = fix_data.get("step", step)
            cp = state.get("completed", {})
            if target_step in cp:
                del cp[target_step]
                # 同时清理 pending_routes 中的残留
                pr = state.get("pending_routes", {})
                pr.pop(target_step, None)
                actions.append(f"remove_illegal_completed: {target_step}")

        elif fix_type == "remove_illegal_pending_routes":
            target_step = fix_data.get("step", step)
            pr = state.get("pending_routes", {})
            if target_step in pr:
                del pr[target_step]
                actions.append(f"remove_illegal_pending_route: {target_step}")

        elif fix_type == "remove_illegal_dispatch":
            idx = fix_data.get("index", -1)
            disp_list = state.get("pending_dispatches") or []
            if 0 <= idx < len(disp_list):
                removed = disp_list.pop(idx)
                state["pending_dispatches"] = disp_list if disp_list else None
                actions.append(f"remove_illegal_dispatch[{idx}]: {removed.get('step', '?')}")

        # ── INV-3: 终态完整性修复 ──
        elif fix_type == "clear_step_status_on_terminal":
            steps = fix_data.get("steps", [])
            ss = state.get("step_status", {})
            for s in steps:
                ss.pop(s, None)
            actions.append(f"clear_step_status_on_terminal: {steps}")

        elif fix_type == "clear_dispatches_on_terminal":
            state["pending_dispatches"] = None
            actions.append("clear_dispatches_on_terminal")

        elif fix_type == "clear_pending_routes_on_terminal":
            steps = fix_data.get("steps", [])
            pr = state.get("pending_routes", {})
            for s in steps:
                pr.pop(s, None)
            actions.append(f"clear_pending_routes_on_terminal: {steps}")

        # ── INV-4: 删除 stale pending_route ──
        elif fix_type == "remove_stale_pending_route":
            target_step = fix_data.get("step", step)
            pr = state.get("pending_routes", {})
            if target_step in pr:
                del pr[target_step]
                actions.append(f"remove_stale_pending_route: {target_step}")

        # ── INV-8: 移除无效 dispatch ──
        elif fix_type == "remove_duplicate_dispatch":
            idx = fix_data.get("index", -1)
            disp_list = state.get("pending_dispatches") or []
            if 0 <= idx < len(disp_list):
                removed = disp_list.pop(idx)
                state["pending_dispatches"] = disp_list if disp_list else None
                actions.append(f"remove_duplicate_dispatch[{idx}]: {removed.get('step', '?')}")

        elif fix_type == "remove_unsatisfied_dispatch":
            idx = fix_data.get("index", -1)
            disp_list = state.get("pending_dispatches") or []
            if 0 <= idx < len(disp_list):
                removed = disp_list.pop(idx)
                state["pending_dispatches"] = disp_list if disp_list else None
                actions.append(f"remove_unsatisfied_dispatch[{idx}]: {removed.get('step', '?')}")

        # ── INV-9: 清空 stale cache ──
        elif fix_type == "clear_cached_branch_results":
            state["cached_branch_results"] = []
            actions.append("clear_cached_branch_results")

        # ── Z3: 重建断裂 JOIN 的 pending_routes ──
        elif fix_type == "regenerate_dispatch":
            tgt_step = fix_data.get("step", step)
            sources = fix_data.get("sources", [])
            completed = state.get("completed", {})
            pending_routes = state.get("pending_routes", {})
            restored = []
            for src in sources:
                if src in completed and src not in pending_routes:
                    pending_routes[src] = completed[src]
                    restored.append(src)
            if restored:
                state["pending_routes"] = pending_routes
                state["pending_dispatches"] = None
                state["cached_branch_results"] = []
                actions.append(f"rebuild_pending_routes: {tgt_step} <- {', '.join(restored)}")
            else:
                actions.append(f"skip_rebuild: {tgt_step} (sources not in completed)")

    return len(actions), actions


# ═══════════════════════════════════════════════════════════════
# CLI（与旧版完全兼容）
# ═══════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="全局 STATE 健康检测与修复 (v5.0)")
    parser.add_argument("--workspace-id", default=None, help="工作区 ID")
    parser.add_argument("--state-path", default=None, help="STATE.json 路径")
    parser.add_argument("--router-path", default=None, help="ROUTER.json 路径")
    parser.add_argument("--dry-run", action="store_true", help="仅检测不修复")
    parser.add_argument("--fix", action="store_true", help="自动修复检测到的问题")
    args = parser.parse_args()

    # 解析路径
    ws_id = args.workspace_id
    state_path = args.state_path
    if not state_path:
        state_path = resolve_ws_state(ws_id)
    if not state_path or not os.path.exists(state_path):
        print(json.dumps({"status": "error", "error": f"STATE.json 不存在: {state_path}"}))
        sys.exit(1)

    # 解析 app 路径
    if args.router_path:
        router_path = args.router_path
        registry_path = args.router_path.replace("ROUTER.json", "registry.json")
    else:
        if not ws_id:
            ws_id = load_json(state_path).get("workspace_id", "default") if load_json(state_path) else "default"
        app_path = resolve_app_path(ws_id)
        router_path = os.path.join(app_path, "ROUTER.json")
        registry_path = os.path.join(app_path, "registry.json")

    # 加载数据
    state = load_json(state_path)
    router_data = load_json(router_path)
    registry_data = load_json(registry_path)

    if not state or not router_data:
        print(json.dumps({"status": "error", "error": "无法加载 STATE.json 或 ROUTER.json"}))
        sys.exit(1)

    router_steps = router_data.get("steps", [])
    entry_step = router_data.get("entry", "")
    join_map = build_join_map(registry_data or [])

    # 执行检测
    findings = check_health(state, router_steps, join_map, entry_step)

    # 汇总
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
    }

    # 修复
    if args.fix and findings:
        try:
            state = load_json(state_path) or state
            fixed_count, actions = apply_fixes(state, findings)

            if fixed_count > 0:
                hist = state.setdefault("history", [])
                hist.append({
                    "timestamp": now_iso(),
                    "action": "health_check_fix",
                    "step": "global",
                    "actor": "state_health_check.py",
                    "result": f"fixed {fixed_count} issues: {'; '.join(actions)}",
                })
                if len(hist) > 500:
                    state["history"] = hist[-500:]

                save_state(state_path, state)
                result["fix_status"] = f"fixed {fixed_count} issues"
                result["fix_actions"] = actions
            else:
                result["fix_status"] = "no auto-fixable issues"
        except Exception as e:
            result["fix_status"] = f"error: {e}"

    if args.dry_run:
        result["mode"] = "dry-run"
    elif args.fix:
        result["mode"] = "fix"
    else:
        result["mode"] = "check"

    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
