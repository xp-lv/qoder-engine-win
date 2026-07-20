#!/usr/bin/env python3
"""Gate — 统一两阶段校验器。

Layer 0: 协议信封校验（--mode envelope）
  校验 role-executor 返回值的格式契约（step/verdict/status/outputs）。
  失败 → ENVELOPE_FAIL → BLOCKING（协议违规，不走 fail 边）。
  verdict 合法性权威源：ROUTER.json 的 transitions keys。

Layer 1: 产出物文件校验（--mode file，默认）
  校验磁盘产出物文件的存在性 + 非空 + 二进制短路 + 可选 contract。
  失败 → FAIL → 走 fail 边（质量问题，可自动重试）。

Usage:
  python engine/scripts/gate.py --mode envelope --step <STEP> --envelope <json> --app-path <path>
  python engine/scripts/gate.py --mode file --step <STEP> --output-path <path> --app-path <path> [--workspace-id <id>]
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path


# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def output(data):
    print(json.dumps(data, ensure_ascii=False))
    sys.exit(0)


def fail(message):
    output({"verdict": "FAIL", "errors": [message]})


def get_nested(data, path):
    """按点分隔路径读取嵌套字段。"""
    val = data
    for k in path.split("."):
        if isinstance(val, dict):
            val = val.get(k)
        else:
            return None
    return val


def validate_schema(data, schema):
    """统一的 Schema 校验（v8.0：简化为二件套 required + enum）。
    返回 errors 列表（空 = 通过）。

    v8.0 变更：删除 minLength / items / additionalProperties 校验。
    原因：这三个字段从未被 compiler.py 自动生成，属于文档定义但无代码消费的“僵尸约束”。
    保留 required（必填字段）+ enum（枚举值校验）两件真有消费者的约束。
    """
    errors = []

    # required 字段
    for field in schema.get("required", []):
        if field not in data:
            errors.append(f"缺少必填字段: {field}")

    # properties 类型校验
    for prop, rules in schema.get("properties", {}).items():
        val = get_nested(data, prop)
        if val is None:
            continue

        expected_type = rules.get("type")
        type_map = {
            "string": lambda v: isinstance(v, str),
            "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
            "boolean": lambda v: isinstance(v, bool),
            "float": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
            "array": lambda v: isinstance(v, list),
            "object": lambda v: isinstance(v, dict),
        }
        if expected_type and expected_type in type_map:
            if not type_map[expected_type](val):
                errors.append(f"字段 {prop} 应为 {expected_type}")

    # enum 校验（与类型校验分离，独立循环以支持嵌套路径如 result.verdict）
    for prop, rules in schema.get("properties", {}).items():
        val = get_nested(data, prop)
        if val is not None and "enum" in rules:
            if val not in rules["enum"]:
                errors.append(f"字段 {prop} 值 '{val}' 不在允许范围 {rules['enum']} 中")

    # 禁止模式
    for pattern in schema.get("_forbidden_patterns", []):
        content = json.dumps(data, ensure_ascii=False)
        if pattern in content:
            errors.append(f"包含禁止内容: {pattern}")

    return errors


def validate_envelope(envelope, step_def):
    """Gate Layer 0: 协议信封校验。

    校验 role-executor 返回值的格式契约。
    失败 → ENVELOPE_FAIL（BLOCKING，不走 fail 边）。

    权威源：ROUTER.json 的 transitions keys（天然包含所有合法 verdict）。
    """
    errors = []

    # 1. step 字段必须存在
    step = envelope.get("step", "")
    if not step:
        errors.append("信封缺少 step 字段")
        return errors

    # 2. verdict 合法性（权威源：ROUTER.json transitions）
    verdict = envelope.get("verdict", "")
    if verdict:
        transitions = step_def.get("transitions", {}) if step_def else {}
        # 合法 verdict = transitions keys（排除系统保留词 fail）
        legal_verdicts = set(transitions.keys()) - {"fail"}
        # 无条件出边会被编译器写入 confirmed，故 confirmed 始终合法
        legal_verdicts.add("confirmed")
        if verdict not in legal_verdicts:
            errors.append(f"verdict '{verdict}' 不在合法集合 {sorted(legal_verdicts)} 中")

    # 3. status 字段（可选：仅 confirmed/BLOCKING 合法）
    status = envelope.get("status", "")
    if status and status not in ("confirmed", "BLOCKING"):
        errors.append(f"status '{status}' 不合法（仅允许 confirmed 或 BLOCKING）")

    # 4. outputs 结构校验（必须是数组，每项可以是字符串路径或 {path: "..."} 对象）
    outputs = envelope.get("outputs", [])
    if not isinstance(outputs, list):
        errors.append("outputs 必须是数组")
    else:
        for i, o in enumerate(outputs):
            if isinstance(o, str):
                continue  # 字符串路径合法
            if not isinstance(o, dict):
                errors.append(f"outputs[{i}] 必须是字符串或对象")
            elif "path" not in o:
                errors.append(f"outputs[{i}] 缺少 path 字段")

    return errors


def validate_deliverable_contract(file_path, raw_content, contract):
    """P1 (v8.2): 对 deliverable 产出物做深度校验。

    contract 是 schema.json._required_files[].contract 中的手写声明，支持：
      - min_lines: 文件行数 ≥ N
      - required_headings: 每个 heading 必须在文档中出现（grep 语义）
      - req_coverage: 每个 REQ-ID 必须在文档中出现
      - forbidden_patterns: 文档不得包含的字符串

    返回 errors 列表（空 = 通过）。
    """
    errors = []

    # min_lines: 行数校验
    min_lines = contract.get("min_lines")
    if min_lines and isinstance(min_lines, int):
        line_count = raw_content.count("\n") + 1
        if line_count < min_lines:
            errors.append(f"行数不足: {line_count} < min_lines={min_lines}")

    # required_headings: 标题/关键字必须出现
    for heading in contract.get("required_headings", []):
        if heading not in raw_content:
            errors.append(f"缺少必需标题/关键字: {heading}")

    # req_coverage: REQ-ID 覆盖校验
    missing_reqs = [req for req in contract.get("req_coverage", []) if req not in raw_content]
    if missing_reqs:
        errors.append(f"REQ-ID 未覆盖: {missing_reqs}")

    # forbidden_patterns: 禁止内容
    for pattern in contract.get("forbidden_patterns", []):
        if pattern in raw_content:
            errors.append(f"包含禁止内容: {pattern}")

    return errors


def main():
    parser = argparse.ArgumentParser(description="Gate 统一两阶段校验器")
    parser.add_argument("--mode", default="file", choices=["envelope", "file"],
                        help="envelope=信封校验(Layer 0);file=文件校验(Layer 1,默认)")
    parser.add_argument("--step", required=True)
    parser.add_argument("--output-path", default=None, help="file 模式:产出物路径")
    parser.add_argument("--envelope", default=None, help="envelope 模式:完整信封 JSON")
    parser.add_argument("--state-path", default=None)
    parser.add_argument("--app-path", default=None)
    parser.add_argument("--workspace-id", default=None)
    args = parser.parse_args()

    app_path = args.app_path or resolve_app_path(args.workspace_id)
    # v9.2: state_path 延迟到 file 模式才解析（envelope 模式不需要 state）
    state_path = args.state_path
    if state_path is None and args.workspace_id:
        try:
            state_path = resolve_ws_state(args.workspace_id)
        except Exception:
            state_path = None

    # ── 加载 ROUTER.json（两种模式都需要查找 step_def）──
    router_path = os.path.join(app_path, "ROUTER.json")
    router = {}
    if os.path.exists(router_path):
        with open(router_path, "r", encoding="utf-8-sig") as f:
            router = json.load(f)
    step_def = next((s for s in router.get("steps", []) if s["step"] == args.step), None)

    # ════════════════════════════════════════════════════════════
    # Layer 0: 协议信封校验（--mode envelope）
    # 失败 → ENVELOPE_FAIL → BLOCKING（不走 fail 边）
    # ════════════════════════════════════════════════════════════
    if args.mode == "envelope":
        if not args.envelope:
            output({"verdict": "ENVELOPE_FAIL", "errors": ["--mode envelope 需要 --envelope 参数"]})
        try:
            envelope = json.loads(args.envelope)
        except (json.JSONDecodeError, ValueError) as e:
            output({"verdict": "ENVELOPE_FAIL", "errors": [f"envelope 不是有效 JSON: {e}"]})
        errors = validate_envelope(envelope, step_def)
        if errors:
            output({"verdict": "ENVELOPE_FAIL", "errors": errors})
        output({"verdict": "PASS", "errors": []})

    # ════════════════════════════════════════════════════════════
    # Layer 1: 产出物文件校验（--mode file，默认）
    # 失败 → FAIL → 走 fail 边（质量问题，可重试）
    # ════════════════════════════════════════════════════════════
    if not args.output_path:
        fail("--mode file 需要 --output-path 参数")

    # ── 1. 物理检查（统一，不区分产物类型）──
    if not os.path.exists(args.output_path):
        fail(f"产出物文件不存在: {args.output_path}")

    # 目录类型产出物：检查存在且非空即 PASS
    if os.path.isdir(args.output_path):
        dir_contents = os.listdir(args.output_path)
        if not dir_contents:
            fail(f"产出物目录为空: {args.output_path}")
        output({"verdict": "PASS", "errors": []})

    if os.path.getsize(args.output_path) == 0:
        fail(f"产出物文件为空: {args.output_path}")

    # ── 2. 二进制文件短路：物理检查通过即 PASS ──
    BINARY_EXTENSIONS = {
        '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.svg',
        '.woff', '.woff2', '.ttf', '.eot', '.pdf', '.zip', '.tar', '.gz',
    }
    _, ext = os.path.splitext(args.output_path)
    if ext.lower() in BINARY_EXTENSIONS:
        output({"verdict": "PASS", "errors": []})

    # ── 3. 统一解析：JSON 直接用，非 JSON 包装 ──
    with open(args.output_path, "rb") as bf:
        raw_bytes = bf.read()
    try:
        raw = raw_bytes.decode("utf-8")
    except (UnicodeDecodeError, ValueError):
        # 无法解码为 UTF-8 → 物理检查通过即 PASS
        output({"verdict": "PASS", "errors": []})
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        data = {"_raw_text": raw}

    # ── 4. 查找 step / role（用于定位 schema）──
    reg_path = os.path.join(app_path, "registry.json")
    if not os.path.exists(reg_path):
        # 无配置文件 → 只做物理检查（已有内容即 PASS）
        output({"verdict": "PASS", "errors": []})

    with open(reg_path, "r", encoding="utf-8-sig") as f:
        registry = json.load(f)

    if not step_def:
        fail(f"STEP {args.step} 不在 ROUTER.json 中")

    role_name = step_def["role"]
    role_record = next((r for r in registry if r.get("role_name") == role_name), None)
    if not role_record:
        fail(f"角色 {role_name} 不在 registry.json 中")

    # ── 5. 深度契约校验（可选 contract，不再区分 type）──
    import re
    schema_dir = re.sub(r'[^\w\u4e00-\u9fff]', '_', role_name)
    schema_file = os.path.join(app_path, "roles", schema_dir, "schema.json")

    errors = []
    rf_contract = None
    if os.path.exists(schema_file):
        try:
            with open(schema_file, "r", encoding="utf-8-sig") as f:
                schema = json.load(f)
            norm_output = args.output_path.replace("\\", "/").rstrip("/")
            for rf in schema.get("_required_files", []):
                rf_path = rf.get("path", "").replace("\\", "/").rstrip("/")
                if rf_path and (norm_output.endswith(rf_path) or rf_path.endswith(norm_output)):
                    rf_contract = rf.get("contract")
                    break
        except Exception as e:
            errors.append(f"schema 加载失败: {e}")

    # 统一 contract 校验（不再按 type 分发，不再校验 result schema）
    # result.verdict 等信封字段已由 Layer 0 校验，文件只做物理检查 + 可选 contract
    if rf_contract:
        errors.extend(validate_deliverable_contract(args.output_path, raw, rf_contract))

    # ── 6. 返回 ──
    if errors:
        result = {"verdict": "FAIL", "errors": errors}
    else:
        result = {"verdict": "PASS", "errors": []}

    # 写 gate-result.json 到 workspace
    ws_base = None
    if args.workspace_id:
        from session_path import resolve_ws_base
        ws_base = resolve_ws_base(args.workspace_id)
    elif state_path:
        ws_base = os.path.dirname(state_path)
    if ws_base:
        ws_root = ws_base
        wr_file = os.path.join(ws_base, "WORKSPACE_ROOT")
        if os.path.exists(wr_file):
            with open(wr_file, "r", encoding="utf-8-sig") as f:
                ws_root = f.read().strip()
        result_file = os.path.join(ws_root, "outputs", f"{args.step}-gate-result.json")
        os.makedirs(os.path.dirname(result_file), exist_ok=True)
        with open(result_file, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)

    output(result)


if __name__ == "__main__":
    main()
