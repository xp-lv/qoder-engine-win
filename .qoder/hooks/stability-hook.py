#!/usr/bin/env python3
"""stability-hook.py — UserPromptSubmit Hook

职责：判断用户消息是否与 app 执行相关，如果是则注入"调用扰动分析器"。
不做引擎状态操作、不读 STATE.json、不生成分支。
"""
import json, sys


# 与 app 执行无关的关键词（纯技术讨论、闲聊等）
_NON_EXECUTION_KEYWORDS = [
    "画", "mermaid", "图", "路由图", "流程图",
    "什么是", "解释", "区别", "为什么",
    "检查", "审阅", "看看", "帮我看看",
    "文档", "注释", "规范",
]


def is_execution_related(prompt):
    """判断用户消息是否与 app 执行相关。

    简单规则：
    - 包含 confirmed / pass / 继续 / 推进 / 执行 → 执行相关
    - 包含 app 名称或工作流术语 → 执行相关
    - 包含非执行关键词且不含执行关键词 → 非执行相关
    - 默认 → 执行相关（保守策略，宁可多调不可漏调）
    """
    p = prompt.lower().strip()

    # 明确的执行控制词
    exec_words = [
        "confirmed", "pass", "continue", "继续", "推进", "执行",
        "启动", "重新启动", "重跑", "fail", "reject", "拒绝",
        "confirmed", "确认", "通过", "运行",
    ]
    if any(w in p for w in exec_words):
        return True

    # app 切换意图
    if any(w in p for w in ["app-builder", "app-architect", "prose-loop", "switch", "切换", "用这个"]):
        return True

    # 明确的非执行意图（纯讨论/查看）
    if any(w in p for w in _NON_EXECUTION_KEYWORDS):
        # 但如果同时包含执行词，仍然是执行相关
        if not any(w in p for w in exec_words):
            return False

    # 默认：保守策略，调用扰动分析器
    return True


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except Exception:
        sys.exit(0)

    if not data.get("prompt"):
        sys.exit(0)

    prompt = data.get("prompt", "")

    if is_execution_related(prompt):
        result = {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": "调用扰动分析器（stability-analyzer）来处理用户消息"
            }
        }
        print(json.dumps(result, ensure_ascii=False))

    sys.exit(0)


if __name__ == "__main__":
    main()
