#!/usr/bin/env python3
"""step.py — 指令周期统一入口（facade 层）。

将传统 5 步指令周期合并为 2 步：
  1. step.py --next          → 获取下一步指令，返回 delegate / confirm / complete
  2. step.py --submit        → 提交执行结果，返回 delegate / confirm / complete / rework / idempotent
  3. step.py --decide        → 提交用户确认决策

内部通过 subprocess 调用 orchestrator.py，不复制任何业务逻辑。
旧 5 步协议（直接调用 orchestrator.py）完全保留向后兼容。

Usage:
  python engine/scripts/step.py --next  [--workspace-id WS_ID] [--task-request "..."]
  python engine/scripts/step.py --submit --step STEP1 --dispatch-id ckpt_xxx --outputs '[...]' [--workspace-id WS_ID]
  python engine/scripts/step.py --decide --decisions '[...]' [--workspace-id WS_ID]

典型流程：
  主 Agent:
    1. python engine/scripts/step.py --next → action=delegate + dispatches
    2. Task(role-executor) 执行 dispatch
    3. (role-executor 内部) python engine/scripts/step.py --submit → next=delegate/confirm/complete/rework
    4. 若 next=delegate → 回到 1
       若 next=confirm  → 收集决策后 --decide，再回到 1
       若 next=complete → 结束
       若 next=rework   → role-executor 重新执行同一步骤后再次 --submit
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_ws_state, resolve_app_path
from state_io import load_state, save_state

# 可配置超时（与 orchestrator.py 保持一致）
_SCRIPT_TIMEOUT = int(os.environ.get("STATE_OP_TIMEOUT", "30"))

# 引擎脚本路径（相对于 workspace root，与 orchestrator.py 内部调用方式一致）
_ORCHESTRATOR = "engine/scripts/orchestrator.py"


# ─── 工具函数 ───
# v4.2: _save_state_locked 已删除，所有写入通过 state_io.save_state()

# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def run_engine(args_list):
    """调用引擎脚本并返回 (success, result_dict)。

    与 orchestrator.py 的 run_script 保持相同的容错策略：
    - returncode 0    → 解析 stdout 为 JSON，返回 (True, data)
    - returncode != 0 → 仍尝试解析 stdout（orchestrator 的 output_error 也输出 JSON），
                        解析失败时回退到 stderr。
    """
    cmd = [sys.executable] + args_list
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=_SCRIPT_TIMEOUT, encoding="utf-8", errors="replace", env={**os.environ, "PYTHONIOENCODING": "utf-8"}
        )
        if result.returncode == 0:
            try:
                return True, json.loads(result.stdout)
            except (json.JSONDecodeError, ValueError):
                return False, {"error": f"无法解析输出: {result.stdout[:200]}"}
        else:
            try:
                return False, json.loads(result.stdout)
            except (json.JSONDecodeError, ValueError):
                return False, {"error": result.stderr.strip() or f"exit code {result.returncode}"}
    except subprocess.TimeoutExpired:
        return False, {"error": f"超时（{_SCRIPT_TIMEOUT}s）"}
    except Exception as e:
        return False, {"error": str(e)}


def _print_json(data, workspace_id=None):
    """输出 JSON 并退出（exit 0）。

    自动注入 workspace_id 到 data 中（供 _gen_directive 使用），
    并生成 directive 字段。主 Agent 只读 directive 执行。
    """
    if workspace_id:
        data["workspace_id"] = workspace_id
    if "directive" not in data:
        data["directive"] = _gen_directive(data)
    print(json.dumps(data, ensure_ascii=False, indent=2))
    sys.exit(0)


def _gen_directive(data):
    """根据 action/next/status 自动生成 directive 文本。

    这是旧引擎 .mdc 规则的代码化——把原来主 Agent 需要记住的规则
    变成引擎输出中的固定指令文本。
    """
    sid = data.get("workspace_id", "")
    action = data.get("action", "")
    next_val = data.get("next", "")
    status = data.get("status", "")

    # 构建 workspace 参数后缀
    s = f" --workspace-id {sid}" if sid else ""

    # --next 输出的 action
    if action == "delegate":
        prompts = data.get("task_prompts", [])
        n = len(prompts)
        parallel = data.get("parallel", False)
        if n == 0:
            return f"调 step.py --next{s} 获取任务"
        if n == 1:
            return (f"发起 1 个 Task(role-executor, prompt 为 task_prompts[0])。"
                    f"Task 返回后调 step.py --next{s}")
        if parallel:
            return (f"发起 {n} 个 Task(role-executor)（同一消息并行）。"
                    f"全部 Task 返回后调 step.py --next{s}")
        return (f"发起 {n} 个 Task(role-executor)。全部 Task 返回后调 step.py --next{s}")

    if action == "confirm":
        pending = data.get("pending", [])
        decide_items = []
        for p in pending:
            step = p.get("step", "")
            decide_items.append(f'{{"step":"{step}","decision":"<confirmed 或 fail>"}}')
        decisions_json = "[" + ",".join(decide_items) + "]"
        steps_desc = ", ".join(p.get("step", "?") for p in pending)
        return (f"向用户展示以下步骤的确认请求：{steps_desc}。"
                f"收到用户回复后执行：\n"
                f"python engine/scripts/step.py --decide --decisions '{decisions_json}'{s}")

    if action == "complete":
        return "任务完成，结束"

    if action == "loop":
        return f"调 step.py --next{s}"

    if action == "wait":
        reason = data.get("reason", "等待中")
        return f"BLOCKING：{reason}。向用户报告并等待介入"

    if action == "error":
        err = data.get("error", data.get("failed", "未知错误"))
        return f"BLOCKING：引擎错误 — {err}"

    if action == "unknown":
        return f"BLOCKING：引擎返回未知状态 — {data.get('next', '?')}"

    # --submit 输出的 next
    if next_val == "delegate":
        return f"调 step.py --next{s} 获取下一步"
    if next_val == "confirm":
        pending = data.get("pending", [])
        decide_items = []
        for p in pending:
            step = p.get("step", "")
            decide_items.append(f'{{"step":"{step}","decision":"<confirmed 或 fail>"}}')
        decisions_json = "[" + ",".join(decide_items) + "]"
        steps_desc = ", ".join(p.get("step", "?") for p in pending)
        return (f"向用户展示确认请求：{steps_desc}。收到回复后执行：\n"
                f"python engine/scripts/step.py --decide --decisions '{decisions_json}'{s}")
    if next_val == "complete":
        return "任务完成，结束"
    if next_val == "rework":
        return f"Gate 校验失败，重新执行（调 step.py --next 获取）"
    if next_val == "idempotent":
        return f"已处理，跳过。调 step.py --next{s}"
    if next_val == "wait":
        return f"BLOCKING：{data.get('reason', '等待中')}"
    if next_val == "error":
        failed = data.get("failed", [])
        return f"BLOCKING：永久失败 — {failed}"

    # --decide 输出的 next
    if status == "success" and next_val:
        if next_val == "delegate":
            return f"调 step.py --next{s}"
        if next_val == "complete":
            return "任务完成，结束"
        if next_val == "wait":
            return f"BLOCKING：{data.get('reason', '等待中')}"

    return f"调 step.py --next{s}"


def _print_error(error, action="error"):
    """输出错误 JSON 并以非零码退出。"""
    print(json.dumps({
        "action": action, "status": "error", "error": error,
        "directive": f"BLOCKING：引擎错误 — {error}"
    }, ensure_ascii=False, indent=2))
    sys.exit(1)


def _check_idempotent(state, dispatch_id):
    """检查 dispatch_id 是否已处理（已 advance 到 completed）。"""
    if not dispatch_id:
        return False

    # v4.1: 读 completed
    completed = state.get("completed", {}) or {}
    for ckpt_data in completed.values():
        if isinstance(ckpt_data, dict) and ckpt_data.get("id") == dispatch_id:
            return True
    return False


# ─── task_prompt 生成 ──

def _build_task_prompt(dispatch, workspace_id, state_path, app_path=None):
    """根据 dispatch 信息自动生成可直接使用的 Task(role-executor) prompt。

    主 Agent 拿到这个字符串后，直接作为 Task 的 prompt 参数传入即可，
    无需理解 dispatch 内部结构。
    """
    step = dispatch.get("step", "")
    role = dispatch.get("role", "")
    skill = dispatch.get("skill", "") or dispatch.get("parameters", {}).get("skill", "")
    ckpt_id = dispatch.get("checkpoint_id", "")
    output_targets = dispatch.get("output_targets", [])
    inputs = dispatch.get("inputs", [])
    task_ctx = dispatch.get("task_context", {})
    user_request = task_ctx.get("user_request", "")
    principles_path = dispatch.get("principles", "")

    lines = []
    lines.append(f"## 执行指令 (dispatch_instruction)")
    lines.append(f"")
    lines.append(f"- workspace_id: {workspace_id}")
    lines.append(f"- step: {step}")
    lines.append(f"- role: {role}")
    # skill 用完整路径，role-executor 直接 Read
    skill_full = os.path.join(app_path, skill) if app_path and skill else skill
    lines.append(f"- skill: {skill_full}")
    lines.append(f"")
    lines.append(f"## 产出物路径")
    for ot in output_targets:
        lines.append(f"- {ot.get('name', '')}: {ot.get('path', '')}")
    lines.append(f"")
    # 注入产出物 schema 约束（从 dispatch 的 schema_constraints 读取，与 inputs 同源）
    schema_constraints = dispatch.get("schema_constraints", {})
    if schema_constraints:
        lines.append(f"## 产出物格式约束（必须遵守，Gate 会校验）")
        req_top = schema_constraints.get("required_top", [])
        if req_top:
            lines.append(f"- 顶层必填字段: {', '.join(req_top)}")
        result_req = schema_constraints.get("result_required", [])
        if result_req:
            lines.append(f"- result 必填字段: {', '.join(result_req)}")
        verdict_enum = schema_constraints.get("verdict_enum")
        if verdict_enum:
            lines.append(f"- result.verdict 允许值: {', '.join(verdict_enum)}")
        lines.append("")
    if inputs:
        lines.append(f"## 输入文件")
        for inp in inputs:
            lines.append(f"- {inp}")
        lines.append(f"")
    # 注入原则指导文档（如果 registry 中声明了 principles）
    if principles_path and app_path:
        principles_full = os.path.join(app_path, principles_path)
        if os.path.exists(principles_full):
            try:
                with open(principles_full, "r", encoding="utf-8-sig") as f:
                    principles_content = f.read().strip()
                if principles_content:
                    lines.append(f"## 原则指导")
                    lines.append(principles_content)
                    lines.append(f"")
            except Exception:
                pass
    # 反馈物料由边 carries 自动注入，无需 step.py 处理。
    if user_request:
        lines.append(f"## 用户需求")
        lines.append(user_request)
        lines.append(f"")
    lines.append(f"## 执行要求")
    lines.append(f"1. Read skill 文件")
    lines.append(f"2. 按 skill 文件的步骤执行")
    lines.append(f"3. 用 Write 写入产出物到指定路径")
    # verdict 从返回值读取（不从产出物文件读），产出物可以是任意格式
    verdict_hint = ""
    schema_constraints = dispatch.get("schema_constraints", {})
    verdict_enum = schema_constraints.get("verdict_enum")
    if verdict_enum:
        verdict_hint = f'，verdict 从以下值中选择: {", ".join(verdict_enum)}'
    lines.append(f'4. 返回 JSON：{{"status": "confirmed", "step": "{step}", "workspace_id": "{workspace_id}", "verdict": "<verdict值>"{verdict_hint}, "outputs": [产出物列表]}}')

    return "\n".join(lines)


# ─── --next ───

def cmd_next(args):
    """step.py --next: 获取下一步指令。

    v4.0: 统一走 orchestrator --phase dispatch（无并行模式分支）。
    将返回值翻译为统一 action 格式：
      - delegate : 有 dispatches 需要执行
      - confirm  : 有 awaiting_confirmation 需要用户确认
      - complete : 任务完成
      - wait     : 等待中
      - loop     : 状态已更新，请再次调用 --next
    """
    app_path = resolve_app_path(args.workspace_id, args.app_path)
    state_path = resolve_ws_state(args.workspace_id)

    extra = ["--state-path", state_path, "--app-path", app_path]
    if args.workspace_id:
        extra += ["--workspace-id", args.workspace_id]
    if args.task_request:
        extra += ["--task-request", args.task_request]

    # v4.0: 统一走 dispatch（v4.0 unified dispatch）
    ok, result = run_engine([_ORCHESTRATOR, "--phase", "dispatch"] + extra)
    if not ok:
        _print_error(result.get("error", "orchestrator dispatch 失败"))

    next_val = result.get("next", "")
    dispatches = result.get("dispatches", [])
    pending = result.get("pending", [])

    # ── 翻译 orchestrator 返回值为统一 action 格式 ──
    if next_val == "execute" and dispatches:
        task_prompts = []
        for d in dispatches:
            prompt = _build_task_prompt(d, args.workspace_id, state_path, app_path)
            task_prompts.append(prompt)
        # v4.1: pbc 从 step_status 派生，不再手动设置（消除多源冲突）
        # pbc = len(dispatches) 的逻辑已移除，Hook② 直接读 len(step_status)
        _print_json({
            "action": "delegate",
            "dispatches": dispatches,
            "task_prompts": task_prompts,
            "parallel": result.get("parallel", False),
        }, args.workspace_id)
    elif next_val == "confirm" and pending:
        _print_json({"action": "confirm", "pending": pending}, args.workspace_id)
    elif next_val == "complete":
        _print_json({"action": "complete", "reason": result.get("reason", "")}, args.workspace_id)
    elif next_val == "dispatch":
        # 缓存了新 dispatch，主 Agent 再次调 --next 即可读取
        _print_json({"action": "loop", "message": "状态已更新，请再次调用 --next"}, args.workspace_id)
    elif next_val == "wait":
        _print_json({"action": "wait", "reason": result.get("reason", "等待中")}, args.workspace_id)
    else:
        _print_json({"action": "unknown", "next": next_val, "raw": result}, args.workspace_id)


# ─── --submit ───

def _resolve_dispatch_id(state, step):
    """从 STATE.json 自动定位 dispatch_id。

    v4.0: 只读主线 step_status（无并行分支）。
    """
    info = state.get("step_status", {}).get(step, {})
    did = info.get("dispatch_id")
    if did:
        return did
    return None


def cmd_submit(args):
    """step.py --submit: 提交执行结果（role-executor 调用）。

    内部调用 orchestrator.py --phase post_execute，将返回值翻译为统一 next 格式：
      - delegate  : 有后续步骤需执行（调 --next 获取）
      - confirm   : 有 awaiting_confirmation
      - complete  : 任务完成
      - rework    : Gate 失败，重试 dispatch 已缓存（role-executor 需重新执行）
      - idempotent: dispatch_id 已处理，跳过
      - error     : 永久失败

    v4.0.1 路径权威源机制：outputs 路径从 registry.json 的权威声明中取，
    不信任 role-executor 返回的路径（role-executor 可能拼错路径）。
    """
    app_path = resolve_app_path(args.workspace_id, args.app_path)
    state_path = resolve_ws_state(args.workspace_id)

    # ── 路径权威源：从 registry.json 读取 output_targets ──
    # role-executor 返回的 outputs 仅用于记录，不作为路径权威
    from session_path import resolve_workspace_output
    step_name = args.step
    registry_path = os.path.join(app_path, "registry.json")
    router_path = os.path.join(app_path, "ROUTER.json")
    ws_id = args.workspace_id or ""

    authoritative_outputs = []
    try:
        with open(router_path, "r", encoding="utf-8-sig") as f:
            router_data = json.load(f)
        with open(registry_path, "r", encoding="utf-8-sig") as f:
            registry_data = json.load(f)

        # 从 ROUTER.json 找到 step → role 映射
        step_entry = next((s for s in router_data.get("steps", []) if s["step"] == step_name), None)
        if step_entry:
            role_name = step_entry["role"]
            reg_entry = next((r for r in registry_data if r.get("role_name") == role_name), None)
            if reg_entry:
                for o in reg_entry.get("outputs", []):
                    o_type = o.get("type", "deliverable")
                    resolved = resolve_workspace_output(ws_id, o["path"], app_path, o_type)
                    authoritative_outputs.append({
                        "name": o.get("name", ""),
                        "path": resolved,
                        "type": o_type
                    })
    except Exception:
        pass  # 读取失败时回退到 role-executor 返回值

    # 如果成功获取权威 outputs，使用它；否则回退到 role-executor 返回值
    if authoritative_outputs:
        outputs = authoritative_outputs
    else:
        # 回退：解析 role-executor 返回的 outputs（相对路径自动解析为绝对路径）
        try:
            outputs = json.loads(args.outputs) if isinstance(args.outputs, str) else args.outputs
        except (json.JSONDecodeError, ValueError):
            _print_error("--outputs 不是有效 JSON")

        from session_path import resolve_ws_base
        ws_base = resolve_ws_base(args.workspace_id) if args.workspace_id else os.path.dirname(state_path)
        ws_root = ws_base
        wr_file = os.path.join(ws_base, "WORKSPACE_ROOT") if ws_base else None
        if wr_file and os.path.exists(wr_file):
            with open(wr_file, "r", encoding="utf-8-sig") as f:
                ws_root = f.read().strip()
        for i, o in enumerate(outputs):
            if isinstance(o, str):
                o = {"path": o}
                outputs[i] = o
            p = o.get("path", "")
            if p and not os.path.isabs(p):
                o["path"] = os.path.join(ws_root, p)

    # ── 加载 STATE.json ──
    try:
        with open(state_path, "r", encoding="utf-8-sig") as f:
            st = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        st = {}

    # ── 自动定位 dispatch_id（若未显式传入）──
    # dispatch_id 是幂等令牌，不是执行前提条件。
    # 找不到时跳过幂等检查，不阻塞流程。
    dispatch_id = args.dispatch_id
    if not dispatch_id:
        dispatch_id = _resolve_dispatch_id(st, args.step)

    # ── 幂等检查：dispatch_id 已处理则跳过 ──
    # 仅在 dispatch_id 存在时检查（避免 None 匹配）
    if dispatch_id and _check_idempotent(st, dispatch_id):
        _print_json({
            "status": "success",
            "next": "idempotent",
            "message": f"dispatch_id {dispatch_id} 已处理",
        })

    # ── 构造 post_execute results 参数 ──
    result_entry = {
        "step": args.step,
        "status": "confirmed",
        "outputs": outputs,
    }
    if args.verdict:
        result_entry["verdict"] = args.verdict

    extra = ["--state-path", state_path, "--app-path", app_path]
    if args.workspace_id:
        extra += ["--workspace-id", args.workspace_id]

    ok, result = run_engine([
        _ORCHESTRATOR,
        "--phase", "post_execute",
        "--results", json.dumps([result_entry]),
    ] + extra)

    if not ok:
        _print_error(result.get("error", "orchestrator post_execute 失败"))

    # ── 翻译返回值 ──
    next_val = result.get("next", "")
    failed = result.get("failed", [])
    pending = result.get("pending", [])
    gate_results = result.get("gate_results", [])

    if failed and next_val == "error":
        action = {"status": "error", "next": "error", "failed": failed}
    elif next_val == "error":
        action = {"status": "error", "next": "error", "reason": result.get("reason", "")}
    elif next_val in ("dispatch",):
        action = {
            "status": "success",
            "next": "delegate",
            "gate_results": gate_results,
        }
    elif next_val == "confirm":
        action = {
            "status": "success",
            "next": "confirm",
            "pending": pending,
            "gate_results": gate_results,
        }
    elif next_val == "complete":
        action = {"status": "success", "next": "complete", "gate_results": gate_results}
    elif next_val == "wait":
        action = {"status": "success", "next": "wait", "reason": result.get("reason", "")}
    else:
        action = {"status": "success", "next": next_val, "raw": result, "gate_results": gate_results}

    _print_json(action, args.workspace_id)


# ─── --decide ───

def cmd_decide(args):
    """step.py --decide: 提交用户确认决策。

    内部调用 orchestrator.py --phase post_confirm，将返回值翻译为统一 next 格式。
    """
    app_path = resolve_app_path(args.workspace_id, args.app_path)
    state_path = resolve_ws_state(args.workspace_id)

    try:
        decisions = json.loads(args.decisions) if isinstance(args.decisions, str) else args.decisions
    except (json.JSONDecodeError, ValueError):
        _print_error("--decisions 不是有效 JSON")

    extra = ["--state-path", state_path, "--app-path", app_path]
    if args.workspace_id:
        extra += ["--workspace-id", args.workspace_id]

    ok, result = run_engine([
        _ORCHESTRATOR,
        "--phase", "post_confirm",
        "--decisions", json.dumps(decisions),
    ] + extra)

    if not ok:
        _print_error(result.get("error", "orchestrator post_confirm 失败"))

    next_val = result.get("next", "")

    if next_val == "dispatch":
        action = {"status": "success", "next": "delegate"}
    elif next_val == "complete":
        action = {"status": "success", "next": "complete"}
    elif next_val == "wait":
        action = {"status": "success", "next": "wait", "reason": result.get("reason", "")}
    else:
        action = {"status": "success", "next": next_val}

    _print_json(action, args.workspace_id)


# ─── --list-workspaces ───

def cmd_list_workspaces(args):
    """列出所有 workspace 及其状态。"""
    ws_dir = os.path.join("runtime", "workspaces")
    result = []
    if os.path.isdir(ws_dir):
        for ws_id in sorted(os.listdir(ws_dir)):
            ws_base = os.path.join(ws_dir, ws_id)
            if not os.path.isdir(ws_base):
                continue
            state_f = os.path.join(ws_base, "STATE.json")
            if not os.path.exists(state_f):
                continue
            try:
                with open(state_f, "r", encoding="utf-8-sig") as f:
                    st = json.load(f)
                executing = list(st.get("step_status", {}).keys())
                completed = list(st.get("completed", {}).keys())
                terminal = st.get("terminal_state")
                # 读 APP_REF
                app_ref_f = os.path.join(ws_base, "APP_REF")
                app_ref = ""
                if os.path.exists(app_ref_f):
                    with open(app_ref_f, "r", encoding="utf-8-sig") as f:
                        app_ref = f.read().strip()
                # 读 WORKSPACE_ROOT
                ws_root_f = os.path.join(ws_base, "WORKSPACE_ROOT")
                ws_root = ""
                if os.path.exists(ws_root_f):
                    with open(ws_root_f, "r", encoding="utf-8-sig") as f:
                        ws_root = f.read().strip()
                result.append({
                    "workspace_id": ws_id,
                    "app": app_ref,
                    "executing": executing,
                    "completed": completed,
                    "terminal": terminal,
                    "workspace_root": ws_root or None,
                })
            except Exception:
                pass
    print(json.dumps({"workspaces": result}, ensure_ascii=False, indent=2))


# ─── main ───

def main():
    parser = argparse.ArgumentParser(
        description="指令周期统一入口（facade 层）— 合并 5 步为 2 步",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # 公共参数
    parser.add_argument("--workspace-id", default=None, help="Session ID")
    parser.add_argument("--state-path", default=None, help="STATE.json 路径（覆盖 workspace 推导）")
    parser.add_argument("--app-path", default=None, help="应用包路径（覆盖 workspace 推导）")

    # 命令（互斥，store_true）
    parser.add_argument("--next", action="store_true", help="获取下一步指令")
    parser.add_argument("--submit", action="store_true", help="提交执行结果（role-executor 调用）")
    parser.add_argument("--decide", action="store_true", help="提交用户确认决策")
    parser.add_argument("--list-workspaces", action="store_true", help="列出所有运行中的应用及状态")

    # --next 参数
    parser.add_argument("--task-request", default=None, help="--next: 用户需求文本")

    # --submit 参数
    parser.add_argument("--step", default=None, help="--submit: 步骤 ID")
    parser.add_argument("--dispatch-id", default=None, help="--submit: dispatch 唯一 ID（可选，未传入时自动从 STATE.json 定位）")
    parser.add_argument("--outputs", default=None, help="--submit: 产出物 JSON 数组 [{name, path}]")
    parser.add_argument("--verdict", default=None, help="--submit: 角色 verdict 值（从 role-executor 返回值读取）")

    # --decide 参数
    parser.add_argument("--decisions", default=None, help="--decide: 用户决策 JSON 数组")

    args = parser.parse_args()

    if args.list_workspaces:
        cmd_list_workspaces(args)
    elif args.next:
        cmd_next(args)
    elif args.submit:
        if not args.step:
            parser.error("--submit 需要 --step")
        # --dispatch-id 可选：未传入时 cmd_submit 自动从 STATE.json 定位
        if not args.outputs:
            parser.error("--submit 需要 --outputs")
        cmd_submit(args)
    elif args.decide:
        if not args.decisions:
            parser.error("--decide 需要 --decisions")
        cmd_decide(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
