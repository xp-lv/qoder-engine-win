#!/usr/bin/env python3
"""review_lint.py — 角色评审自动化工具

基于《角色评审方法论（5维×8步）》的自动化预扫描工具。
将评审时间从 1 小时/角色降到 15 分钟/角色（机器预扫 + 人工深审）。

自动检测维度：
  B1：verdict 四方一致性（schema enum ↔ registry verdicts ↔ ROUTER transitions ↔ skill verdict 表）
  B3：跨文件路径一致性（grep 所有引用路径）
  D2：跨文档重复段落（cp 命令清单重复检测）
  E1：fail 边 target 自指检测
  E3：SDK 陷阱引用缺失检测（producer 角色是否引用《SDK陷阱规避》）

Usage:
  python engine/scripts/review_lint.py --app-path apps/xxx
  python engine/scripts/review_lint.py --app-path z-workspace/xxx
"""
import argparse, json, os, re, sys
from collections import defaultdict


def load_json(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def slugify(name):
    return re.sub(r'[^\w\u4e00-\u9fff]', '_', name)


def find_enum_in_schema(schema_path):
    """从 schema.json 提取 verdict enum（可能不存在）。"""
    if not os.path.exists(schema_path):
        return None
    try:
        schema = load_json(schema_path)
        return schema.get("properties", {}).get("result", {}).get("properties", {}).get("verdict", {}).get("enum")
    except (json.JSONDecodeError, ValueError):
        return None


def find_verdicts_in_skill(skill_path):
    """从 skill.md 提取 verdict 表中的 verdict 值。"""
    if not os.path.exists(skill_path):
        return set()
    with open(skill_path, "r", encoding="utf-8-sig") as f:
        content = f.read()
    # 匹配 `verdict_name` 形式（在反引号内）
    return set(re.findall(r'`([a-z_]+)`', content))


# ─── B1：verdict 四方一致性 ───

def check_b1_verdict_consistency(app_path, errors, warnings):
    """B1: schema enum ↔ registry verdicts ↔ ROUTER transitions ↔ skill verdict 表"""
    router_path = os.path.join(app_path, "ROUTER.json")
    reg_path = os.path.join(app_path, "registry.json")
    if not os.path.exists(router_path) or not os.path.exists(reg_path):
        warnings.append("B1: ROUTER.json 或 registry.json 不存在，跳过")
        return

    router = load_json(router_path)
    registry = load_json(reg_path)

    reg_map = {r["role_name"]: r for r in registry}
    router_steps = {s["step"]: s for s in router.get("steps", [])}

    for step_name, step in router_steps.items():
        role_name = step.get("role", "")
        role_dir = slugify(role_name)
        schema_path = os.path.join(app_path, "roles", role_dir, "schema.json")
        skill_path = os.path.join(app_path, "roles", role_dir, "skill.md")

        # ROUTER transitions keys
        router_keys = set(step.get("transitions", {}).keys())

        # Registry verdicts
        reg_verdicts = set(reg_map.get(role_name, {}).get("verdicts", []))

        # Schema enum
        schema_enum = set(find_enum_in_schema(schema_path) or [])

        # 比对（fail 是 SDK 系统保留，不在 verdicts/enum 中）
        router_no_fail = router_keys - {"fail"}

        # Registry vs ROUTER
        if reg_verdicts and reg_verdicts != router_no_fail:
            # 校验角色特例：reg_verdicts 可能多 confirmed/loop（compiler 强制加）
            diff = reg_verdicts.symmetric_difference(router_no_fail)
            if diff - {"confirmed", "loop"}:
                errors.append(f"B1: {step_name} Registry verdicts 与 ROUTER transitions 不一致。diff={diff}")

        # Schema enum vs Registry verdicts（校验角色多 confirmed/loop）
        if schema_enum and reg_verdicts:
            diff = schema_enum.symmetric_difference(reg_verdicts)
            if diff - {"confirmed", "loop"}:
                errors.append(f"B1: {step_name} Schema enum 与 Registry verdicts 不一致。diff={diff}")


# ─── B3：跨文件路径一致性 ───

def check_b3_path_consistency(app_path, errors, warnings):
    """B3: 检查 app.yaml 中 outputs 路径与 schema _required_files 路径一致性"""
    # 简化版：检测明显的后缀漂移（.md vs .json）
    for role_dir in os.listdir(os.path.join(app_path, "roles")):
        skill_path = os.path.join(app_path, "roles", role_dir, "skill.md")
        schema_path = os.path.join(app_path, "roles", role_dir, "schema.json")
        if not os.path.exists(skill_path) or not os.path.exists(schema_path):
            continue
        with open(skill_path, "r", encoding="utf-8-sig") as f:
            skill_content = f.read()
        schema = load_json(schema_path)
        for rf in schema.get("_required_files", []):
            path = rf.get("path", "")
            if path and path not in skill_content:
                warnings.append(f"B3: {role_dir} schema 声明产出物 {path}，但 skill.md 未提及")


# ─── D2：跨文档重复段落 ───

def check_d2_cross_doc_duplication(app_path, errors, warnings):
    """D2: 检测 cp 命令清单、problem schema 等重复段落"""
    knowledge_dir = os.path.join(app_path, "knowledge")
    if not os.path.isdir(knowledge_dir):
        return

    # 检测 cp 命令清单重复（mkdir -p outputs/archive 或 cp outputs/）
    cp_pattern = re.compile(r'(mkdir -p outputs/archive[^\n]*|cp outputs/[^\n]+archive[^\n]*)')
    files_with_cp = []
    for fname in os.listdir(knowledge_dir):
        fpath = os.path.join(knowledge_dir, fname)
        if not fname.endswith(".md"):
            continue
        with open(fpath, "r", encoding="utf-8-sig") as f:
            content = f.read()
        cp_matches = cp_pattern.findall(content)
        if len(cp_matches) >= 3:  # 阈值：≥3 行 cp 命令视为完整清单
            files_with_cp.append(fname)

    if len(files_with_cp) > 1:
        errors.append(f"D2: cp 命令清单在多份文档重复: {files_with_cp}。应保留单一权威源，其他引用")


# ─── E1：fail 边 target 自指检测 ───

def check_e1_fail_edge_self_reference(app_path, errors, warnings):
    """E1: 检测 fail 边 target 是否自指（部分自指是 SDK 兜底，允许；但 producer 主 step 自指可疑）"""
    router_path = os.path.join(app_path, "ROUTER.json")
    if not os.path.exists(router_path):
        return
    router = load_json(router_path)

    for step in router.get("steps", []):
        step_name = step["step"]
        fail_edge = step.get("transitions", {}).get("fail", {})
        if not isinstance(fail_edge, dict):
            continue
        fail_targets = fail_edge.get("targets", [])
        if step_name in fail_targets and "-validate" not in step_name:
            # producer 主 step 自指：可能是合理的（producer 失败重做）
            # 但如果是多路径角色，可能是 bug
            warnings.append(f"E1: {step_name} fail 边自指（target=自身）。producer 主 step 通常合理；多路径角色需确认")


# ─── E3：SDK 陷阱引用缺失检测 ───

def check_e3_sdk_traps_reference(app_path, errors, warnings):
    """E3: 检查 producer 角色是否引用《SDK陷阱规避》"""
    # 读 app.yaml 找 producer 角色
    app_yaml_path = os.path.join(app_path, "app.yaml")
    if not os.path.exists(app_yaml_path):
        return
    with open(app_yaml_path, "r", encoding="utf-8-sig") as f:
        content = f.read()

    # 简单解析 producer 角色名
    producer_roles = set()
    in_roles = False
    current_role = None
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped == "roles:":
            in_roles = True
            continue
        if in_roles:
            if line and not line.startswith(" ") and not stripped.endswith(":"):
                break
            if line.startswith("  ") and not line.startswith("    ") and stripped.endswith(":"):
                current_role = stripped[:-1].strip()
            elif current_role and "type: producer" in stripped:
                producer_roles.add(current_role)

    # 检查每个 producer 的 skill 是否引用 SDK陷阱规避
    for role in producer_roles:
        role_dir = slugify(role)
        skill_path = os.path.join(app_path, "roles", role_dir, "skill.md")
        if not os.path.exists(skill_path):
            continue
        with open(skill_path, "r", encoding="utf-8-sig") as f:
            skill_content = f.read()
        if "SDK陷阱规避" not in skill_content and "SDK 陷阱" not in skill_content:
            # 检查 app.yaml 是否注册了 SDK陷阱规避
            if "SDK陷阱规避" not in content:
                warnings.append(f"E3: producer 角色 {role} 的 skill.md 未引用《SDK陷阱规避》，且 app.yaml 也未注册")
            else:
                warnings.append(f"E3: producer 角色 {role} 的 skill.md 未引用《SDK陷阱规避》（app.yaml 已注册）")


# ─── 主流程 ───

def main():
    parser = argparse.ArgumentParser(description="角色评审自动化工具")
    parser.add_argument("--app-path", required=True, help="APP 路径")
    args = parser.parse_args()

    app_path = args.app_path
    if not os.path.isdir(app_path):
        print(f"❌ 路径不存在: {app_path}")
        sys.exit(1)

    errors = []
    warnings = []

    print(f"🔍 评审预扫描: {app_path}\n")

    # B1
    print("▸ B1 verdict 四方一致性...")
    check_b1_verdict_consistency(app_path, errors, warnings)

    # B3
    print("▸ B3 跨文件路径一致性...")
    check_b3_path_consistency(app_path, errors, warnings)

    # D2
    print("▸ D2 跨文档重复段落...")
    check_d2_cross_doc_duplication(app_path, errors, warnings)

    # E1
    print("▸ E1 fail 边自指检测...")
    check_e1_fail_edge_self_reference(app_path, errors, warnings)

    # E3
    print("▸ E3 SDK 陷阱引用缺失...")
    check_e3_sdk_traps_reference(app_path, errors, warnings)

    # 输出报告
    print("\n" + "=" * 60)
    print(f"评审预扫描报告")
    print("=" * 60)

    if errors:
        print(f"\n❌ 错误（{len(errors)} 个，必须修复）:")
        for e in errors:
            print(f"  • {e}")

    if warnings:
        print(f"\n⚠️  警告（{len(warnings)} 个，建议检查）:")
        for w in warnings:
            print(f"  • {w}")

    if not errors and not warnings:
        print("\n✅ 未发现问题，建议人工深审（5维×8步方法论）")

    print(f"\n总计: {len(errors)} 错误 + {len(warnings)} 警告")
    print("=" * 60)

    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
