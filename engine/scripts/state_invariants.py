#!/usr/bin/env python3
"""state_invariants.py — STATE 合法性不变量规范（v7.0: 移除写入后自动修复）。

v7.0 变更：
  - 移除 Layer A (check_basic)：写入后即时校验引入不确定性，已全部删除。
  - save_state/state_txn 不再调用 check_basic。
  - 保留 Layer B/C/D：由 state_health_check.py 独立调用（仅检测报告，不自动修复）。

四层分组（v7.0 后）：
  Layer A:    已移除（原 check_basic 由 state_io 内部调用）
  Layer B (check_structural): 需 ROUTER steps
  Layer C (check_causal):     需 ROUTER + registry
  Layer D (check_parallel):   需 ROUTER + registry（并行专属检查）

CLI:
  python state_invariants.py --state-path <path> [--router-path <path>] [--registry-path <path>]
  python state_invariants.py --workspace-id <ws_id>
"""
import argparse, json, os, sys
from dataclasses import dataclass, field
from typing import List, Dict, Any, Optional, Set

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path


# ═══════════════════════════════════════════════════════════════
# Violation 数据结构
# ═══════════════════════════════════════════════════════════════

# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


@dataclass
class Violation:
    """单条不变量违反。"""
    inv_id: str
    severity: str          # "critical" | "major" | "minor"
    step: str
    message: str
    fix_type: str
    fix_data: dict = field(default_factory=dict)
    auto_fixable: bool = False

    def to_dict(self):
        return {
            "inv_id": self.inv_id,
            "severity": self.severity,
            "step": self.step,
            "message": self.message,
            "fix_type": self.fix_type,
            "fix_data": self.fix_data,
            "auto_fixable": self.auto_fixable,
        }


_VALID_STATUS = {"executing", "awaiting_confirmation"}


# ═══════════════════════════════════════════════════════════════
# Layer A: 基础结构不变量（零外部依赖）
# ═══════════════════════════════════════════════════════════════

# Layer A (check_basic / _a1 ~ _a4) 已在 v7.0 全部移除。
# 原因：写入后即时校验在合法瞬态窗口内引入不确定性自动修复。
# 不变量检测现由 state_health_check.py 独立执行（仅报告，不修复）。


# ═══════════════════════════════════════════════════════════════
# Layer B: 结构一致性（需 ROUTER steps）
# ═══════════════════════════════════════════════════════════════

def check_structural(state: dict, router_steps: list) -> List[Violation]:
    """结构检查，需 ROUTER.json 步骤定义。

    覆盖: B1 (步骤引用合法性), B2 (verdict 合法性)
    """
    violations = []
    all_steps = {s["step"] for s in router_steps if "step" in s}
    step_transitions = {}
    for s in router_steps:
        step_name = s.get("step", "")
        trans = s.get("transitions", {})
        step_transitions[step_name] = set(trans.keys()) if isinstance(trans, dict) else set()

    _b1_step_reference(state, all_steps, violations)
    _b2_verdict_consistency(state, step_transitions, violations)
    return violations


def _b1_step_reference(state, all_steps, violations):
    """B1: STATE 中所有 step 引用必须在 ROUTER.json 中定义。"""
    ss = state.get("step_status", {})
    cp = state.get("completed", {})
    pr = state.get("pending_routes", {})

    for source, data in [("step_status", ss), ("completed", cp), ("pending_routes", pr)]:
        for step in data:
            if step not in all_steps:
                violations.append(Violation(
                    inv_id="B1",
                    severity="critical",
                    step=step,
                    message=f"{source}['{step}'] 不在 ROUTER.json 的步骤定义中",
                    fix_type=f"remove_illegal_{source}",
                    fix_data={"step": step},
                    auto_fixable=True,
                ))

    pd = state.get("pending_dispatches")
    if pd:
        for i, disp in enumerate(pd):
            if isinstance(disp, dict):
                step = disp.get("step", "")
                if step and step not in all_steps:
                    violations.append(Violation(
                        inv_id="B1",
                        severity="critical",
                        step=step,
                        message=f"pending_dispatches[{i}].step='{step}' 不在 ROUTER.json 中",
                        fix_type="remove_illegal_dispatch",
                        fix_data={"index": i},
                        auto_fixable=True,
                    ))


