#!/usr/bin/env python3
"""mac2win.py — 将 mac-repo-clone 的引擎脚本迁移到 Windows 主工作区。

迁移策略：
  1. 用 mac-repo-clone 版本覆盖主工作区对应文件（取最新架构）
  2. 自动应用 5 条 Windows 适配规则（纯机械替换，不改逻辑）
  3. 同步 .qoder/hooks（同样适配）

Windows 适配规则：
  R1: "python3" → sys.executable（Windows 无 python3 命令）
  R2: open(path, "r", encoding="utf-8") → encoding="utf-8-sig"（跳过 BOM）
  R3: subprocess.run() 无 encoding= 的 → 补 encoding/errors/env（防 GBK 乱码）
  R4: hook 脚本的 sys.stdin.read() 前插入 stdin UTF-8 重配置（防 stdin GBK）
  R5: hook 脚本的 print()/sys.stdout 输出 → 补 stdout UTF-8 重配置（防 print GBK 崩溃）
  R7: open(..., "w") 无 encoding → 补 encoding="utf-8"（防写 GBK）
  R8: open(..., "r") 无 encoding → 补 encoding="utf-8"（防读 GBK）

Usage:
  python process/mac2win.py --dry-run    # 预览变更
  python process/mac2win.py --apply      # 实际执行迁移
"""
import os, re, sys, shutil

WORKSPACE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

MIGRATION_MAP = {
    "engine/scripts": "mac-repo-clone/engine/scripts",
    ".qoder/hooks": "mac-repo-clone/.qoder/hooks",
    ".qoder/settings.json": "mac-repo-clone/.qoder/settings.json",
}

# 不迁移的文件（平台专属 / 环境差异 / 运行时日志）
SKIP_FILES = {
    "stability-hook.sh",
    "__pycache__",
    "_hook2_role.log",
    "_hook_debug.log",
    "_hook_error.log",
    # agents/*.md 不迁移：模型 ID 是环境差异，非平台适配
    "role-executor.md",
    "stability-analyzer.md",
}


def apply_r1_python3(content):
    """R1: "python3" → sys.executable"""
    changes = 0
    if '"python3"' in content:
        content = content.replace('"python3"', 'sys.executable')
        changes += 1
    return content, changes


def apply_r2_bom(content):
    """R2: 读模式的 encoding="utf-8" → encoding="utf-8-sig" """
    changes = 0
    def replacer(m):
        nonlocal changes
        changes += 1
        return m.group(1) + '"utf-8-sig"'
    content = re.sub(
        r'(open\([^)]*"r"[^)]*encoding=)"utf-8"',
        replacer,
        content,
    )
    return content, changes


def apply_r8_read_encoding(content):
    """R8: 读模式的 open() 无 encoding → 补 encoding="utf-8-sig"

    Mac 上 open(f) 默认 UTF-8，Windows 上默认 GBK。
    对所有读模式 open() 调用且无 encoding= 的补 encoding="utf-8-sig"。
    必须在 R2 之后执行（R2 先把已有的 utf-8 改成 utf-8-sig）。
    """
    changes = 0
    lines = content.split("\n")
    result = []
    for line in lines:
        if 'open(' in line and 'encoding=' not in line:
            # Case 1: open(f, "r") → open(f, "r", encoding="utf-8-sig")
            if '"r"' in line:
                new_line = line.replace('"r"', '"r", encoding="utf-8-sig"', 1)
                if new_line != line:
                    changes += 1
                    result.append(new_line)
                    continue
            # Case 2: open(single_var) 无 mode 参数 → open(var, "r", encoding="utf-8-sig")
            m = re.search(r'open\(\s*(\w+)\s*\)', line)
            if m and '"w"' not in line and '"a"' not in line:
                new_line = line.replace(
                    m.group(0),
                    f'open({m.group(1)}, "r", encoding="utf-8-sig")',
                    1,
                )
                if new_line != line:
                    changes += 1
                    result.append(new_line)
                    continue
        result.append(line)
    return "\n".join(result), changes


def apply_r7_write_encoding(content):
    """R7: 写/追加模式的 open(f, "w"/"a") 无 encoding → 补 encoding="utf-8"

    Mac 上 open(f, "w") 默认 UTF-8，Windows 上默认 GBK。
    对所有写/追加模式 open() 调用补 encoding="utf-8"。
    """
    changes = 0
    lines = content.split("\n")
    result = []
    for line in lines:
        if 'open(' in line and 'encoding=' not in line:
            for mode in ('"w"', '"a"'):
                if mode in line:
                    new_line = line.replace(mode, f'{mode}, encoding="utf-8"', 1)
                    if new_line != line:
                        changes += 1
                        result.append(new_line)
                        break
            else:
                result.append(line)
            continue
        result.append(line)
    return "\n".join(result), changes


