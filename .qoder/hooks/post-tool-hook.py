#!/usr/bin/env python3
"""post-tool-hook.py — Hook 独占脚本执行权

每次 subagent 返回后触发。Hook 内部执行所有引擎脚本，
主 Agent 和 subagent 均不直接调脚本。

职责：
  1. stability-analyzer 返回 → 调 fix/switch/init（如需）→ 调 step.py --next → 注入 directive
  2. role-executor 返回 → 调 step.py --submit → 读结果 → 调 step.py --next → 注入 directive
"""
import json, os, re, subprocess, sys

_HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
_ENGINE_SCRIPTS = os.path.normpath(os.path.join(_HOOK_DIR, "..", "..", "engine", "scripts"))
sys.path.insert(0, _ENGINE_SCRIPTS)

from session_path import resolve_ws_state, resolve_app_path, resolve_ws_base, read_workspace_root
from state_io import load_state, save_state

# 项目根目录
_PROJECT_ROOT = os.path.normpath(os.path.join(_HOOK_DIR, "..", ".."))
# 默认产出物工作区
default_workspace_base = os.path.join(_PROJECT_ROOT, "Z_工作区")


def default_workspace_path(app_path, ws_id):
    """推导默认 workspace_path：Z_工作区/{ws_id}"""
    return os.path.join(default_workspace_base, ws_id)


def load_json_file(path):
    """安全加载 JSON 文件。"""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None


def emit(text):
    """统一注入入口。自动补全【主Agent指令】前缀，确保每条消息都形成闭环。"""
    if not text.startswith("【主Agent指令】"):
        text = f"【主Agent指令】{text}"
    output = json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": text
        }
    }, ensure_ascii=False)
    print(output)
    sys.exit(0)


def run_script(args):
    """执行引擎脚本，返回 JSON 结果。失败时返回带 _error 字段的 dict。"""
    try:
        r = subprocess.run(
            [sys.executable] + args,
            capture_output=True, text=True, timeout=30
        )
        if r.returncode != 0:
            # 非零退出：尝试解析 stdout（引擎错误也输出 JSON），回退到 stderr
            try:
                result = json.loads(r.stdout)
                return result
            except (json.JSONDecodeError, ValueError):
                return {"_error": f"exit_code={r.returncode}", "_stderr": r.stderr.strip()[:500]}
        if r.stdout.strip():
            try:
                return json.loads(r.stdout)
            except (json.JSONDecodeError, ValueError):
                return {"_error": f"stdout_not_json: {r.stdout.strip()[:200]}"}
        return {}
    except subprocess.TimeoutExpired:
        return {"_error": "timeout(30s)"}
    except FileNotFoundError as e:
        return {"_error": f"script_not_found: {e}"}
    except Exception as e:
        return {"_error": str(e)}