def _b2_verdict_consistency(state, step_transitions, violations):
    """B2: completed 中不在 step_status 的 step，其 verdict 必须是 ROUTER transition key。

    排除 step ∈ step_status 的步骤（重执行场景，verdict 是上一轮旧值）。
    """
    cp = state.get("completed", {})
    ss = state.get("step_status", {})

    for step, ckpt in cp.items():
        if step in ss:
            continue

        if not isinstance(ckpt, dict):
            continue

        verdict = ckpt.get("verdict")
        if verdict is None:
            valid_keys = step_transitions.get(step, set())
            violations.append(Violation(
                inv_id="B2",
                severity="major",
                step=step,
                message=f"completed['{step}'] 无 verdict 字段，合法值: {sorted(valid_keys) if valid_keys else '（该步骤不在ROUTER中）'}",
                fix_type="missing_verdict",
                fix_data={"step": step, "valid_verdicts": sorted(valid_keys)},
                auto_fixable=False,
            ))
            continue

        valid_keys = step_transitions.get(step, set())
        if valid_keys and verdict not in valid_keys:
            violations.append(Violation(
                inv_id="B2",
                severity="major",
                step=step,
                message=f"completed['{step}'].verdict='{verdict}' 不在 transitions 中，合法值: {sorted(valid_keys)}",
                fix_type="invalid_verdict",
                fix_data={"step": step, "verdict": verdict, "valid_verdicts": sorted(valid_keys)},
                auto_fixable=False,
            ))


# ═══════════════════════════════════════════════════════════════
# Layer C: 因果一致性（需 ROUTER + registry）
# ═══════════════════════════════════════════════════════════════

def check_causal(state: dict, router_steps: list, join_map: dict, entry_step: str = "") -> List[Violation]:
    """因果检查，需 ROUTER + registry。

    覆盖: C1 (调度前置合法性), C2 (因果可达性), C3 (dispatch 有效性)
    """
    violations = []
    _c1_precondition(state, join_map, violations, entry_step)
    _c2_causal_reachability(state, router_steps, violations, entry_step)
    _c3_dispatch_validity(state, join_map, violations)
    return violations


def _c1_precondition(state, join_map, violations, entry_step=""):
    """C1: step_status 中的 step 满足调度前置条件之一。

    合法状态：
    - 是 entry step 且 completed 为空（首次执行）
    - 无 input_groups 声明
    - 至少有一个 input_group 全部在 completed 中
    - 同时也在 completed 中（重执行场景）
    """
    ss = state.get("step_status", {})
    cp = state.get("completed", {})
    cp_set = set(cp.keys())

    for step in ss:
        # 重执行场景：step 同时在 CP 和 SS 中
        if step in cp:
            continue
        # 入口步骤首次执行
        if step == entry_step and not cp:
            continue
        groups = join_map.get(step, [])
        if not groups:
            continue
        satisfied = False
        for group in groups:
            if isinstance(group, list) and set(group).issubset(cp_set):
                satisfied = True
                break
        if not satisfied:
            missing = []
            for group in groups:
                if isinstance(group, list):
                    missing.extend([s for s in group if s not in cp_set])
            violations.append(Violation(
                inv_id="C1",
                severity="major",
                step=step,
                message=f"step_status['{step}'] 正在执行但前置未满足，缺少: {sorted(set(missing))}",
                fix_type="precondition_unmet",
                fix_data={"step": step, "missing_sources": sorted(set(missing))},
                auto_fixable=False,
            ))


def _c2_causal_reachability(state, router_steps, violations, entry_step=""):
    """C2: completed 中每个非入口 step 必须存在至少一条正向边从 completed 中的来源指向它。

    排除 backward 边和自环。
    """
    cp = state.get("completed", {})

    reverse_adj = {}
    # 入口步骤通过 entry_step 参数识别（而非 "无 transitions" 判定）
    entry_candidates = {entry_step} if entry_step else set()
    # 补充：无 transitions 的步骤也是入口候选
    for s in router_steps:
        step_name = s.get("step", "")
        trans = s.get("transitions", {})
        if not trans:
            entry_candidates.add(step_name)
        for verdict, t_info in trans.items():
            targets = t_info.get("targets", []) if isinstance(t_info, dict) else []
            t_type = t_info.get("type", "normal") if isinstance(t_info, dict) else "normal"
            if t_type == "backward":
                continue
            for tgt in targets:
                reverse_adj.setdefault(tgt, []).append((step_name, verdict))

    for step in cp:
        if step in entry_candidates:
            continue
        sources = reverse_adj.get(step, [])
        found = False
        for src_step, src_verdict in sources:
            if src_step == step:
                continue
            if src_step in cp:
                src_ckpt = cp[src_step]
                if isinstance(src_ckpt, dict) and src_ckpt.get("verdict") == src_verdict:
                    found = True
                    break
        if not found:
            external_sources_in_cp = [
                s for s, v in sources if s != step and s in cp
            ]
            if not external_sources_in_cp:
                violations.append(Violation(
                    inv_id="C2",
                    severity="major",
                    step=step,
                    message=f"completed['{step}'] 因果不可达：无任何来源步骤（排除自环/backward）在 completed 中",
                    fix_type="orphan_completed",
                    fix_data={"step": step, "known_sources": [f"{s}--{v}" for s, v in sources if s != step]},
                    auto_fixable=False,
                ))