def apply_r3_subprocess_encoding(content):
    """R3: 所有无 encoding= 的 subprocess.run() → 补 encoding/errors/env

    匹配策略：逐行扫描，跟踪括号深度，提取完整的 subprocess.run(...) 调用。
    不依赖 timeout=\d+ 这种脆弱的模式匹配。
    """
    lines = content.split("\n")
    result_lines = []
    changes = 0

    i = 0
    while i < len(lines):
        line = lines[i]

        if "subprocess.run(" in line:
            # 向后收集完整的调用（跨行）
            call_lines = [line]
            paren_depth = line.count("(") - line.count(")")
            j = i + 1
            while paren_depth > 0 and j < len(lines):
                call_lines.append(lines[j])
                paren_depth += lines[j].count("(") - lines[j].count(")")
                j += 1

            call_text = "\n".join(call_lines)

            if "encoding=" not in call_text:
                # 找到闭合括号所在的行和位置
                last_line_idx = len(call_lines) - 1
                last_line = call_lines[last_line_idx]

                # 在最后一个 ")" 前插入参数
                close_paren_pos = last_line.rfind(")")
                before_paren = last_line[:close_paren_pos].rstrip()
                indent = " " * (len(last_line) - len(last_line.lstrip()))

                # 构造插入文本
                has_env = "env=" in call_text
                if has_env:
                    params = 'encoding="utf-8", errors="replace"'
                else:
                    params = 'encoding="utf-8", errors="replace", env={**os.environ, "PYTHONIOENCODING": "utf-8"}'

                # 判断闭合括号所在行的内容
                if before_paren.strip() == "":
                    # 闭合括号在独立行，如:
                    #     timeout=30,
                    # )
                    # 在前一行的逗号后追加参数行
                    if last_line_idx > 0:
                        prev = call_lines[last_line_idx - 1].rstrip()
                        if prev.endswith(","):
                            call_lines[last_line_idx - 1] = prev + " " + params
                        else:
                            call_lines[last_line_idx - 1] = prev + ", " + params
                elif before_paren.endswith(","):
                    call_lines[last_line_idx] = before_paren + " " + params + last_line[close_paren_pos:]
                elif before_paren.rstrip().endswith("("):
                    call_lines[last_line_idx] = before_paren + params + last_line[close_paren_pos:]
                else:
                    call_lines[last_line_idx] = before_paren + ", " + params + last_line[close_paren_pos:]

                changes += 1
                result_lines.extend(call_lines)
                i = j
                continue
            else:
                result_lines.extend(call_lines)
                i = j
                continue

        result_lines.append(line)
        i += 1

    return "\n".join(result_lines), changes


def apply_r4_stdin_utf8(content):
    """R4: 在 sys.stdin.read() 前插入 stdin UTF-8 重配置。

    只对含 sys.stdin.read() 的 hook 脚本生效。
    插入位置：def main() 函数体的第一行之前。
    """
    if "sys.stdin.read()" not in content:
        return content, 0

    # 检查是否已有 stdin 重配置
    if "sys.stdin.buffer" in content and "TextIOWrapper" in content:
        return content, 0

    # 在 "raw = sys.stdin.read()" 前插入
    target = "        raw = sys.stdin.read()"
    replacement = (
        '        # Windows: 重配置 stdin/stdout 为 UTF-8（防止 GBK 编码崩溃）\n'
        '        try:\n'
        '            import io\n'
        '            sys.stdin = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace")\n'
        '            sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")\n'
        '        except Exception:\n'
        '            pass\n'
        '        raw = sys.stdin.read()'
    )

    if target in content:
        content = content.replace(target, replacement, 1)
        return content, 1

    return content, 0


def apply_r5_stdout_utf8(content):
    """R5: 对含 print() 输出 JSON 的 hook 脚本，在文件头部加 stdout 重配置。

    R4 已覆盖 main() 函数内的 stdin+stdout 重配置。
    此规则处理 main() 外部的 print（如模块级 emit 函数）。
    """
    # 如果 R4 已处理 stdout，跳过
    if "sys.stdout.buffer" in content and "TextIOWrapper" in content:
        return content, 0

    # 只对 hook 脚本中的 emit/print 函数生效
    if 'print(output)' not in content and 'print(json.dumps' not in content:
        return content, 0

    # 在 import 部分之后插入全局 stdout 重配置
    # 找到第一个 def 或 class 定义，并跳过其上方的装饰器行
    lines = content.split("\n")
    insert_point = None
    for i, line in enumerate(lines):
        if line.startswith("def ") or line.startswith("class "):
            insert_point = i
            break

    if insert_point is None:
        return content, 0

    # 向上跳过紧邻的装饰器行（以 @ 开头），确保插入点在装饰器块之前
    # 避免将插入块放在 @decorator 与 def/class 之间（会破坏装饰器语法）
    while insert_point > 0 and lines[insert_point - 1].lstrip().startswith("@"):
        insert_point -= 1

    # lines 已在上面赋值
    insertion = (
        '# Windows: 全局 stdout UTF-8（防止 print 中文时 GBK 崩溃）\n'
        'try:\n'
        '    sys.stdout.reconfigure(encoding="utf-8", errors="replace")\n'
        'except Exception:\n'
        '    pass\n'
        '\n'
    )
    lines.insert(insert_point, insertion)
    return "\n".join(lines), 1