def format_directive(step_result):
    """将 step.py 输出转化为完整的主Agent指令注入。

    所有注入消息统一以【主Agent指令】开头，明确告知主 Agent 应做什么、禁止做什么。
    形成闭环：主 Agent 无需猜测，严格按指令字面执行即可。
    """
    task_prompts = step_result.get("task_prompts", [])
    action = step_result.get("action", "")

    # ── delegate：有 task_prompt 需要派发 ──
    if task_prompts:
        if len(task_prompts) == 1:
            header = (
                "【主Agent指令】发起 1 个 Task(role-executor)，"
                "将下方全部内容作为 prompt 参数原样传入。\n"
                "禁止自行读取文件、写入产出物或调用引擎脚本。\n"
                "下方指令中的 step 名为引擎标准名，禁止修改、添加后缀或括号注释，必须原样传入 Task。\n\n"
            )
            return header + task_prompts[0]
        # 并行场景：明确要求同一消息发起全部 Task
        parts = [
            f"【主Agent指令】以下 {len(task_prompts)} 个 Task 必须在同一条消息中同时发起，"
            f"不要等待任何一个返回后再发起下一个。"
            f"每个使用 Task(role-executor)，prompt 为对应段全文。\n"
            f"禁止自行执行角色工作或调用引擎脚本。\n"
            f"各 Task 的 step 名为引擎标准名，禁止修改、添加后缀或括号注释，必须原样传入。"
        ]
        for i, tp in enumerate(task_prompts):
            parts.append(f"=== Task {i + 1} / {len(task_prompts)} ===")
            parts.append(tp)
        parts.append(f"全部 {len(task_prompts)} 个 Task 返回后，Hook② 会自动推进，无需手动调用任何脚本。")
        return "\n\n".join(parts)

    # ── 非 delegate 场景：根据 action 给出完整行为指令 ──
    if action == "complete":
        return "【主Agent指令】任务已全部完成，向用户报告结果并结束。"
    if action == "confirm":
        pending = step_result.get("pending", [])
        steps_desc = ", ".join(p.get("step", "?") for p in pending)
        return (f"【主Agent指令】向用户展示确认请求：{steps_desc}。"
                f"等待用户回复 confirmed 或 fail，"
                f"然后将用户回复原样传递给 Task(stability-analyzer)。")
    if action == "wait":
        reason = step_result.get("reason", "等待中")
        return f"【主Agent指令】BLOCKING：{reason}。向用户报告当前状态并等待介入。"

    # 兜底：使用 step.py 原始 directive，加前缀
    directive = step_result.get("directive", "")
    if directive:
        return f"【主Agent指令】{directive}"
    return ""


def extract_json_from_text(text, required_keys=None):
    """从文本中提取 JSON（尝试多种方式）。

    如果指定 required_keys，优先返回包含这些 key 的 JSON 块。
    """
    text = text.strip() if isinstance(text, str) else str(text)
    # 剥离 <system-reminder>...</system-reminder> 标签（Qoder 会附加到 tool_output）
    import re
    text = re.sub(r'<system-reminder>.*?</system-reminder>', '', text, flags=re.DOTALL).strip()
    # 剥离 markdown 代码块标记（```json ... ``` 或 ``` ... ```）
    if text.startswith('```'):
        lines = text.split('\n')
        if len(lines) >= 3:
            text = '\n'.join(lines[1:-1]).strip()
        elif len(lines) >= 2:
            text = '\n'.join(lines[1:]).strip()
    try:
        result = json.loads(text)
        if not required_keys or all(k in result for k in required_keys):
            return result
    except (json.JSONDecodeError, ValueError):
        pass
    # 花括号匹配：收集所有有效 JSON 块
    candidates = []
    brace_depth = 0
    start = -1
    for i, ch in enumerate(text):
        if ch == '{':
            if brace_depth == 0:
                start = i
            brace_depth += 1
        elif ch == '}':
            brace_depth -= 1
            if brace_depth == 0 and start >= 0:
                try:
                    parsed = json.loads(text[start:i + 1])
                    if not required_keys or all(k in parsed for k in required_keys):
                        return parsed
                    candidates.append(parsed)
                except (json.JSONDecodeError, ValueError):
                    pass
                start = -1
    # 未找到含 required_keys 的 JSON 块 → 返回 None（不 fallback）
    return None


def format_gate_errors(submit_result):
    """从 submit 返回值中提取 Gate 校验失败的错误详情。"""
    gate_results = submit_result.get("gate_results", [])
    errors = []
    for gr in gate_results:
        if gr.get("verdict") == "FAIL":
            step = gr.get("step", "?")
            errs = gr.get("errors", [])
            if errs:
                errors.append(f"{step}: {'; '.join(errs)}")
            else:
                errors.append(f"{step}: 校验失败（无具体错误信息）")
    return "\n".join(errors) if errors else ""