def _c3_dispatch_validity(state, join_map, violations):
    """C3: pending_dispatches 中的 dispatch 不指向正在执行的步骤，且 JOIN 前置已满足。"""
    pd = state.get("pending_dispatches")
    if not pd:
        return

    ss = state.get("step_status", {})
    cp = state.get("completed", {})
    cp_set = set(cp.keys())

    for i, disp in enumerate(pd):
        if not isinstance(disp, dict):
            continue
        step = disp.get("step", "")

        if step in ss:
            violations.append(Violation(
                inv_id="C3",
                severity="major",
                step=step,
                message=f"pending_dispatches[{i}] 指向 '{step}' 已在 step_status 中（重复执行）",
                fix_type="remove_duplicate_dispatch",
                fix_data={"index": i},
                auto_fixable=True,
            ))
            continue

        groups = join_map.get(step, [])
        if groups:
            satisfied = False
            for group in groups:
                if isinstance(group, list) and set(group).issubset(cp_set):
                    satisfied = True
                    break
            if not satisfied:
                missing = []
                for group in groups:
                    if isinstance(group, list):
                        missing.extend([s for s in group if s not in cp_set])
                violations.append(Violation(
                    inv_id="C3",
                    severity="major",
                    step=step,
                    message=f"pending_dispatches[{i}].step='{step}' JOIN 前置未满足，缺少: {sorted(set(missing))}",
                    fix_type="remove_unsatisfied_dispatch",
                    fix_data={"index": i, "missing_sources": sorted(set(missing))},
                    auto_fixable=True,
                ))


# ═══════════════════════════════════════════════════════════════
# Layer D: 并行一致性（需 ROUTER + registry）
# ═══════════════════════════════════════════════════════════════

def check_parallel(state: dict, router_steps: list, join_map: dict, entry_step: str = "") -> List[Violation]:
    """并行专属检查。

    覆盖: D1 (并行集一致性), D2 (并行分支可恢复性), D3 (JOIN 活跃性检测)
    """
    violations = []
    _d1_parallel_set_consistency(state, router_steps, violations)
    _d2_branch_recoverability(state, router_steps, violations)
    _d3_join_liveness(state, router_steps, join_map, violations)
    return violations


def _d1_parallel_set_consistency(state, router_steps, violations):
    """D1: 缓存中的 step 应与 step_status 中的 step 属于同一 FORK 批次。

    判定：缓存中的 step 和 step_status 中的 step 应有共同的直接前驱。
    如果没有共同前驱，说明可能存在跨轮次缓存污染。
    """
    ss = state.get("step_status", {})
    cbr = state.get("cached_branch_results", [])
    if not cbr or not ss:
        return

    # 构建反向邻接表（normal 边）
    reverse_adj = {}
    for s in router_steps:
        step_name = s.get("step", "")
        trans = s.get("transitions", {})
        for verdict, t_info in trans.items():
            targets = t_info.get("targets", []) if isinstance(t_info, dict) else []
            t_type = t_info.get("type", "normal") if isinstance(t_info, dict) else "normal"
            if t_type == "backward":
                continue
            for tgt in targets:
                reverse_adj.setdefault(tgt, set()).add(step_name)

    # 获取 step_status 中 step 的前驱集
    ss_preds = set()
    for step in ss:
        ss_preds.update(reverse_adj.get(step, set()))

    # 检查缓存中每个 step 的前驱是否与 ss 的前驱有交集
    for entry in cbr:
        cached_step = entry.get("step", "") if isinstance(entry, dict) else ""
        if not cached_step:
            continue
        cached_preds = reverse_adj.get(cached_step, set())
        if ss_preds and cached_preds and not (ss_preds & cached_preds):
            violations.append(Violation(
                inv_id="D1",
                severity="major",
                step=cached_step,
                message=f"cached_branch_results 中的 '{cached_step}' 与 step_status 中的步骤无共同前驱（可能跨轮次缓存污染）",
                fix_type="stale_cache",
                fix_data={"step": cached_step},
                auto_fixable=False,
            ))