def apply_r6_json_python3(content):
    """R6: JSON 配置文件中的 python3 → python

    settings.json 中的 hook 命令行用的是 shell 命令，
    Windows 上用 `python`（不是 python3，也不能用 sys.executable）。
    """
    if 'python3' not in content:
        return content, 0
    content = content.replace('python3 ', 'python ')
    return content, 1


def apply_win_adaptations(content, filepath):
    """对文件内容应用全部 Windows 适配规则。"""
    all_changes = []

    content, n = apply_r1_python3(content)
    if n > 0:
        all_changes.append(f"R1: python3→sys.executable ({n})")

    content, n = apply_r2_bom(content)
    if n > 0:
        all_changes.append(f"R2: utf-8→utf-8-sig ({n})")

    content, n = apply_r7_write_encoding(content)
    if n > 0:
        all_changes.append(f"R7: write encoding ({n})")

    content, n = apply_r8_read_encoding(content)
    if n > 0:
        all_changes.append(f"R8: read encoding ({n})")

    content, n = apply_r3_subprocess_encoding(content)
    if n > 0:
        all_changes.append(f"R3: subprocess encoding ({n})")

    content, n = apply_r4_stdin_utf8(content)
    if n > 0:
        all_changes.append("R4: stdin UTF-8")

    content, n = apply_r5_stdout_utf8(content)
    if n > 0:
        all_changes.append("R5: stdout UTF-8")

    content, n = apply_r6_json_python3(content)
    if n > 0:
        all_changes.append("R6: json python3→python")

    return content, len(all_changes), all_changes


def migrate(dry_run=True):
    stats = {"copied": [], "adapted": [], "skipped": [], "errors": []}

    for dest_subdir, src_subdir in MIGRATION_MAP.items():
        dest_full = os.path.join(WORKSPACE, dest_subdir)
        src_full = os.path.join(WORKSPACE, src_subdir)

        # 支持单文件映射（如 .qoder/settings.json）
        if os.path.isfile(src_full):
            src_files = [(os.path.basename(src_full), src_full)]
            dest_dir = os.path.dirname(dest_full)
        else:
            if not os.path.isdir(src_full):
                stats["errors"].append(f"源不存在: {src_full}")
                continue
            dest_dir = dest_full
            src_files = [(fn, os.path.join(src_full, fn)) for fn in sorted(os.listdir(src_full))]

        if not os.path.isdir(dest_dir):
            os.makedirs(dest_dir, exist_ok=True)

        for fn, src_path in src_files:
            if fn in SKIP_FILES or fn.startswith("."):
                stats["skipped"].append(fn)
                continue

            dest_path = os.path.join(dest_dir, fn)

            if not os.path.isfile(src_path):
                continue

            # .py 和 .json 都做适配，其他直接复制
            if fn.endswith(".py") or fn.endswith(".json"):
                with open(src_path, "r", encoding="utf-8-sig") as f:
                    content = f.read()

                adapted, n_changes, change_list = apply_win_adaptations(content, src_path)

                if dry_run:
                    if content != adapted:
                        stats["adapted"].append((fn, change_list))
                    else:
                        stats["copied"].append(fn)
                else:
                    with open(dest_path, "w", encoding="utf-8") as f:
                        f.write(adapted)
                    if n_changes > 0:
                        stats["adapted"].append((fn, change_list))
                    else:
                        stats["copied"].append(fn)
            else:
                if dry_run:
                    stats["copied"].append(fn)
                else:
                    shutil.copy2(src_path, dest_path)
                    stats["copied"].append(fn)

    return stats


def main():
    dry_run = "--apply" not in sys.argv

    if dry_run:
        print("=== DRY RUN 模式（预览，不实际修改文件）===\n")
    else:
        print("=== APPLY 模式（实际执行迁移）===\n")

    stats = migrate(dry_run)

    print(f"复制（无适配）: {len(stats['copied'])} 个文件")
    for f in stats["copied"]:
        print(f"  OK  {f}")

    print(f"\n复制 + Windows 适配: {len(stats['adapted'])} 个文件")
    for f, changes in stats["adapted"]:
        change_str = ", ".join(changes)
        print(f"  ADAPT  {f} ({change_str})")

    print(f"\n跳过: {len(stats['skipped'])} 个文件")
    for f in stats["skipped"]:
        print(f"  SKIP  {f}")

    if stats["errors"]:
        print(f"\n错误: {len(stats['errors'])}")
        for e in stats["errors"]:
            print(f"  ERR  {e}")

    total = len(stats["copied"]) + len(stats["adapted"])
    print(f"\n总计: {total} 个文件迁移，{len(stats['adapted'])} 个需要 Windows 适配")

    if dry_run:
        print("\n如需实际执行: python process/mac2win.py --apply")


if __name__ == "__main__":
    main()