def handle_analyzer_return(tool_output, workspace_id):
    """处理 stability-analyzer 返回。"""

    data = extract_json_from_text(tool_output, required_keys=["intent"])
    if not data or "intent" not in data:
        emit("BLOCKING：扰动分析器返回格式异常，无法提取 intent。向用户报告此问题，不要继续推进流程。")
        return

    intent = data.get("intent", "")
    action = data.get("action", "")
    sid = data.get("workspace_id", workspace_id or "default")

    # ── 全局 STATE 健康检测（在所有 intent 分支前执行）──
    # 原理：主 Agent 可能违规调用 --next/step.py，或 Task 被取消后留下僵尸状态。
    # 每次进入 analyzer 路径时，基于 ROUTER.json DAG 拓扑做全局一致性校验+修复。
    # 这不替代扰动分析器的意图分类，而是确保引擎状态在处理用户意图前是合法的。
    _inv_state_path = resolve_ws_state(sid)
    if os.path.exists(_inv_state_path):
        _hc_result = run_script([
            "engine/scripts/state_health_check.py",
            "--workspace-id", sid,
            "--fix"
        ])
        if _hc_result and not _hc_result.get("_error"):
            _summary = _hc_result.get("summary", {})
            _fixes = _hc_result.get("fix_actions", [])
            if _summary.get("critical", 0) > 0 or _summary.get("major", 0) > 0:
                _hook2_log(f"HEALTH_CHECK: status={_hc_result.get('status')} fixes={_fixes}")
            elif _fixes:
                _hook2_log(f"HEALTH_CHECK: minor fixes applied: {_fixes}")
        else:
            _err = _hc_result.get("_error", "unknown") if _hc_result else "no result"
            _hook2_log(f"HEALTH_CHECK: failed - {_err}")

    # ── 1. chitchat ──
    if intent == "chitchat":
        emit("正常回应用户的消息，不调用任何引擎脚本，不发起任何 Task。")
        return

    # ── 2. task_control ──
    if intent == "task_control":
        app_path = resolve_app_path(sid)
        state_path = resolve_ws_state(sid)

        # STATE.json 不存在时自动走 init 路径
        if not os.path.exists(state_path):
            workspace_path = data.get("workspace_path", "") or default_workspace_path(app_path, sid)
            init_result = run_script(["engine/scripts/init.py",
                        "--workspace-path", workspace_path,
                        "--workspace-id", sid,
                        "--app-path", app_path,
                        "--force", "--skip-compile", "--skip-dep-check"])
            if init_result.get("_error"):
                emit(f"BLOCKING：init.py 执行失败 — {init_result['_error']}")
                return
            if init_result.get("status") == "failure":
                emit(f"BLOCKING：初始化失败 — {init_result.get('error_code', '?')}: {init_result.get('message', '?')}")
                return

        if action in ("rework", "reset", "jump"):
            target_step = data.get("target_step", "")
            fix_args = ["engine/scripts/fix.py", "--type", action,
                        "--workspace-id", sid]
            if action == "jump" and target_step:
                fix_args += ["--step", target_step]
            fix_result = run_script(fix_args)
            if fix_result.get("_error"):
                emit(f"BLOCKING：fix.py 执行失败 — {fix_result['_error']}")
                return

        # 读取 analyzer 返回的 user_decision（语义判断由 analyzer 完成，Hook 不推断）
        user_decision = data.get("user_decision", "")

        # 提取用户反馈（拒绝时的修改建议）→ 写入文件载体
        user_feedback = data.get("feedback", "")

        if user_decision in ("confirmed", "fail"):
            # v4.0: 只扫描主线 step_status（无并行分支）
            state = load_json_file(state_path) or {}
            decisions = []
            for s, info in state.get("step_status", {}).items():
                if info.get("status") == "awaiting_confirmation":
                    decisions.append({"step": s, "decision": user_decision})
            # fail 时把用户反馈写入固定文件载体
            if user_decision == "fail" and user_feedback and decisions:
                ws_base = os.path.dirname(state_path)
                ws_root = ws_base
                wr_file = os.path.join(ws_base, "WORKSPACE_ROOT")
                if os.path.exists(wr_file):
                    with open(wr_file, "r", encoding="utf-8-sig") as f:
                        ws_root = f.read().strip()
                for d in decisions:
                    fb_file = os.path.join(ws_root, "outputs", f"{d['step']}-feedback.json")
                    os.makedirs(os.path.dirname(fb_file), exist_ok=True)
                    with open(fb_file, "w", encoding="utf-8") as f:
                        json.dump({"step": d["step"], "feedback": user_feedback},
                                  f, ensure_ascii=False, indent=2)
            if decisions:
                decide_result = run_script(["engine/scripts/step.py", "--decide",
                           "--decisions", json.dumps(decisions, ensure_ascii=False),
                           "--workspace-id", sid])
                if decide_result.get("_error"):
                    emit(f"BLOCKING：step.py --decide 执行失败 — {decide_result['_error']}")
                    return

        step_result = run_script(["engine/scripts/step.py", "--next", "--workspace-id", sid])
        if step_result.get("_error"):
            emit(f"BLOCKING：step.py --next 执行失败 — {step_result['_error']}")
            return
        injection = format_directive(step_result)
        if injection:
            emit(injection)
        else:
            emit(f"BLOCKING：引擎返回空指令（task_control 路径）。step.py 结果：{json.dumps(step_result, ensure_ascii=False)[:300]}")
        return

    # ── 3. switch_app ──
    if intent == "switch_app":
        target_app = data.get("target_app", "")
        ws_id = data.get("workspace_id", sid or "default")
        target_state = resolve_ws_state(ws_id)
        if os.path.exists(target_state):
            # 已有运行数据 → 检查 terminal_state，决定 switch 还是 force reinit
            existing_state = load_json_file(target_state) or {}
            terminal = existing_state.get("terminal_state")
            if terminal == "completed":
                # 已终态 → 需要 force reinit（switch.py 不重置 STATE）
                workspace_path = data.get("workspace_path", "") or default_workspace_path(target_app, ws_id)
                init_result = run_script(["engine/scripts/init.py",
                            "--workspace-path", workspace_path,
                            "--workspace-id", ws_id,
                            "--app-path", target_app,
                            "--force", "--skip-compile", "--skip-dep-check"])
                if init_result.get("_error"):
                    emit(f"BLOCKING：init.py 执行失败（terminal reinit） — {init_result['_error']}")
                    return
                if init_result.get("status") == "failure":
                    emit(f"BLOCKING：初始化失败 — {init_result.get('error_code', '?')}: {init_result.get('message', '?')}")
                    return
            else:
                # 非终态 → switch 更新 APP_REF
                switch_result = run_script(["engine/scripts/switch.py", "--workspace-id", ws_id, "--app-path", target_app])
                if switch_result.get("_error"):
                    emit(f"BLOCKING：switch.py 执行失败 — {switch_result['_error']}")
                    return
        else:
            # 首次 init → 默认使用 Z_工作区/{ws_id}
            workspace_path = data.get("workspace_path", "") or default_workspace_path(target_app, ws_id)
            init_result = run_script(["engine/scripts/init.py",
                        "--workspace-path", workspace_path,
                        "--workspace-id", ws_id,
                        "--app-path", target_app,
                        "--force", "--skip-compile", "--skip-dep-check"])
            if init_result.get("_error"):
                emit(f"BLOCKING：init.py 执行失败 — {init_result['_error']}")
                return
            if init_result.get("status") == "failure":
                emit(f"BLOCKING：初始化失败 — {init_result.get('error_code', '?')}: {init_result.get('message', '?')}")
                return

        step_result = run_script(["engine/scripts/step.py", "--next", "--workspace-id", ws_id])
        if step_result.get("_error"):
            emit(f"BLOCKING：step.py --next 执行失败 — {step_result['_error']}")
            return
        injection = format_directive(step_result)
        if injection:
            emit(injection)
        else:
            emit(f"BLOCKING：引擎返回空指令。step.py --next 结果：{json.dumps(step_result, ensure_ascii=False)[:300]}")
        return

    # ── 4. blocking ──
    if intent == "blocking":
        reason = data.get("reason", "")
        emit(f"向用户澄清意图：{reason}")
        return

    # 未匹配任何 intent，报错而非静默
    emit(f"BLOCKING：扰动分析器返回了未知的 intent='{intent}'，原始数据：{json.dumps(data, ensure_ascii=False)[:300]}")