def _d2_branch_recoverability(state, router_steps, violations):
    """D2: 并行分支可恢复性检测（替代旧 Z1 僵尸检测）。

    核心区别 vs Z1：
    - Z1 说 "executing = 僵尸" → 错误（并行场景下 executing 是合法常态）
    - D2 说 "step 在 SS 但不在 CP 且无缓存 = 可能是孤儿" → 更精确

    auto_fixable=False：自动清除可能破坏 JOIN 收敛，需人工确认。
    """
    ss = state.get("step_status", {})
    cp = state.get("completed", {})
    cbr = state.get("cached_branch_results", [])

    # 收集缓存中已记录的 step
    cached_steps = set()
    for entry in cbr:
        if isinstance(entry, dict):
            cached_steps.add(entry.get("step", ""))

    for step, info in ss.items():
        if not isinstance(info, dict):
            continue
        if info.get("status") != "executing":
            continue
        # step 在 SS 但不在 CP → 正常的活跃执行，不是违规
        # D2 不产生 violation，只做信息记录
        # 僵尸 executing 的清理由用户通过 jump 显式触发（Hook② 不再自动清理）


def _d3_join_liveness(state, router_steps, join_map, violations):
    """D3: JOIN 活跃性检测 — 检测不可达的 JOIN 成员导致的永久死锁。

    对于每个 JOIN 目标（input_groups 含 ≥2 元素组）：
    1. 取其多元素组
    2. 检查该组每个成员的可达性
    3. 成员不可达 = 该 JOIN 永远无法收敛 = 死锁
    """
    cp = state.get("completed", {})
    ss = state.get("step_status", {})
    pd = state.get("pending_dispatches")

    # 收集所有可达的 step 集合
    reachable = set(cp.keys()) | set(ss.keys())
    if pd:
        for disp in pd:
            if isinstance(disp, dict):
                reachable.add(disp.get("step", ""))

    # 所有 ROUTER 中定义的 step
    all_steps = {s.get("step", "") for s in router_steps}

    for step, groups in join_map.items():
        # 只检查含多元素组的 step（JOIN 目标）
        multi_groups = [g for g in groups if isinstance(g, list) and len(g) >= 2]
        if not multi_groups:
            continue

        # 如果 JOIN 目标已经在 completed 中，不需要检查
        if step in cp:
            continue

        for group in multi_groups:
            unreachable_members = []
            for member in group:
                if member not in reachable and member not in all_steps:
                    # 成员不在 STATE 的任何活跃字段中，也不是 ROUTER 定义的步骤
                    unreachable_members.append(member)
                elif member not in reachable and member in all_steps:
                    # 成员是合法步骤但不在任何活跃字段中 → 可能崩溃后被清除
                    unreachable_members.append(member)

            if unreachable_members:
                violations.append(Violation(
                    inv_id="D3",
                    severity="critical",
                    step=step,
                    message=(
                        f"JOIN 目标 '{step}' 的成员 {unreachable_members} 不可达"
                        f"（不在 completed/step_status/pending_dispatches 中），"
                        f"该 JOIN 永远无法收敛"
                    ),
                    fix_type="join_deadlock",
                    fix_data={
                        "step": step,
                        "unreachable_members": unreachable_members,
                        "group": group,
                    },
                    auto_fixable=False,
                ))
                break  # 每个 JOIN 目标只报一次


# ═══════════════════════════════════════════════════════════════
# 汇总入口
# ═══════════════════════════════════════════════════════════════

def validate_all(state: dict, router_steps: list = None, join_map: dict = None,
                 entry_step: str = "") -> List[Violation]:
    """全量不变量检查（v7.0: Layer A 已移除，仅 B/C/D）。"""
    violations = []
    # Layer A (check_basic) 已在 v7.0 移除
    if router_steps is not None:
        violations.extend(check_structural(state, router_steps))
    if router_steps is not None and join_map is not None:
        violations.extend(check_causal(state, router_steps, join_map, entry_step))
        violations.extend(check_parallel(state, router_steps, join_map, entry_step))
    return violations


