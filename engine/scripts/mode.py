#!/usr/bin/env python3
"""mode.py - 切换系统运行模式（跨平台，支持 --session-id）

用法：
  python engine/scripts/mode.py [选项] [模式]

选项：
  --session-id <id>   指定 Session ID（默认 "default"）

模式：
  production    工作模式（Hook 拦截 + 规则驱动）
  development   开发模式（Hook 旁路 + 自由操作）
  orchestration 编排模式（Hook 注入编排知识）
  prod          production 简写
  dev           development 简写
  orch          orchestration 简写
  toggle        切换到下一个模式

无参数时显示当前模式。
"""
import argparse, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_path import resolve_mode_path, resolve_app_path

MODE_ORDER = ["production", "development", "orchestration"]
SHORT_MAP = {"dev": "development", "prod": "production", "orch": "orchestration"}


def get_mode_file(session_id):
    app_path = resolve_app_path(session_id)
    mode_file = resolve_mode_path(session_id, app_path)
    # 确保 session-scoped MODE 目录存在
    mode_dir = os.path.dirname(mode_file)
    if mode_dir:
        os.makedirs(mode_dir, exist_ok=True)
    return mode_file


def show_mode(session_id, current):
    print(f"当前模式: {current} (session: {session_id})")
    if current == "development":
        print("  Hook: 已旁路（不注入系统提示）")
        print("  规则: 走「未收到系统提示」分支")
        print("  适用: 调试/开发系统本身")
    elif current == "orchestration":
        print("  Hook: 注入编排能力知识（状态摘要 + 脚本接口 + 能力清单）")
        print("  规则: 走「未收到系统提示」分支（注入的是 [编排模式] 而非 [系统提示]）")
        print("  适用: 灵活编排，AI 手动驱动编排流程")
    else:
        print("  Hook: 正常运行（拦截 + 扰动分析 + 注入）")
        print("  规则: stability-layer.mdc 完整生效")
        print("  适用: 正式运行多角色编排任务")
    print("")
    print(f"切换: python engine/scripts/mode.py --session-id {session_id} [prod|dev|orch|toggle]")


def switch_mode(session_id, target, current):
    print(f"模式已切换: {current} → {target} (session: {session_id})")
    print("")
    if target == "development":
        print("  开发模式已激活")
        print("  Hook 将直接放行，不再注入系统提示")
        print("  你可以自由调试脚本、修改配置，不受状态机约束")
    elif target == "orchestration":
        print("  编排模式已激活")
        print("  Hook 将注入编排能力知识（状态摘要 + 脚本接口 + 能力清单）")
        print("  AI 知道系统的全部编排能力，可手动驱动编排流程")
    else:
        print("  工作模式已激活")
        print("  Hook 恢复正常运行")
        print("  用户消息将被拦截 → 扰动分析 → 注入系统提示")


def main():
    parser = argparse.ArgumentParser(description="切换系统运行模式")
    parser.add_argument("--session-id", default="default", help="Session ID")
    parser.add_argument("mode", nargs="?", default="", help="目标模式")
    args = parser.parse_args()

    mode_file = get_mode_file(args.session_id)

    # 如果 MODE 文件不存在，默认为 production
    if not os.path.exists(mode_file):
        with open(mode_file, "w", encoding="utf-8") as f:
            f.write("production\n")

    with open(mode_file, "r", encoding="utf-8-sig") as f:
        current = f.read().strip()

    target = args.mode.strip()

    # 无模式参数：显示当前模式
    if not target:
        show_mode(args.session_id, current)
        sys.exit(0)

    # 处理简写和 toggle
    if target in SHORT_MAP:
        target = SHORT_MAP[target]
    elif target == "toggle":
        idx = MODE_ORDER.index(current) if current in MODE_ORDER else 0
        target = MODE_ORDER[(idx + 1) % len(MODE_ORDER)]
    elif target not in MODE_ORDER:
        print(f"错误: 未知模式 '{target}'")
        print("可用: production | development | orchestration | dev | prod | orch | toggle")
        sys.exit(1)

    # 已经是目标模式
    if target == current:
        print(f"已经在 {target} 模式，无需切换 (session: {args.session_id})")
        sys.exit(0)

    # 写入新模式
    with open(mode_file, "w", encoding="utf-8") as f:
        f.write(target + "\n")

    switch_mode(args.session_id, target, current)


if __name__ == "__main__":
    main()