def _collect_all_gate_errors(results):
    """从多个 submit_result 中合并所有 Gate FAIL 错误详情。"""
    all_errors = []
    for r in results:
        errs = format_gate_errors(r)
        if errs:
            all_errors.append(errs)
    return "\n".join(all_errors) if all_errors else ""


def _hook2_log(msg):
    """Hook② role-executor 路径专用日志。"""
    try:
        import datetime
        log_path = os.path.join(os.path.dirname(__file__), "_hook2_role.log")
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"[{datetime.datetime.now()}] {msg}\n")
    except Exception:
        pass


def handle_role_executor_return(tool_output, workspace_id):
    """处理 role-executor 返回。

    v4.1: pbc 从 step_status 实时派生（len(step_status)），不再使用独立计数器。
    核心原则：step_status 非空时禁止向主 Agent 注入任何信号（仍有分支在执行）。
    所有分支的 submit_next 和 gate_results 缓存到 STATE.json 的 cached_branch_results，
    step_status 为空时统一读取全部缓存，按优先级全局决策后注入。
    """

    def _derive_pbc(sid):
        """v4.1: pbc 从 step_status 派生，不再使用独立计数器。
        消除多源冲突：step_status 是 set_state.py 唯一写者维护的权威源。
        rollback 删除 step_status 条目时，pbc 自然递减，无需手动清零。
        """
        try:
            sp = resolve_ws_state(sid)
            st = load_json_file(sp) or {}
            return len(st.get("step_status", {}))
        except Exception:
            return 0

    data = extract_json_from_text(tool_output, required_keys=["status"])
    sid_fallback = workspace_id or "default"
    if not data:
        emit("BLOCKING：role-executor 返回格式异常，无法解析为 JSON。向用户报告此问题，不要继续推进流程。")
        return

    status = data.get("status", "")
    sid = data.get("workspace_id", sid_fallback)
    branch_id = data.get("branch_id", None)
    outputs = data.get("outputs", [])
    role_verdict = data.get("verdict", "")  # 从 role-executor 返回值读 verdict
    step = data.get("step", "")

    # ── 状态检查（非 confirmed 状态直接报告，不缓存）──
    if status == "BLOCKING":
        emit(f"BLOCKING：role-executor 返回 BLOCKING。向用户报告以下信息：\n{json.dumps(data, ensure_ascii=False)[:500]}")
        return
    if status != "confirmed":
        emit(f"BLOCKING：role-executor 返回异常状态 '{status}'，向用户报告此问题。")
        return

    # ── 调 step.py --submit ──
    _hook2_log(f"SUBMIT: step={step} verdict={role_verdict} outputs={json.dumps(outputs, ensure_ascii=False)[:200]}")
    submit_args = [
        "engine/scripts/step.py", "--submit",
        "--step", step,
        "--outputs", json.dumps(outputs, ensure_ascii=False),
        "--workspace-id", sid,
    ]
    if role_verdict:
        submit_args += ["--verdict", role_verdict]
    submit_result = run_script(submit_args)
    submit_next = submit_result.get("next", "")
    _hook2_log(f"SUBMIT_RESULT: next={submit_next} action={submit_result.get('action','')} gate_results={json.dumps(submit_result.get('gate_results',[]), ensure_ascii=False)[:200]}")

    # submit 失败时直接报错（pbc 从 step_status 派生，无需手动递减）
    if submit_result.get("action") == "error" or submit_result.get("status") == "error":
        _err = submit_result.get("error", "submit 失败")
        emit(f"BLOCKING：引擎错误 — {_err}")
        return

    # ── pbc 门控（从 step_status 派生）──
    state_path = resolve_ws_state(sid)
    state = load_json_file(state_path) or {}
    pbc = _derive_pbc(sid)  # v4.1: 从 step_status 派生
    _hook2_log(f"PBC_DERIVED: pbc={pbc} pending_dispatches={state.get('pending_dispatches')} step_status_keys={list(state.get('step_status',{}).keys())}")

    if pbc > 0:
        # ══════════════════════════════════════════════════════
        # pbc > 0：仍有并行分支在执行（step_status 非空）
        # ══════════════════════════════════════════════════════
        # 缓存当前分支结果，纯静默，等其他分支返回
        cached = state.setdefault("cached_branch_results", [])
        cached.append({
            "branch_id": branch_id,
            "step": step,
            "submit_next": submit_next,
            "gate_results": submit_result.get("gate_results", []),
            "pending": submit_result.get("pending", []),
            "failed": submit_result.get("failed", []),
            "reason": submit_result.get("reason", ""),
        })
        save_state(state_path, state)
        sys.exit(0)

    # pbc == 0：最后一个分支返回（step_status 已空），统一决策
    all_results = [submit_result]
    for c in state.get("cached_branch_results", []):
        all_results.append({
            "next": c.get("submit_next", ""),
            "gate_results": c.get("gate_results", []),
            "pending": c.get("pending", []),
            "failed": c.get("failed", []),
            "reason": c.get("reason", ""),
        })

    # 清空缓存
    state["cached_branch_results"] = []
    save_state(state_path, state)

    # ══════════════════════════════════════════════════════
    # pbc == 0：统一决策（v4.3 优先级修订）
    # 优先级：error > confirm > delegate > complete(all) > wait(all) > --next
    #
    # v4.3 变更：
    #   1. delegate 提升至 complete 和 wait 之前——JOIN 场景下先完成分支的
    #      delegate 信号（pending_dispatches 已缓存）不得被 wait 误报淹没。
    #   2. _scan_awaiting_confirmation 移除（pbc=0 时 step_status 必为空，死代码），
    #      改为从 submit/cached 结果中检测 confirm 信号。
    #   3. wait 判定从 any 改为 all——只要存在 delegate 或其他推进信号就不 BLOCKING。
    # ══════════════════════════════════════════════════════

    all_submit_nexts = [r.get("next", "") for r in all_results]
    _hook2_log(f"DECISION: all_submit_nexts={all_submit_nexts}")

    # ① error：任一分支失败 → 汇总所有 failed 详情
    if any(n == "error" for n in all_submit_nexts):
        all_failed = []
        for r in all_results:
            all_failed.extend(r.get("failed", []))
        emit(f"BLOCKING：引擎错误 — {all_failed}")
        return

    # ② confirm：任一分支返回 confirm → 展示确认请求，严禁 --next
    if any(n == "confirm" for n in all_submit_nexts):
        all_pending = []
        for r in all_results:
            all_pending.extend(r.get("pending", []))
        all_gate_errors = _collect_all_gate_errors(all_results)
        steps_desc = ", ".join(p.get("step", "?") for p in all_pending) if all_pending else "未知步骤"
        lines = [f"向用户展示确认请求：{steps_desc}。"]
        if all_gate_errors:
            lines.append(f"Gate 详情：{all_gate_errors}")
        lines.append("等待用户回复 confirmed 或 fail 后，将用户回复原样传递给 Task(stability-analyzer)。")
        emit("\n".join(lines))
        return

    # ③ delegate：任一分支返回 delegate → 有 pending_dispatches 待消费
    has_delegate = any(n == "delegate" for n in all_submit_nexts)

    # ④ complete：无 delegate 且所有分支都返回 complete
    if not has_delegate and all(n == "complete" for n in all_submit_nexts):
        emit("任务已全部完成，向用户报告结果并结束。")
        return

    # ⑤ wait：无 delegate 且所有分支都返回 wait = 引擎无可调度
    if not has_delegate and all(n == "wait" for n in all_submit_nexts):
        reasons = [r.get("reason", "等待中") for r in all_results if r.get("next") == "wait"]
        _hook2_log(f"BLOCKING_WAIT: reasons={reasons}")
        emit(f"BLOCKING：{' | '.join(reasons)}")
        return

    # ⑥ 正常推进 / delegate 推进：调 --next 获取下一步 task_prompt
    _decision = "delegate" if has_delegate else "正常"
    _hook2_log(f"CALLING_NEXT: ⑥{_decision}推进路径")
    step_result = run_script(["engine/scripts/step.py", "--next", "--workspace-id", sid])
    if step_result.get("_error"):
        emit(f"BLOCKING：step.py --next 执行失败 — {step_result['_error']}")
        return
    next_action = step_result.get("action", "")
    _hook2_log(f"NEXT_RESULT: action={next_action} next={step_result.get('next','')} has_dispatches={'dispatches' in step_result}")
    if next_action == "complete" or step_result.get("next") == "complete":
        emit("任务已全部完成，向用户报告结果并结束。")
        return
    injection = format_directive(step_result)
    if injection:
        _hook2_log(f"INJECTION: {injection[:100]}")
        emit(injection)
    else:
        _hook2_log(f"BLOCKING_EMPTY: step_result={json.dumps(step_result, ensure_ascii=False)[:300]}")
        emit(f"BLOCKING：引擎返回空指令（role-executor 路径）。step.py 结果：{json.dumps(step_result, ensure_ascii=False)[:300]}")


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except Exception:
        # stdin 解析失败 → emit 报错而非静默
        try:
            emit("BLOCKING：Hook② 无法解析 stdin 输入，Hook 可能收到非预期格式的数据。向用户报告此问题。")
        except Exception:
            # emit 自身也崩溃（极罕见）→ 写 stderr 作为最后手段
            sys.stderr.write("Hook② FATAL: emit() failed during stdin parse error\n")
        sys.exit(0)

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})
    # Qoder 的 PostToolUse 把返回值放在 tool_response（不是 tool_output）
    tool_output = data.get("tool_response", "") or data.get("tool_output", "")

    # 调试日志（写入临时文件，用于排查 Hook 输入格式问题）
    try:
        import datetime
        debug_path = os.path.join(os.path.dirname(__file__), "_hook_debug.log")
        with open(debug_path, "a", encoding="utf-8") as f:
            f.write(f"\n[{datetime.datetime.now()}] tool_name={tool_name}\n")
            f.write(f"  data keys={list(data.keys())}\n")
            f.write(f"  tool_input={json.dumps(tool_input, ensure_ascii=False)[:300]}\n")
            f.write(f"  tool_output type={type(tool_output).__name__}, len={len(str(tool_output))}\n")
            f.write(f"  tool_output={str(tool_output)[:300]}\n")
            # 检查其他可能的输出字段
            for k in data:
                if k not in ('tool_name', 'tool_input', 'tool_output'):
                    f.write(f"  extra field '{k}'={str(data[k])[:200]}\n")
    except Exception:
        pass

    # 只处理 Task/Agent
    if tool_name not in ("Task", "Agent"):
        sys.exit(0)

    # 识别 subagent 类型
    agent_type = (tool_input.get("subagent_type", "") or
                  tool_input.get("agent_type", "") or
                  tool_input.get("type", ""))
    prompt_text = tool_input.get("prompt", "")
    if not agent_type:
        if "stability-analyzer" in prompt_text:
            agent_type = "stability-analyzer"
        elif "role-executor" in prompt_text:
            agent_type = "role-executor"

    # 白名单
    if agent_type not in ("stability-analyzer", "role-executor"):
        sys.exit(0)

    # 提取 workspace_id
    workspace_id = tool_input.get("workspace_id", "")
    if not workspace_id:
        for line in prompt_text.split("\n"):
            if "workspace_id" in line:
                workspace_id = line.split("workspace_id")[-1].strip(": =").strip()
                break

    # 分发处理
    try:
        if agent_type == "stability-analyzer":
            handle_analyzer_return(tool_output, workspace_id)
        elif agent_type == "role-executor":
            handle_role_executor_return(tool_output, workspace_id)
    except Exception as e:
        # Hook② 内部错误 → 写日志 + emit 报错（不静默退出）
        import traceback
        debug_path = os.path.join(os.path.dirname(__file__), "_hook_error.log")
        try:
            with open(debug_path, "a") as f:
                f.write(f"\n[{__import__('datetime').datetime.now()}] {traceback.format_exc()}\n")
        except:
            pass
        emit(f"BLOCKING：Hook② 内部异常 — {e}\n{traceback.format_exc()[:500]}")

    sys.exit(0)


if __name__ == "__main__":
    main()
