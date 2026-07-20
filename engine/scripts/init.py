#!/usr/bin/env python3
"""初始化器。校验功能层配置 → 创建工作目录 → 初始化 STATE.json。
Usage: python engine/scripts/init.py --workspace-path <path> --app-path <path> [--workspace-id <id>] [--force]
"""
import argparse, json, os, sys, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import (
    resolve_ws_base, resolve_ws_state,
    derive_ws_id, get_app_name, get_edge_targets, resolve_workspace_output,
)
from state_io import save_state
from datetime import datetime, timezone

# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def output_success(message, state=None, registry=None, router=None):
    result = {"status": "success", "error_code": None, "message": message}
    if state:
        result["state_snapshot"] = {
            "executing_steps": list(state.get("step_status", {}).keys()),
            "total_steps": len(router.get("steps", [])) if router else 0,
            "roles_registered": [r["role_name"] for r in registry] if registry else []
        }
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)

def output_failure(error_code, message):
    print(json.dumps({"status": "failure", "error_code": error_code, "message": message, "state_snapshot": None}, ensure_ascii=False))
    sys.exit(1)

def check_dependencies():
    try:
        import jsonschema  # noqa: F401
    except ImportError:
        output_failure("OIC-E506",
            "缺少依赖 jsonschema。请安装: pip install jsonschema")

def load_json(path, error_code, missing_msg):
    if not os.path.exists(path):
        output_failure(error_code, f"{missing_msg}: {path}")
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (json.JSONDecodeError, ValueError) as e:
        output_failure(error_code, f"JSON 解析失败: {e}")

def validate_registry(registry):
    if not isinstance(registry, list):
        output_failure("OIC-E502", "注册表必须是角色记录数组")
    required_fields = {"role_name", "skill_path", "outputs"}
    seen = set()
    for i, role in enumerate(registry):
        missing = required_fields - set(role.keys())
        if missing:
            output_failure("OIC-E503", f"角色 {i} 缺少必填字段: {', '.join(missing)}")
        name = role["role_name"]
        if name in seen:
            output_failure("OIC-E504", f"角色名 {name} 重复注册")
        seen.add(name)
        if not role.get("outputs") and not role.get("allow_empty_output"):
            output_failure("OIC-E505", f"角色 {name} 没有注册产出物（如为终态步骤，请加 \"allow_empty_output\": true）")

def validate_router(router):
    if not isinstance(router, dict):
        output_failure("OIC-E512", "路由表必须是对象")
    if "entry" not in router:
        output_failure("OIC-E515", "路由表缺少 entry 字段")
    steps = router.get("steps", [])
    if not isinstance(steps, list):
        output_failure("OIC-E512", "路由表 steps 必须是数组")
    required_fields = {"step", "role", "transitions"}
    seen = set()
    for entry in steps:
        missing = required_fields - set(entry.keys())
        if missing:
            output_failure("OIC-E513", f"路由记录缺少必填字段: {', '.join(missing)}")
        step = entry["step"]
        if step in seen:
            output_failure("OIC-E514", f"STEP {step} 重复定义")
        seen.add(step)
        transitions = entry.get("transitions", {})
        standard_keys = {"confirmed", "fail"}
        conditional_keys = set(transitions.keys()) - standard_keys
        if not transitions:
            output_failure("OIC-E516", f"STEP {step} transitions 不能为空")
    for entry in steps:
        for result in entry.get("transitions", {}):
            targets = get_edge_targets(entry.get("transitions", {}), result)
            for t in targets:
                if t not in seen:
                    output_failure("OIC-E517", f"STEP {entry['step']} transitions.{result} 引用了未定义的 STEP: {t}")
    if router["entry"] not in seen:
        output_failure("OIC-E515", f"entry STEP {router['entry']} 不在 steps 中")

def cross_validate(router, registry):
    reg_names = {r["role_name"] for r in registry}
    for entry in router.get("steps", []):
        if entry["role"] not in reg_names:
            output_failure("OIC-E521", f"路由表中的角色 {entry['role']} 未在注册表中注册")

