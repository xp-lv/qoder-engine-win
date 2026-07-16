#!/usr/bin/env python3
"""state_invariants.py — STATE 合法性不变量规范（三层防御 Phase 1）。

纯函数模块，不修改任何 STATE，不依赖网络或文件锁。
所有函数接收 state dict（+ 可选 ROUTER/registry 上下文），返回 Violation 列表。

三层分组：
  Group A (check_basic):      不需要外部上下文，Layer 2 (state_io) 使用
  Group B (check_structural): 需要 ROUTER steps，Layer 1 (set_state) 使用
  Group C (check_causal):     需要 ROUTER + registry，Layer 3 (health_check) 使用

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
    inv_id: str            # "INV-1" ~ "INV-9"
    severity: str          # "critical" | "major" | "minor"
    step: str              # 涉及的步骤名（可为空）
    message: str           # 人可读的描述
    fix_type: str          # 修复策略标识
    fix_data: dict = field(default_factory=dict)   # 修复所需数据
    auto_fixable: bool = False                      # 是否可安全自动修复

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


# 合法 status 枚举值
_VALID_STATUS = {"executing", "awaiting_confirmation"}


# ═══════════════════════════════════════════════════════════════
# Group A: 基础检查（无外部上下文）
# Layer 2 (state_io.save_state) 使用
# ═══════════════════════════════════════════════════════════════

def check_basic(state: dict) -> List[Violation]:
    """检查仅依赖 STATE 自身的不变量。

    在 state_io.save_state() 内部调用，零外部依赖。
    覆盖: INV-2, INV-3, INV-4, INV-9
    """
    violations = []
    _inv_2_status_enum(state, violations)
    _inv_3_terminal_completeness(state, violations)
    _inv_4_pending_routes_subset(state, violations)
    _inv_9_cache_consistency(state, violations)
    return violations


def _inv_2_status_enum(state, violations):
    """INV-2: step_status 中的 status 只能是 executing / awaiting_confirmation。"""
    ss = state.get("step_status", {})
    for step, info in ss.items():
        if isinstance(info, dict):
            status = info.get("status", "")
            if status not in _VALID_STATUS:
                violations.append(Violation(
                    inv_id="INV-2",
                    severity="critical",
                    step=step,
                    message=f"step_status['{step}'].status='{status}' 不在合法枚举中 {_VALID_STATUS}",
                    fix_type="invalid_status",
                    fix_data={"step": step, "status": status},
                    auto_fixable=False,
                ))


def _inv_3_terminal_completeness(state, violations):
    """INV-3: terminal_state 非空时，step_status/pending_dispatches/pending_routes 应为空。"""
    ts = state.get("terminal_state")
    if ts is None:
        return

    ss = state.get("step_status", {})
    pd = state.get("pending_dispatches")
    pr = state.get("pending_routes", {})

    if ss:
        steps = list(ss.keys())
        violations.append(Violation(
            inv_id="INV-3",
            severity="critical",
            step=steps[0] if steps else "",
            message=f"terminal_state='{ts}' 但 step_status 非空: {steps}",
            fix_type="clear_step_status_on_terminal",
            fix_data={"steps": steps},
            auto_fixable=True,
        ))

    if pd:
        violations.append(Violation(
            inv_id="INV-3",
            severity="critical",
            step="",
            message=f"terminal_state='{ts}' 但 pending_dispatches 非空 ({len(pd)} 条)",
            fix_type="clear_dispatches_on_terminal",
            fix_data={},
            auto_fixable=True,
        ))

    if pr:
        steps = list(pr.keys())
        violations.append(Violation(
            inv_id="INV-3",
            severity="major",
            step=steps[0] if steps else "",
            message=f"terminal_state='{ts}' 但 pending_routes 非空: {steps}",
            fix_type="clear_pending_routes_on_terminal",
            fix_data={"steps": steps},
            auto_fixable=True,
        ))


def _inv_4_pending_routes_subset(state, violations):
    """INV-4: pending_routes 中的 step 必须也在 completed 中。"""
    pr = state.get("pending_routes", {})
    cp = state.get("completed", {})
    for step in pr:
        if step not in cp:
            violations.append(Violation(
                inv_id="INV-4",
                severity="minor",
                step=step,
                message=f"pending_routes['{step}'] 不在 completed 中",
                fix_type="remove_stale_pending_route",
                fix_data={"step": step},
                auto_fixable=True,
            ))


def _inv_9_cache_consistency(state, violations):
    """INV-9: step_status 为空时 cached_branch_results 也应为空。"""
    ss = state.get("step_status", {})
    cbr = state.get("cached_branch_results", [])
    if not ss and cbr:
        violations.append(Violation(
            inv_id="INV-9",
            severity="minor",
            step="",
            message=f"step_status 为空但 cached_branch_results 有 {len(cbr)} 条残留",
            fix_type="clear_cached_branch_results",
            fix_data={},
            auto_fixable=True,
        ))


# ═══════════════════════════════════════════════════════════════
# Group B: 结构检查（需 ROUTER steps）
# Layer 1 (set_state) 使用
# ═══════════════════════════════════════════════════════════════

def check_structural(state: dict, router_steps: list) -> List[Violation]:
    """检查需要 ROUTER.json 步骤定义的不变量。

    在 set_state.py 操作前校验中调用。
    覆盖: INV-1, INV-5
    """
    violations = []
    all_steps = {s["step"] for s in router_steps if "step" in s}
    # 构建 step → transitions keys 映射
    step_transitions = {}
    for s in router_steps:
        step_name = s.get("step", "")
        trans = s.get("transitions", {})
        step_transitions[step_name] = set(trans.keys()) if isinstance(trans, dict) else set()

    _inv_1_step_reference(state, all_steps, violations)
    _inv_5_verdict_consistency(state, step_transitions, violations)
    return violations


def _inv_1_step_reference(state, all_steps, violations):
    """INV-1: STATE 中所有 step 引用必须在 ROUTER.json 中定义。"""
    ss = state.get("step_status", {})
    cp = state.get("completed", {})
    pr = state.get("pending_routes", {})

    for source, data in [("step_status", ss), ("completed", cp), ("pending_routes", pr)]:
        for step in data:
            if step not in all_steps:
                violations.append(Violation(
                    inv_id="INV-1",
                    severity="critical",
                    step=step,
                    message=f"{source}['{step}'] 不在 ROUTER.json 的步骤定义中",
                    fix_type=f"remove_illegal_{source}",
                    fix_data={"step": step},
                    auto_fixable=True,
                ))

    # 检查 pending_dispatches
    pd = state.get("pending_dispatches")
    if pd:
        for i, disp in enumerate(pd):
            if isinstance(disp, dict):
                step = disp.get("step", "")
                if step and step not in all_steps:
                    violations.append(Violation(
                        inv_id="INV-1",
                        severity="critical",
                        step=step,
                        message=f"pending_dispatches[{i}].step='{step}' 不在 ROUTER.json 中",
                        fix_type="remove_illegal_dispatch",
                        fix_data={"index": i},
                        auto_fixable=True,
                    ))


def _inv_5_verdict_consistency(state, step_transitions, violations):
    """INV-5: completed 中不在 step_status 的 step，其 verdict 必须是 ROUTER 中的 transition key。

    关键限定：排除 step ∈ step_status 的步骤。
    重执行场景下 CP 中的 verdict 是上一轮旧值，当前轮次尚未产生新 verdict。
    """
    cp = state.get("completed", {})
    ss = state.get("step_status", {})

    for step, ckpt in cp.items():
        # 重执行场景：step 同时在 CP 和 SS 中时跳过
        if step in ss:
            continue

        if not isinstance(ckpt, dict):
            continue

        verdict = ckpt.get("verdict")
        if verdict is None:
            # verdict 缺失（如 fix.py jump 的 jumped_over 条目）
            valid_keys = step_transitions.get(step, set())
            violations.append(Violation(
                inv_id="INV-5",
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
                inv_id="INV-5",
                severity="major",
                step=step,
                message=f"completed['{step}'].verdict='{verdict}' 不在 transitions 中，合法值: {sorted(valid_keys)}",
                fix_type="invalid_verdict",
                fix_data={"step": step, "verdict": verdict, "valid_verdicts": sorted(valid_keys)},
                auto_fixable=False,
            ))


# ═══════════════════════════════════════════════════════════════
# Group C: 因果检查（需 ROUTER + registry）
# Layer 3 (state_health_check) 使用
# ═══════════════════════════════════════════════════════════════

def check_causal(state: dict, router_steps: list, join_map: dict, entry_step: str = "") -> List[Violation]:
    """检查需要 DAG 图遍历的不变量。

    在 state_health_check.py 中调用。
    覆盖: INV-6, INV-7, INV-8
    entry_step: ROUTER.json 的 entry 字段，入口步骤不受 INV-6 约束。
    """
    violations = []
    _inv_6_precondition(state, join_map, violations, entry_step)
    _inv_7_causal_reachability(state, router_steps, violations)
    _inv_8_dispatch_validity(state, join_map, violations)
    return violations


def _inv_6_precondition(state, join_map, violations, entry_step=""):
    """INV-6: step_status 中的 step 要么是 entry，要么至少有一个 input_group 全部满足。

    注意：
    - 入口步骤（entry_step）不受此约束，因为它是首次执行的起点。
    - 入口步骤可能为 backward 重执行定义了包含自身的 input_groups，
      但首次执行时 completed 中还没有任何步骤，此时应跳过。
    - 重执行场景下 input_groups 的来源步骤通常已在 CP 中，此不变量自然满足。
    """
    ss = state.get("step_status", {})
    cp = state.get("completed", {})
    cp_set = set(cp.keys())

    for step in ss:
        # 入口步骤首次执行（completed 为空时）跳过
        if step == entry_step and not cp:
            continue
        groups = join_map.get(step, [])
        if not groups:
            # 无 input_groups 声明 = 入口或无前置依赖
            continue
        # 检查至少一个 group 全部在 completed 中
        satisfied = False
        for group in groups:
            if isinstance(group, list) and set(group).issubset(cp_set):
                satisfied = True
                break
        if not satisfied:
            # 列出缺少的来源
            missing = []
            for group in groups:
                if isinstance(group, list):
                    missing.extend([s for s in group if s not in cp_set])
            violations.append(Violation(
                inv_id="INV-6",
                severity="major",
                step=step,
                message=f"step_status['{step}'] 正在执行但 JOIN 前置未满足，缺少: {sorted(set(missing))}",
                fix_type="precondition_unmet",
                fix_data={"step": step, "missing_sources": sorted(set(missing))},
                auto_fixable=False,
            ))


def _inv_7_causal_reachability(state, router_steps, violations):
    """INV-7: completed 中每个非入口 step 必须存在至少一个 completed 中的来源步骤，
    且该来源的 verdict 边指向它。

    构建: {target_step: [(source_step, verdict), ...]}
    """
    cp = state.get("completed", {})

    # 构建反向邻接表：谁可以通过什么 verdict 到达我
    reverse_adj = {}  # {target: [(source, verdict), ...]}
    entry_candidates = set()
    for s in router_steps:
        step_name = s.get("step", "")
        trans = s.get("transitions", {})
        if not trans:
            entry_candidates.add(step_name)
        for verdict, t_info in trans.items():
            targets = t_info.get("targets", []) if isinstance(t_info, dict) else []
            for tgt in targets:
                reverse_adj.setdefault(tgt, []).append((step_name, verdict))

    for step in cp:
        if step in entry_candidates:
            continue
        # 检查是否有至少一个来源（排除自身）在 CP 中且 verdict 匹配
        # 自环（backward 边回到自身）不能证明因果可达性
        sources = reverse_adj.get(step, [])
        found = False
        for src_step, src_verdict in sources:
            if src_step == step:
                continue  # 排除自环
            if src_step in cp:
                src_ckpt = cp[src_step]
                if isinstance(src_ckpt, dict) and src_ckpt.get("verdict") == src_verdict:
                    found = True
                    break
        if not found:
            # 排除自环后，检查是否有任何来源在 CP 中
            external_sources_in_cp = [
                s for s, v in sources if s != step and s in cp
            ]
            if not external_sources_in_cp:
                violations.append(Violation(
                    inv_id="INV-7",
                    severity="major",
                    step=step,
                    message=f"completed['{step}'] 因果不可达：无任何来源步骤（排除自环）在 completed 中",
                    fix_type="orphan_completed",
                    fix_data={"step": step, "known_sources": [f"{s}--{v}" for s, v in sources if s != step]},
                    auto_fixable=False,
                ))


def _inv_8_dispatch_validity(state, join_map, violations):
    """INV-8: pending_dispatches 中的 dispatch 不指向正在执行的步骤，且 JOIN 前置已满足。"""
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

        # 检查 1: 不指向正在执行的步骤
        if step in ss:
            violations.append(Violation(
                inv_id="INV-8",
                severity="major",
                step=step,
                message=f"pending_dispatches[{i}] 指向 '{step}' 已在 step_status 中（重复执行）",
                fix_type="remove_duplicate_dispatch",
                fix_data={"index": i},
                auto_fixable=True,
            ))
            continue

        # 检查 2: JOIN 前置满足
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
                    inv_id="INV-8",
                    severity="major",
                    step=step,
                    message=f"pending_dispatches[{i}].step='{step}' JOIN 前置未满足，缺少: {sorted(set(missing))}",
                    fix_type="remove_unsatisfied_dispatch",
                    fix_data={"index": i, "missing_sources": sorted(set(missing))},
                    auto_fixable=True,
                ))


# ═══════════════════════════════════════════════════════════════
# 汇总入口
# ═══════════════════════════════════════════════════════════════

def validate_all(state: dict, router_steps: list = None, join_map: dict = None,
                 entry_step: str = "") -> List[Violation]:
    """全量不变量检查（三层叠加）。

    router_steps/join_map 为 None 时跳过对应层级的检查。
    entry_step 用于 INV-6 的入口步骤豁免。
    """
    violations = []
    violations.extend(check_basic(state))
    if router_steps is not None:
        violations.extend(check_structural(state, router_steps))
    if router_steps is not None and join_map is not None:
        violations.extend(check_causal(state, router_steps, join_map, entry_step))
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
    parser = argparse.ArgumentParser(description="STATE 不变量校验（三层防御 Phase 1）")
    parser.add_argument("--workspace-id", default=None, help="工作区 ID")
    parser.add_argument("--state-path", default=None, help="STATE.json 路径")
    parser.add_argument("--router-path", default=None, help="ROUTER.json 路径")
    parser.add_argument("--registry-path", default=None, help="registry.json 路径")
    parser.add_argument("--group", choices=["basic", "structural", "causal", "all"], default="all",
                        help="只运行指定层级的检查")
    parser.add_argument("--format", choices=["json", "summary"], default="json",
                        help="输出格式：完整 JSON 或仅摘要")
    args = parser.parse_args()

    # 解析路径
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

    # 解析 ROUTER 和 registry
    router_steps = None
    join_map = None

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

    entry_step = ""
    if args.group in ("structural", "causal", "all"):
        router_data = _load_json(router_path)
        if router_data:
            router_steps = router_data.get("steps", [])
            entry_step = router_data.get("entry", "")
        else:
            print(json.dumps({"status": "warning", "message": f"无法加载 ROUTER.json: {router_path}，跳过结构/因果检查"}))

    if args.group in ("causal", "all"):
        registry_data = _load_json(registry_path)
        if registry_data:
            join_map = build_join_map(registry_data)
        else:
            print(json.dumps({"status": "warning", "message": f"无法加载 registry.json: {registry_path}，跳过因果检查"}))

    # 执行检查
    violations = []
    if args.group == "basic":
        violations = check_basic(state)
    elif args.group == "structural" and router_steps:
        violations = check_structural(state, router_steps)
    elif args.group == "causal" and router_steps and join_map is not None:
        violations = check_causal(state, router_steps, join_map, entry_step)
    elif args.group == "all":
        violations = validate_all(state, router_steps, join_map, entry_step)

    # 输出
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