def build_join_map(registry: list) -> dict:
    """从 registry.json 构建 JOIN 映射。

    返回: {step_name: [[src1, src2,...], ...]}
    """
    join_map = {}
    if not isinstance(registry, list):
        return join_map
    for entry in registry:
        step = entry.get("role_name", "")
        groups = entry.get("input_groups", [])
        if groups:
            join_map[step] = groups
    return join_map


def summarize(violations: List[Violation]) -> dict:
    """汇总 violations 为统计摘要。"""
    by_severity = {"critical": 0, "major": 0, "minor": 0}
    by_inv = {}
    auto_fixable = []
    for v in violations:
        by_severity[v.severity] = by_severity.get(v.severity, 0) + 1
        by_inv[v.inv_id] = by_inv.get(v.inv_id, 0) + 1
        if v.auto_fixable:
            auto_fixable.append(v.to_dict())
    return {
        "total": len(violations),
        "by_severity": by_severity,
        "by_invariant": by_inv,
        "auto_fixable_count": len(auto_fixable),
        "auto_fixable": auto_fixable,
    }


# ═══════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════

def _load_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(description="STATE 不变量校验（v6.0 并行原生设计）")
    parser.add_argument("--workspace-id", default=None, help="工作区 ID")
    parser.add_argument("--state-path", default=None, help="STATE.json 路径")
    parser.add_argument("--router-path", default=None, help="ROUTER.json 路径")
    parser.add_argument("--registry-path", default=None, help="registry.json 路径")
    parser.add_argument("--group", choices=["basic", "structural", "causal", "parallel", "all"], default="all",
                        help="只运行指定层级的检查")
    parser.add_argument("--format", choices=["json", "summary"], default="json",
                        help="输出格式：完整 JSON 或仅摘要")
    args = parser.parse_args()

    ws_id = args.workspace_id
    state_path = args.state_path
    if not state_path:
        state_path = resolve_ws_state(ws_id)
    if not state_path or not os.path.exists(state_path):
        print(json.dumps({"status": "error", "error": f"STATE.json 不存在: {state_path}"}))
        sys.exit(1)

    state = _load_json(state_path)
    if not state:
        print(json.dumps({"status": "error", "error": f"无法解析 STATE.json: {state_path}"}))
        sys.exit(1)

    router_steps = None
    join_map = None
    entry_step = ""

    app_path = None
    if args.router_path:
        router_path = args.router_path
    else:
        if not ws_id:
            ws_id = state.get("workspace_id", "default")
        app_path = resolve_app_path(ws_id)
        router_path = os.path.join(app_path, "ROUTER.json")

    if args.registry_path:
        registry_path = args.registry_path
    elif app_path:
        registry_path = os.path.join(app_path, "registry.json")
    else:
        registry_path = router_path.replace("ROUTER.json", "registry.json")

    if args.group in ("structural", "causal", "parallel", "all"):
        router_data = _load_json(router_path)
        if router_data:
            router_steps = router_data.get("steps", [])
            entry_step = router_data.get("entry", "")
        else:
            print(json.dumps({"status": "warning", "message": f"无法加载 ROUTER.json: {router_path}，跳过结构/因果/并行检查"}))

    if args.group in ("causal", "parallel", "all"):
        registry_data = _load_json(registry_path)
        if registry_data:
            join_map = build_join_map(registry_data)
        else:
            print(json.dumps({"status": "warning", "message": f"无法加载 registry.json: {registry_path}，跳过因果/并行检查"}))

    violations = []
    # Layer A (check_basic) 已在 v7.0 移除
    if args.group == "basic":
        violations = []  # v7.0: basic 已移除
    elif args.group == "structural" and router_steps:
        violations = check_structural(state, router_steps)
    elif args.group == "causal" and router_steps and join_map is not None:
        violations = check_causal(state, router_steps, join_map, entry_step)
    elif args.group == "parallel" and router_steps and join_map is not None:
        violations = check_parallel(state, router_steps, join_map, entry_step)
    elif args.group == "all":
        violations = validate_all(state, router_steps, join_map, entry_step)

    summary = summarize(violations)
    result = {
        "status": "healthy" if summary["by_severity"]["critical"] == 0 and summary["by_severity"]["major"] == 0 else "unhealthy",
        "workspace_id": ws_id or state.get("workspace_id", "?"),
        "state_path": state_path,
        "checked_groups": args.group,
        "summary": summary,
        "violations": [v.to_dict() for v in violations],
    }

    if args.format == "summary":
        print(json.dumps({
            "status": result["status"],
            "summary": summary["by_severity"],
            "by_invariant": summary["by_invariant"],
        }, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