def main():
    parser = argparse.ArgumentParser(description="初始化器")
    parser.add_argument("--app-path", required=True, help="应用包路径")
    parser.add_argument("--workspace-path", required=True, help="实际项目目录（workspace）")
    parser.add_argument("--workspace-id", default=None, help="workspace 编号（不传则从 workspace-path 推导）")
    parser.add_argument("--force", action="store_true", help="强制重新初始化")
    parser.add_argument("--skip-compile", action="store_true", help="跳过编译器校验")
    parser.add_argument("--skip-dep-check", action="store_true", help="跳过依赖检查")
    args = parser.parse_args()

    # 推导 ws_id
    ws_id = args.workspace_id or derive_ws_id(args.workspace_path)
    ws_base = resolve_ws_base(ws_id)
    state_path = resolve_ws_state(ws_id)
    app_path = args.app_path

    if not args.skip_dep_check:
        check_dependencies()

    # Step 1-2: 校验 registry.json
    registry = load_json(f"{app_path}/registry.json", "OIC-E501", "注册表不存在")
    validate_registry(registry)

    # Step 3: 校验 ROUTER.json
    router = load_json(f"{app_path}/ROUTER.json", "OIC-E511", "路由表不存在")

    # SDK 兼容性检查
    _sdk_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sdk")
    sys.path.insert(0, _sdk_dir)
    try:
        from sdk import check_app_compatibility, CompatibilityError
        try:
            check_app_compatibility(f"{app_path}/ROUTER.json")
        except CompatibilityError as e:
            output_failure("OIC-E518", str(e))
    except ImportError:
        pass  # SDK 模块不存在时跳过检查

    validate_router(router)

    # Step 4: 交叉校验
    cross_validate(router, registry)

    # Step 5: 验证物理文件
    for role in registry:
        rel_skill = os.path.join(app_path, role["skill_path"])
        if not os.path.exists(rel_skill) and not os.path.exists(role["skill_path"]):
            output_failure("OIC-E531", f"角色 {role['role_name']} 的 SKILL 不存在: {role['skill_path']}")
        schema_path = role.get("schema_path", "")
        if schema_path:
            rel_schema = os.path.join(app_path, schema_path)
            if not os.path.exists(rel_schema) and not os.path.exists(schema_path):
                output_failure("OIC-E532", f"角色 {role['role_name']} 的 schema 不存在: {schema_path}")
        principles_path = role.get("principles", "")
        if principles_path:
            rel_princ = os.path.join(app_path, principles_path)
            if not os.path.exists(rel_princ) and not os.path.exists(principles_path):
                output_failure("OIC-E533", f"角色 {role['role_name']} 的 principles 不存在: {principles_path}")

    # Step 6: 创建 workspace 运行目录
    os.makedirs(ws_base, exist_ok=True)
    os.makedirs(args.workspace_path, exist_ok=True)

    # 写入 APP_REF
    app_ref_f = os.path.join(ws_base, "APP_REF")
    with open(app_ref_f, "w", encoding="utf-8") as f:
        f.write(app_path)

    # 写入 WORKSPACE_ROOT
    ws_root_f = os.path.join(ws_base, "WORKSPACE_ROOT")
    with open(ws_root_f, "w", encoding="utf-8") as f:
        f.write(os.path.abspath(args.workspace_path))

    # v9.2: 删除 process 目录创建（process 机制已废弃）

    # 创建产出物目录（v9.2: 删除 type 路由，统一解析）
    auto_dirs_resolved = set()
    for role in registry:
        for o in role.get("outputs", []):
            resolved = resolve_workspace_output(ws_id, o["path"], app_path)
            out_dir = os.path.dirname(resolved)
            if out_dir:
                auto_dirs_resolved.add(out_dir)
        for inp in role.get("inputs", []):
            resolved = resolve_workspace_output(ws_id, inp["path"], app_path)
            inp_dir = os.path.dirname(resolved)
            if inp_dir:
                auto_dirs_resolved.add(inp_dir)

    manifest_path = os.path.join(app_path, "manifest.json")
    if os.path.exists(manifest_path):
        with open(manifest_path, "r", encoding="utf-8-sig") as f:
            manifest = json.load(f)
        ws_template = manifest.get("workspace_template", {})
        for dir_path in ws_template.get("dirs", []):
            full_dir = os.path.join(args.workspace_path, dir_path)
            os.makedirs(full_dir, exist_ok=True)

    for dir_path in auto_dirs_resolved:
        os.makedirs(dir_path, exist_ok=True)

    # 为 inputs 创建占位骨架（v9.2: 不再读 type，按扩展名判断）
    for role in registry:
        for inp in role.get("inputs", []):
            inp_path = inp.get("path", "")
            if not inp_path:
                continue
            full_path = resolve_workspace_output(ws_id, inp_path, app_path)
            if not os.path.exists(full_path):
                os.makedirs(os.path.dirname(full_path), exist_ok=True)
                _, ext = os.path.splitext(full_path)
                if ext.lower() == '.json':
                    continue
                inp_name = inp.get('name', inp_path)
                placeholder = f"# {inp_name}\n\n（待填写）\n"
                with open(full_path, "w", encoding="utf-8") as f:
                    f.write(placeholder)

    # Step 7: 初始化 STATE.json
    if os.path.exists(state_path) and not args.force:
        try:
            with open(state_path, "r", encoding="utf-8-sig") as f:
                existing = json.load(f)
            if existing.get("terminal_state"):
                output_success("already_terminal")
            else:
                output_success("already_initialized")
        except Exception:
            pass

    initial_state = {
        "schema_version": "4.1",
        "workspace_id": ws_id,
        "step_status": {},
        "terminal_state": None,
        "completed": {},       # v4.1: 持久完成记录（JOIN 判断权威源）
        "pending_routes": {},  # v4.1: 瞬态路由信号（路由后清空）
        "edge_counts": {},
        "pending_dispatches": None,
        "history": [],
        "metadata": {"started_at": now_iso(), "last_advance_at": None, "user_request": ""}
    }

    save_state(state_path, initial_state)

    # v7.2: 注册到工作区索引
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from workspace_index import register
        register(ws_id, app_path, schema_version="4.1")
    except Exception:
        pass

    message = "force_reinitialized" if args.force else "initialized"
    output_success(message, initial_state, registry, router)

if __name__ == "__main__":
    main()
