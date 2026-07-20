#!/usr/bin/env python3
"""doc_dup_check.py — 文档单文件内重复检测器。

检测规则：
1. 同一 markdown 文件中出现 ≥ 2 个 H1 标题
2. 同一 H1 标题重复出现（CRITICAL）
3. 多 H1 但不重复（WARNING，可能是误拼接）

Usage:
  python engine/scripts/doc_dup_check.py --app-path apps/<app_name>
  python engine/scripts/doc_dup_check.py --path /specific/file.md
  python engine/scripts/doc_dup_check.py --scan-all          # 扫描所有 apps
"""
import argparse, os, re, sys


def find_h1_duplicates(file_path):
    """检测单个文件内的 H1 重复。

    返回 dict：
      - h1s: [(line_no, title), ...]
      - dup_titles: {title: count, ...}（重复的标题）
      - severity: 'CRITICAL' | 'WARNING' | 'OK'
    """
    try:
        with open(file_path, encoding='utf-8') as f:
            lines = f.readlines()
    except Exception:
        return {'h1s': [], 'dup_titles': {}, 'severity': 'OK'}

    h1s = []
    in_code_block = False  # 跟踪 ``` 代码块状态，避免误报代码块内的 H1
    for i, line in enumerate(lines, 1):
        stripped = line.rstrip()
        # 代码块围栏切换检测
        if stripped.startswith('```'):
            in_code_block = not in_code_block
            continue
        # 在代码块内的 # 开头行不是真 H1
        if in_code_block:
            continue
        # 匹配 "# 标题"（# 后必须空格，标题首字符不能是 #）
        if re.match(r'^# [^#]', stripped):
            title = stripped[2:].strip()
            h1s.append((i, title))

    if len(h1s) <= 1:
        return {'h1s': h1s, 'dup_titles': {}, 'severity': 'OK'}

    # 统计重复标题
    title_counts = {}
    for _, title in h1s:
        title_counts[title] = title_counts.get(title, 0) + 1
    dup_titles = {t: c for t, c in title_counts.items() if c > 1}

    severity = 'CRITICAL' if dup_titles else 'WARNING'
    return {'h1s': h1s, 'dup_titles': dup_titles, 'severity': severity}


def scan_dir(root_dir):
    """扫描目录下所有 .md 文件，返回问题列表。"""
    problems = []
    for root, dirs, files in os.walk(root_dir):
        # 跳过 outputs/process 等运行时目录
        parts = os.path.relpath(root, root_dir).split(os.sep)
        if any(p in ('outputs', 'process', '__pycache__', '.git', 'node_modules') for p in parts):
            continue

        for fn in files:
            if not fn.endswith('.md'):
                continue
            fp = os.path.join(root, fn)
            result = find_h1_duplicates(fp)
            if result['severity'] == 'OK':
                continue
            problems.append({
                'file': fp,
                'rel_path': os.path.relpath(fp, root_dir),
                **result,
            })
    return problems


def print_report(problems, base_dir=''):
    """打印问题报告。"""
    if not problems:
        print('✅ 未发现单文件内 H1 重复问题')
        return 0

    critical = [p for p in problems if p['severity'] == 'CRITICAL']
    warnings = [p for p in problems if p['severity'] == 'WARNING']

    print(f'\n=== 文档单文件内 H1 重复检测报告 ===\n')
    print(f'总计: {len(critical)} 个 CRITICAL / {len(warnings)} 个 WARNING\n')

    if critical:
        print('❌ CRITICAL（同标题重复，必须修复）:')
        for p in critical:
            display_path = os.path.relpath(p['file'], base_dir) if base_dir else p['file']
            print(f'  {display_path}')
            for line_no, title in p['h1s']:
                marker = ' [重复]' if title in p['dup_titles'] else ''
                print(f'    L{line_no}: {title}{marker}')
        print()

    if warnings:
        print('⚠️  WARNING（多 H1 不重复，可能合理也可能拼接）:')
        for p in warnings:
            display_path = os.path.relpath(p['file'], base_dir) if base_dir else p['file']
            print(f'  {display_path}')
            for line_no, title in p['h1s'][:5]:
                print(f'    L{line_no}: {title}')
            if len(p['h1s']) > 5:
                print(f'    ... 共 {len(p["h1s"])} 个 H1')
        print()

    return 1 if critical else 0


def main():
    parser = argparse.ArgumentParser(description='文档单文件内 H1 重复检测器')
    g = parser.add_mutually_exclusive_group(required=True)
    g.add_argument('--app-path', help='应用包路径（如 apps/pure-arch-design）')
    g.add_argument('--path', help='单个文件路径')
    g.add_argument('--scan-all', action='store_true', help='扫描所有 apps/')
    parser.add_argument('--strict', action='store_true', help='严格模式：WARNING 也算失败')
    args = parser.parse_args()

    if args.path:
        if not os.path.exists(args.path):
            print(f'❌ 文件不存在: {args.path}')
            sys.exit(2)
        result = find_h1_duplicates(args.path)
        problems = [{'file': args.path, 'rel_path': os.path.basename(args.path), **result}] if result['severity'] != 'OK' else []
        base_dir = os.path.dirname(args.path)
    elif args.app_path:
        if not os.path.isdir(args.app_path):
            print(f'❌ 目录不存在: {args.app_path}')
            sys.exit(2)
        problems = scan_dir(args.app_path)
        base_dir = args.app_path
    else:  # scan-all
        # 扫描 workspace 根下的 apps/
        apps_dir = os.path.join(os.getcwd(), 'apps')
        if not os.path.isdir(apps_dir):
            print(f'❌ apps/ 目录不存在')
            sys.exit(2)
        problems = []
        for app_name in sorted(os.listdir(apps_dir)):
            app_path = os.path.join(apps_dir, app_name)
            if not os.path.isdir(app_path):
                continue
            sub_problems = scan_dir(app_path)
            for p in sub_problems:
                p['rel_path'] = f'{app_name}/{p["rel_path"]}'
            problems.extend(sub_problems)
        base_dir = apps_dir

    exit_code = print_report(problems, base_dir)
    if args.strict:
        # 严格模式下，WARNING 也算失败
        warnings_list = [p for p in problems if p['severity'] == 'WARNING']
        if warnings_list:
            exit_code = 1
    sys.exit(exit_code)


if __name__ == '__main__':
    main()
