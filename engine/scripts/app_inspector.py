#!/usr/bin/env python3
"""
app_inspector.py — APP 信息流转全景图

核心目的：查看 role 信息流转方向、检测死链、理解 app 执行路径

布局：
  - 角色按 DAG 拓扑分层排列（流转方向自上而下）
  - knowledge / workspace / external 各以文件树形式展示在侧栏
  - 悬停角色时：input/knowledge 绿色注入动画，output 红色产出动画，其余变暗

用法:
  python3 app_inspector.py <app.yaml> [--open]
"""

import sys, os, re, json, html, subprocess
from pathlib import Path
from collections import defaultdict, deque

try:
    import yaml
except ImportError:
    print("需要 PyYAML: pip install pyyaml"); sys.exit(1)

# ════════════════════════════════════════════════════════════
#  解析层
# ════════════════════════════════════════════════════════════

def _cat(path):
    p = path.lower()
    if p.startswith('knowledge/'): return 'knowledge'
    if p.startswith(('outputs/', 'process/', 'roles/')): return 'workspace'
    return 'external'


class AppModel:
    def __init__(self):
        self.app_name = ""
        self.knowledge = []
        self.roles = {}
        self.role_order = []
        self.edges = []
        self.entry_role = None
        self.terminal_roles = set()
        self.app_dir = None

    def get_role_verdicts(self, name):
        v = set()
        for e in self.edges:
            if len(e['sources']) == 1 and e['sources'][0] == name and e['verdict']:
                v.add(e['verdict'])
        return sorted(v)

    def get_kn_for_role(self, name):
        return [kn for kn in self.knowledge if name in kn['inject_to']]

    def get_all_files(self):
        files = {}
        for rn in self.role_order:
            role = self.roles[rn]
            for o in role['outputs']:
                p = o['path']
                if p not in files:
                    files[p] = {'name': o['name'], 'path': p, 'cat': _cat(p), 'producers': [], 'consumers': []}
                if rn not in files[p]['producers']:
                    files[p]['producers'].append(rn)
            for i in role['inputs']:
                p = i['path']
                if p not in files:
                    files[p] = {'name': i['name'], 'path': p, 'cat': _cat(p), 'producers': [], 'consumers': []}
                if rn not in files[p]['consumers']:
                    files[p]['consumers'].append(rn)
        for kn in self.knowledge:
            p = kn['path']
            if p and p not in files:
                files[p] = {'name': kn['name'], 'path': p, 'cat': 'knowledge', 'producers': [], 'consumers': []}
            if p:
                for rn in kn['inject_to']:
                    if rn not in files[p]['consumers']:
                        files[p]['consumers'].append(rn)
        return files

    def topological_layers(self):
        """将角色按 DAG 拓扑排序，返回分层列表"""
        # 构建邻接表（只取 role→role 边）
        adj = defaultdict(list)   # role -> [downstream roles]
        in_deg = defaultdict(int)
        for rn in self.role_order:
            in_deg[rn] = 0

        for e in self.edges:
            for src in e['sources']:
                for tgt in e['targets']:
                    if tgt != '\u5b8c\u6210' and tgt in self.roles and src in self.roles:
                        adj[src].append(tgt)
                        in_deg[tgt] += 1

        # Kahn's algorithm with layering
        layers = []
        remaining = set(self.role_order)

        while remaining:
            # 当前层：入度为 0 的节点
            current = sorted([r for r in remaining if in_deg[r] == 0],
                             key=lambda r: self.role_order.index(r))
            if not current:
                # 环检测：取剩余中序号最小的
                current = [min(remaining, key=lambda r: self.role_order.index(r))]

            layers.append(current)
            for rn in current:
                remaining.discard(rn)
                for downstream in adj[rn]:
                    if downstream in remaining:
                        in_deg[downstream] -= 1

        return layers


class AppYamlParser:
    ARROW = '\u2192'

    def __init__(self, yaml_path):
        self.yaml_path = Path(yaml_path).resolve()
        self.app_dir = self.yaml_path.parent

    def parse(self):
        raw = self.yaml_path.read_text(encoding='utf-8')
        edges_text, yaml_text = self._split_edges(raw)
        data = yaml.safe_load(yaml_text)
        m = AppModel()
        m.app_name = data.get('app_name', self.app_dir.name)
        m.app_dir = self.app_dir
        m.knowledge = self._parse_kn(data.get('knowledge', []))
        m.roles, m.role_order = self._parse_roles(data.get('roles', {}))
        m.edges = self._parse_edges_text(edges_text)
        m.entry_role = m.role_order[0] if m.role_order else None
        m.terminal_roles = self._infer_terminals(m)
        return m

    def _split_edges(self, text):
        lines = text.split('\n'); el = []; yl = []; in_e = False
        for line in lines:
            s = line.lstrip()
            if s == 'edges:' or s.startswith('edges:'):
                in_e = True; yl.append(line); yl.append('    __ep__: []'); continue
            if in_e and (s == '' or line[0] in ' \t'):
                el.append(line)
            else:
                in_e = False; yl.append(line)
        return '\n'.join(el), '\n'.join(yl)

    def _parse_edges_text(self, text):
        edges = []; cur = None
        for line in text.split('\n'):
            s = line.strip()
            if not s or s.startswith('#'): continue
            if s.startswith('- '):
                if cur: edges.append(cur)
                cur = {'sources': [], 'target': '', 'targets': [], 'verdict': None,
                       'carries': [], 'max_executions': None, 'restrict_verdict': None, 'raw': ''}
                self._parse_edge_def(cur, s[2:].strip())
            elif cur:
                self._parse_edge_attr(cur, s)
        if cur: edges.append(cur)
        return edges

    def _parse_edge_def(self, edge, text):
        if self.ARROW not in text: return
        parts = text.split(self.ARROW)
        if len(parts) != 2: return
        edge['sources'] = self._parse_role_str(parts[0].strip())
        tp = parts[1].strip()
        wm = re.search(r'\s+when\s*:', tp)
        if wm:
            edge['target'] = tp[:wm.start()].strip()
            edge['verdict'] = self._extract_v(tp[wm.end():].strip())
        else:
            edge['target'] = tp
        if edge['target'].startswith('[') and edge['target'].endswith(']'):
            edge['targets'] = [t.strip() for t in edge['target'][1:-1].split(',') if t.strip()]
        else:
            edge['targets'] = [edge['target']] if edge['target'] else []

    def _parse_edge_attr(self, edge, text):
        if text.startswith('carries:'):
            v = text[len('carries:'):].strip()
            if v.startswith('[') and v.endswith(']'):
                edge['carries'] = [x.strip() for x in v[1:-1].split(',') if x.strip()]
            elif v: edge['carries'] = [v]
        elif text.startswith('max_executions:'):
            try: edge['max_executions'] = int(text.split(':')[1].strip())
            except: pass
        elif text.startswith('restrict_verdict:'):
            v = text[len('restrict_verdict:'):].strip()
            if v.startswith('[') and v.endswith(']'):
                edge['restrict_verdict'] = [x.strip().strip('"\'') for x in v[1:-1].split(',') if x.strip()]
            elif v: edge['restrict_verdict'] = [v]

    def _parse_kn(self, lst):
        res = []
        for item in lst:
            if isinstance(item, dict):
                for name, val in item.items():
                    if isinstance(val, dict):
                        res.append({'name': name, 'path': val.get('path', ''), 'inject_to': val.get('inject_to', [])})
                    elif isinstance(val, str):
                        res.append({'name': name, 'path': val, 'inject_to': []})
            elif isinstance(item, str):
                res.append({'name': item, 'path': '', 'inject_to': []})
        return res

    def _parse_roles(self, d):
        roles = {}; order = []
        for name, spec in d.items():
            order.append(name)
            roles[name] = {'confirm': spec.get('confirm', 'auto'),
                           'inputs': self._parse_fl(spec.get('inputs', [])),
                           'outputs': self._parse_fl(spec.get('outputs', []))}
        return roles, order

    def _parse_fl(self, items):
        res = []
        for item in items:
            if isinstance(item, dict):
                for name, path in item.items(): res.append({'name': name, 'path': path})
            elif isinstance(item, str): res.append({'name': item, 'path': item})
        return res

    def _parse_role_str(self, s):
        s = s.strip()
        if s.startswith('[') and s.endswith(']'):
            return [r.strip() for r in s[1:-1].split(',') if r.strip()]
        return [s] if s else []

    def _extract_v(self, expr):
        m = re.search(r'verdict\s*==\s*"([^"]+)"', str(expr))
        if m: return m.group(1)
        m = re.search(r"verdict\s*==\s*'([^']+)'", str(expr))
        return m.group(1) if m else None

    def _infer_terminals(self, model):
        all_src = set(); term = set()
        for e in model.edges:
            for s in e['sources']: all_src.add(s)
            for t in e['targets']:
                if t == '\u5b8c\u6210': term.update(e['sources'])
        if term: return term
        return set(model.roles.keys()) - all_src


# ════════════════════════════════════════════════════════════
#  布局引擎 — DAG 分层 + 坐标计算
# ════════════════════════════════════════════════════════════

class LayoutEngine:
    def __init__(self, model):
        self.m = model
        self.role_pos = {}   # role_name -> {x, y, w, h}
        self.file_pos = {}   # file path -> {x, y, w, h, cat}
        self.links = []      # {from_id, to_id, type, label, style}
        self.W = 0
        self.H = 0
        self.role_nid = {}   # role_name -> node_id
        self.file_nid = {}   # file_path -> node_id

    def compute(self):
        m = self.m
        layers = m.topological_layers()

        # 尺寸
        R_W, R_H = 170, 50
        R_GAP_X = 120
        R_GAP_Y = 25
        TREE_W = 220
        TREE_NODE_H = 22

        # ── 角色坐标（按拓扑层）──
        layer_x_start = TREE_W + 60
        max_layer_size = max(len(l) for l in layers) if layers else 1

        for li, layer in enumerate(layers):
            x = layer_x_start + li * (R_W + R_GAP_X)
            layer_h = len(layer) * R_H + (len(layer) - 1) * R_GAP_Y
            y_start = 80
            for ri, rn in enumerate(layer):
                y = y_start + ri * (R_H + R_GAP_Y)
                nid = f'r{li}_{ri}'
                self.role_nid[rn] = nid
                self.role_pos[rn] = {'x': x, 'y': y, 'w': R_W, 'h': R_H, 'nid': nid, 'layer': li}

        # ── 文件树 ──
        files = m.get_all_files()

        # 构建文件树结构
        def build_tree(file_list, cat):
            """构建目录树，返回嵌套结构"""
            root = {'name': cat, 'path': '', 'children': {}, 'files': []}
            for f in file_list:
                parts = f['path'].split('/')
                node = root
                for i, part in enumerate(parts[:-1]):
                    if part not in node['children']:
                        full = '/'.join(parts[:i+1])
                        node['children'][part] = {'name': part, 'path': full, 'children': {}, 'files': []}
                    node = node['children'][part]
                node['files'].append(f)
            return root

        def flatten_tree(node, x, y, depth=0):
            """递归展开树为坐标列表"""
            indent = depth * 16
            items = []

            # 子目录
            sorted_dirs = sorted(node['children'].items())
            for dname, dnode in sorted_dirs:
                items.append({'type': 'dir', 'name': dname, 'path': dnode['path'],
                              'x': x, 'y': y, 'depth': depth})
                y += TREE_NODE_H
                sub_items, y = flatten_tree(dnode, x, y, depth + 1)
                items.extend(sub_items)

            # 文件
            for f in sorted(node['files'], key=lambda x: x['name']):
                items.append({'type': 'file', 'name': f['name'], 'path': f['path'],
                              'cat': f['cat'], 'x': x, 'y': y, 'depth': depth,
                              'producers': f['producers'], 'consumers': f['consumers']})
                y += TREE_NODE_H

            return items, y

        # Knowledge 树（左侧）
        kn_files = [f for f in files.values() if f['cat'] == 'knowledge']
        kn_tree = build_tree(kn_files, 'knowledge')
        kn_items, _ = flatten_tree(kn_tree, 10, 70)
        kn_x = 10

        for item in kn_items:
            nid = f'kn_{item["path"]}_{item.get("depth",0)}'
            if item['type'] == 'file':
                self.file_nid[item['path']] = nid
                self.file_pos[item['path']] = {
                    'x': kn_x + item['depth'] * 16, 'y': item['y'],
                    'w': TREE_W - item['depth'] * 16, 'h': TREE_NODE_H,
                    'nid': nid, 'cat': 'knowledge',
                    'name': item['name'],
                    'producers': item.get('producers', []),
                    'consumers': item.get('consumers', []),
                }
            item['nid'] = nid

        # Workspace 树（右侧）
        ws_files = [f for f in files.values() if f['cat'] == 'workspace']
        ws_tree = build_tree(ws_files, 'workspace')
        ws_max_x = max((self.role_pos[rn]['x'] + self.role_pos[rn]['w'] for rn in self.role_pos), default=600)
        ws_x = ws_max_x + 80

        ws_items, ws_tree_h = flatten_tree(ws_tree, ws_x, 70)
        for item in ws_items:
            nid = f'ws_{item["path"]}_{item.get("depth",0)}'
            if item['type'] == 'file':
                self.file_nid[item['path']] = nid
                self.file_pos[item['path']] = {
                    'x': item['x'] + item['depth'] * 16, 'y': item['y'],
                    'w': TREE_W - item['depth'] * 16, 'h': TREE_NODE_H,
                    'nid': nid, 'cat': 'workspace',
                    'name': item['name'],
                    'producers': item.get('producers', []),
                    'consumers': item.get('consumers', []),
                }
            item['nid'] = nid

        # External 文件（顶部横排）
        ext_files = [f for f in files.values() if f['cat'] == 'external']
        ext_y = 40
        ext_x_start = layer_x_start
        for i, f in enumerate(sorted(ext_files, key=lambda x: x['path'])):
            nid = f'ext_{i}'
            self.file_nid[f['path']] = nid
            x = ext_x_start + i * 200
            self.file_pos[f['path']] = {
                'x': x, 'y': ext_y, 'w': 190, 'h': TREE_NODE_H,
                'nid': nid, 'cat': 'external',
                'name': f['name'],
                'producers': f['producers'],
                'consumers': f['consumers'],
            }

        # ── 连线 ──
        # role → role (verdict 边)
        for e in m.edges:
            v = e['verdict'] or ''
            label = v
            if e['max_executions']: label += f' x{e["max_executions"]}'
            style = 'normal'
            if v == 'loop': style = 'loop'
            elif any(kw in v for kw in ['reject', 'defect', 'issues', 'challenged', 'BLOCKING']):
                style = 'back'

            for src in e['sources']:
                src_nid = self.role_nid.get(src)
                if not src_nid: continue
                for tgt in e['targets']:
                    if tgt == '\u5b8c\u6210':
                        self.links.append({'from_id': src_nid, 'to_id': None, 'type': 'verdict_end',
                                           'label': label, 'style': style})
                    else:
                        tgt_nid = self.role_nid.get(tgt)
                        if tgt_nid:
                            self.links.append({'from_id': src_nid, 'to_id': tgt_nid, 'type': 'verdict',
                                               'label': label, 'style': style})

        # file → role / role → file (物料边)
        for path, fp in self.file_pos.items():
            fcat = fp['cat']
            fid = fp['nid']
            # consumers: file → role (input)
            for rn in fp['consumers']:
                rnid = self.role_nid.get(rn)
                if rnid:
                    self.links.append({'from_id': fid, 'to_id': rnid, 'type': 'input', 'cat': fcat})
            # producers: role → file (output)
            for rn in fp['producers']:
                rnid = self.role_nid.get(rn)
                if rnid:
                    self.links.append({'from_id': rnid, 'to_id': fid, 'type': 'output', 'cat': fcat})

        # 画布尺寸
        all_right = [fp['x'] + fp['w'] for fp in self.file_pos.values() if fp['cat'] == 'workspace']
        all_bottom_role = [rp['y'] + rp['h'] for rp in self.role_pos.values()]
        all_bottom_file = [fp['y'] + fp['h'] for fp in self.file_pos.values()]
        self.W = max(max(all_right, default=800), max((rp['x'] + rp['w'] for rp in self.role_pos.values()), default=600)) + 60
        self.H = max(max(all_bottom_role, default=400), max(all_bottom_file, default=400)) + 80

        # 保存 tree items 用于渲染
        self.kn_items = kn_items
        self.ws_items = ws_items
        self.ext_files = ext_files

        return self


# ════════════════════════════════════════════════════════════
#  HTML / SVG 生成
# ════════════════════════════════════════════════════════════

def generate(model):
    layout = LayoutEngine(model).compute()
    m = model

    # ── 构建角色数据 JSON ──
    roles_data = {}
    for rn in m.role_order:
        role = m.roles[rn]
        kn_files = m.get_kn_for_role(rn)
        verdicts = m.get_role_verdicts(rn)
        skill_path = f'roles/{rn}/skill.md'
        skill_exists = (m.app_dir / skill_path).exists()

        def finfo(fl):
            res = []
            for f in fl:
                p = f['path']
                exists = (m.app_dir / p).exists() if p else False
                res.append({'name': f['name'], 'path': p, 'exists': exists, 'cat': _cat(p)})
            return res

        roles_data[layout.role_nid[rn]] = {
            'name': rn, 'confirm': role['confirm'],
            'skill': skill_path, 'skill_exists': skill_exists,
            'verdicts': verdicts,
            'inputs': finfo(role['inputs']),
            'outputs': finfo(role['outputs']),
            'knowledge': [{'name': k['name'], 'path': k['path'],
                           'exists': (m.app_dir / k['path']).exists() if k['path'] else False}
                          for k in kn_files],
            'out_edges': [{'v': e['verdict'] or '', 't': t, 'max': e['max_executions'], 'c': len(e['carries'])}
                          for e in m.edges
                          if len(e['sources']) == 1 and e['sources'][0] == rn
                          for t in e['targets']],
            'in_edges': [{'f': ' + '.join(e['sources']), 'v': e['verdict'] or ''}
                         for e in m.edges if rn in e['sources']],
            'input_files': [i['path'] for i in role['inputs']],
            'output_files': [o['path'] for o in role['outputs']],
            'kn_paths': [k['path'] for k in kn_files],
        }

    # ── 构建文件数据 JSON ──
    files_data = {}
    for path, fp in layout.file_pos.items():
        exists = (m.app_dir / path).exists() if path else False
        files_data[fp['nid']] = {
            'name': fp['name'], 'path': path, 'cat': fp['cat'], 'exists': exists,
            'producers': fp['producers'], 'consumers': fp['consumers'],
        }

    # ── 生成 SVG ──
    svg = []

    # Zone 背景
    kn_bottom = max((fp['y'] + fp['h'] for fp in layout.file_pos.values() if fp['cat'] == 'knowledge'), default=70) + 20
    svg.append(f'<rect x="5" y="55" width="{layout.kn_items and 230 or 230}" height="{max(kn_bottom - 55, 100)}" rx="8" fill="rgba(99,102,241,0.05)" stroke="rgba(99,102,241,0.15)" stroke-width="1"/>')
    svg.append(f'<text x="15" y="50" fill="#818cf8" font-size="13" font-weight="600">\U0001f4da Knowledge</text>')

    ws_top = 55
    ws_bottom = max((fp['y'] + fp['h'] for fp in layout.file_pos.values() if fp['cat'] == 'workspace'), default=200) + 20
    ws_x = min((fp['x'] for fp in layout.file_pos.values() if fp['cat'] == 'workspace'), default=800) - 10
    svg.append(f'<rect x="{ws_x}" y="{ws_top}" width="240" height="{max(ws_bottom - ws_top, 100)}" rx="8" fill="rgba(74,222,128,0.05)" stroke="rgba(74,222,128,0.15)" stroke-width="1"/>')
    svg.append(f'<text x="{ws_x + 10}" y="50" fill="#4ade80" font-size="13" font-weight="600">\U0001f4e6 Workspace \u4ea7\u7269</text>')

    if layout.ext_files:
        svg.append(f'<text x="{layout.role_pos.get(m.entry_role, {}).get("x", 300) + 20}" y="32" fill="#fbbf24" font-size="13" font-weight="600">\U0001f4c4 External</text>')

    # ── 连线层（底层）──
    svg.append('<g id="links">')

    for link in layout.links:
        src_role = None; src_file = None; tgt_role = None; tgt_file = None

        # 找 source 位置
        for rn, rp in layout.role_pos.items():
            if rp['nid'] == link['from_id']:
                src_role = rp; break
        for path, fp in layout.file_pos.items():
            if fp['nid'] == link['from_id']:
                src_file = fp; break
        if link['to_id']:
            for rn, rp in layout.role_pos.items():
                if rp['nid'] == link['to_id']:
                    tgt_role = rp; break
            for path, fp in layout.file_pos.items():
                if fp['nid'] == link['to_id']:
                    tgt_file = fp; break

        if not (src_role or src_file): continue

        link_id = f'{link["from_id"]}__{link["to_id"] or "end"}'

        if link['type'] == 'input':
            # file → role
            x1 = src_file['x'] + src_file['w']; y1 = src_file['y'] + src_file['h'] / 2
            x2 = tgt_role['x']; y2 = tgt_role['y'] + tgt_role['h'] / 2
            color = {'knowledge': '#818cf8', 'workspace': '#4ade80', 'external': '#fbbf24'}.get(link.get('cat'), '#64748b')
            svg.append(f'<path d="M{x1:.0f},{y1:.0f} C{(x1+x2)/2:.0f},{y1:.0f} {(x1+x2)/2:.0f},{y2:.0f} {x2:.0f},{y2:.0f}" stroke="{color}" stroke-width="1" stroke-opacity="0.12" fill="none" class="link link-input" data-cat="{link.get("cat","")}" data-file="{link["from_id"]}" data-role="{link["to_id"]}" id="{link_id}"/>')

        elif link['type'] == 'output':
            # role → file
            x1 = src_role['x'] + src_role['w']; y1 = src_role['y'] + src_role['h'] / 2
            x2 = tgt_file['x']; y2 = tgt_file['y'] + tgt_file['h'] / 2
            svg.append(f'<path d="M{x1:.0f},{y1:.0f} C{(x1+x2)/2:.0f},{y1:.0f} {(x1+x2)/2:.0f},{y2:.0f} {x2:.0f},{y2:.0f}" stroke="#4ade80" stroke-width="1" stroke-opacity="0.12" fill="none" class="link link-output" data-file="{link["to_id"]}" data-role="{link["from_id"]}" id="{link_id}"/>')

        elif link['type'] == 'verdict':
            # role → role
            x1 = src_role['x'] + src_role['w'] / 2; y1 = src_role['y'] + src_role['h']
            x2 = tgt_role['x'] + tgt_role['w'] / 2; y2 = tgt_role['y']
            color = {'back': '#f87171', 'loop': '#fbbf24'}.get(link.get('style'), '#38bdf8')
            sw = '2' if link.get('style') == 'back' else '1.5'
            mid_y = (y1 + y2) / 2
            svg.append(f'<path d="M{x1:.0f},{y1:.0f} C{x1:.0f},{mid_y:.0f} {x2:.0f},{mid_y:.0f} {x2:.0f},{y2:.0f}" stroke="{color}" stroke-width="{sw}" stroke-opacity="0.4" fill="none" class="link link-verdict" style="{link.get("style","")}" data-from="{link["from_id"]}" data-to="{link["to_id"]}" id="{link_id}"/>')
            if link.get('label'):
                lx = (x1 + x2) / 2; ly = mid_y
                svg.append(f'<text x="{lx:.0f}" y="{ly:.0f}" fill="{color}" font-size="9" text-anchor="middle" opacity="0.6" class="edge-label">{html.escape(link["label"])}</text>')

        elif link['type'] == 'verdict_end':
            x1 = src_role['x'] + src_role['w'] / 2; y1 = src_role['y'] + src_role['h']
            svg.append(f'<text x="{x1:.0f}" y="{y1+18:.0f}" fill="#fbbf24" font-size="12" text-anchor="middle" class="end-mark">\U0001f3c1 {html.escape(link.get("label", ""))}</text>')

    svg.append('</g>')

    # ── 角色节点 ──
    for rn in m.role_order:
        rp = layout.role_pos[rn]
        role = m.roles[rn]
        fill = '#1e3a5f' if role['confirm'] == 'manual' else '#1a3622'
        stroke = '#60a5fa' if role['confirm'] == 'manual' else '#4ade80'
        nid = rp['nid']
        icon = '\U0001f680' if rn == m.entry_role else ('\U0001f3c1' if rn in m.terminal_roles else ('\U0001f535' if role['confirm'] == 'manual' else '\U0001f7e2'))
        svg.append(f'<g class="node-role" data-nid="{nid}" data-rn="{html.escape(rn)}" transform="translate({rp["x"]},{rp["y"]})">')
        svg.append(f'<rect width="{rp["w"]}" height="{rp["h"]}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="2"/>')
        svg.append(f'<text x="{rp["w"]/2}" y="20" text-anchor="middle" fill="#e2e8f0" font-size="12" font-weight="600">{icon} {html.escape(rn)}</text>')
        svg.append(f'<text x="{rp["w"]/2}" y="38" text-anchor="middle" fill="#64748b" font-size="9">{role["confirm"]}</text>')
        svg.append('</g>')

    # ── Knowledge 文件树节点 ──
    for item in layout.kn_items:
        if item['type'] == 'dir':
            svg.append(f'<g class="tree-dir" transform="translate({item["x"]},{item["y"]})">')
            svg.append(f'<text x="0" y="14" fill="#818cf8" font-size="11" opacity="0.6">\U0001f4c1 {html.escape(item["name"])}</text>')
            svg.append('</g>')
        elif item['type'] == 'file':
            fp = layout.file_pos.get(item['path'])
            if not fp: continue
            exists = (m.app_dir / item['path']).exists() if item['path'] else False
            nid = fp['nid']
            mark = '\u2705' if exists else '\u274c'
            opacity = '1' if exists else '0.4'
            svg.append(f'<g class="node-file" data-nid="{nid}" data-cat="knowledge" data-path="{html.escape(item["path"])}" transform="translate({fp["x"]},{fp["y"]})" opacity="{opacity}">')
            svg.append(f'<rect width="{fp["w"]}" height="{fp["h"]}" rx="4" fill="rgba(49,46,129,0.4)" stroke="rgba(165,180,252,0.3)" stroke-width="0.5"/>')
            short = item['name'][:24] + '..' if len(item['name']) > 26 else item['name']
            svg.append(f'<text x="4" y="15" fill="#a5b4fc" font-size="10">{mark} {html.escape(short)}</text>')
            svg.append('</g>')

    # ── Workspace 文件树节点 ──
    for item in layout.ws_items:
        if item['type'] == 'dir':
            svg.append(f'<g class="tree-dir" transform="translate({item["x"]},{item["y"]})">')
            svg.append(f'<text x="0" y="14" fill="#4ade80" font-size="11" opacity="0.6">\U0001f4c1 {html.escape(item["name"])}</text>')
            svg.append('</g>')
        elif item['type'] == 'file':
            fp = layout.file_pos.get(item['path'])
            if not fp: continue
            exists = (m.app_dir / item['path']).exists() if item['path'] else False
            nid = fp['nid']
            mark = '\u2705' if exists else '\u274c'
            opacity = '1' if exists else '0.4'
            svg.append(f'<g class="node-file" data-nid="{nid}" data-cat="workspace" data-path="{html.escape(item["path"])}" transform="translate({fp["x"]},{fp["y"]})" opacity="{opacity}">')
            svg.append(f'<rect width="{fp["w"]}" height="{fp["h"]}" rx="4" fill="rgba(26,54,34,0.4)" stroke="rgba(74,222,128,0.3)" stroke-width="0.5"/>')
            short = item['name'][:24] + '..' if len(item['name']) > 26 else item['name']
            svg.append(f'<text x="4" y="15" fill="#4ade80" font-size="10">{mark} {html.escape(short)}</text>')
            svg.append('</g>')

    # ── External 文件节点 ──
    for f in layout.ext_files:
        fp = layout.file_pos[f['path']]
        exists = (m.app_dir / f['path']).exists() if f['path'] else False
        nid = fp['nid']
        mark = '\u2705' if exists else '\u274c'
        svg.append(f'<g class="node-file" data-nid="{nid}" data-cat="external" data-path="{html.escape(f["path"])}" transform="translate({fp["x"]},{fp["y"]})">')
        svg.append(f'<rect width="{fp["w"]}" height="{fp["h"]}" rx="4" fill="rgba(59,42,14,0.4)" stroke="rgba(251,191,36,0.3)" stroke-width="0.5"/>')
        short = f['name'][:20] + '..' if len(f['name']) > 22 else f['name']
        svg.append(f'<text x="4" y="15" fill="#fbbf24" font-size="10">{mark} {html.escape(short)}</text>')
        svg.append('</g>')

    svg_inner = '\n'.join(svg)
    roles_json = json.dumps(roles_data, ensure_ascii=False)
    files_json = json.dumps(files_data, ensure_ascii=False)
    W = layout.W
    H = layout.H
    app_name = html.escape(model.app_name)

    template = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>@@TITLE@@</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:-apple-system,'PingFang SC',sans-serif;background:#0f172a;color:#e2e8f0;overflow:hidden;}

#topbar{position:fixed;top:0;left:0;right:0;z-index:50;height:42px;background:#1e293b;border-bottom:1px solid #334155;display:flex;align-items:center;gap:12px;padding:0 20px;}
#topbar h1{font-size:15px;color:#38bdf8;white-space:nowrap;}
#topbar .legend{display:flex;gap:10px;font-size:11px;color:#64748b;}
#topbar .legend span{display:flex;align-items:center;gap:3px;}
#topbar .ctrls{margin-left:auto;display:flex;gap:6px;align-items:center;}
#topbar button{background:#334155;border:1px solid #475569;color:#e2e8f0;border-radius:5px;padding:3px 10px;font-size:12px;cursor:pointer;}
#topbar button:hover{background:#475569;}
#topbar .zv{color:#64748b;font-size:11px;min-width:36px;text-align:center;}

#cwrap{position:fixed;top:42px;left:0;right:0;bottom:0;overflow:hidden;}
#svgc{transform-origin:0 0;}

.node-role{cursor:pointer;transition:opacity 0.2s;}
.node-role:hover rect{stroke-width:3;filter:brightness(1.4);}
.node-file{cursor:pointer;transition:opacity 0.2s;}
.node-file:hover rect{stroke-width:2;filter:brightness(1.4);}

/* 悬停高亮动画 */
.link{transition:stroke-opacity 0.3s,stroke-width 0.3s;}
@keyframes pulse-green{0%,100%{stroke-opacity:0.7;stroke-width:2;}50%{stroke-opacity:1;stroke-width:3.5;}}
@keyframes pulse-red{0%,100%{stroke-opacity:0.7;stroke-width:2;}50%{stroke-opacity:1;stroke-width:3.5;}}
@keyframes flow-dash{to{stroke-dashoffset:-20;}}

.link-active-green{animation:pulse-green 1s ease-in-out infinite;stroke-dasharray:6,4 !important;stroke:#4ade80 !important;}
.link-active-kn{animation:pulse-green 1s ease-in-out infinite;stroke-dasharray:6,4 !important;stroke:#818cf8 !important;}
.link-active-red{animation:pulse-red 1s ease-in-out infinite;stroke-dasharray:6,4 !important;stroke:#f87171 !important;}
.link-dim{stroke-opacity:0.03 !important;}
.node-dim{opacity:0.15 !important;}
.node-highlight rect{filter:brightness(1.5) drop-shadow(0 0 6px currentColor);}

/* tooltip */
#tt{display:none;position:fixed;z-index:100;background:#1e293b;border:1px solid #475569;border-radius:8px;max-width:380px;max-height:75vh;overflow-y:auto;box-shadow:0 8px 32px rgba(0,0,0,0.7);font-size:11px;}
#tt .th{background:#334155;padding:7px 11px;border-radius:8px 8px 0 0;font-size:14px;font-weight:bold;color:#f1f5f9;}
#tt .tb{padding:8px 11px;}
#tt .ts{margin-bottom:8px;}
#tt .ts h4{font-size:9px;text-transform:uppercase;letter-spacing:.5px;color:#818cf8;margin-bottom:3px;}
#tt .tr{display:flex;align-items:baseline;gap:4px;padding:1px 0;line-height:1.3;}
#tt .tr .fn{color:#cbd5e1;min-width:60px;font-size:10px;}
#tt .tr .fp{color:#64748b;font-family:monospace;font-size:9px;word-break:break-all;}
#tt .vt{display:inline-block;background:#312e81;color:#a5b4fc;padding:1px 5px;border-radius:4px;font-family:monospace;font-size:9px;margin:1px;}
#tt .er{padding:1px 0;color:#94a3b8;font-size:10px;}
#tt .ev{color:#a5b4fc;font-family:monospace;}
#tt .et{color:#4ade80;}
#tt .cat-kn{color:#a5b4fc;}#tt .cat-ws{color:#4ade80;}#tt .cat-ext{color:#fbbf24;}
</style>
</head>
<body>
<div id="topbar">
  <h1>&#128203; @@APP_NAME@@</h1>
  <div class="legend">
    <span><span style="color:#38bdf8">&#9881;</span> Role</span>
    <span><span style="color:#a5b4fc">&#128218;</span> Knowledge</span>
    <span><span style="color:#4ade80">&#128230;</span> Workspace</span>
    <span><span style="color:#fbbf24">&#128196;</span> External</span>
    <span style="color:#64748b;">| &#128161; &#25335;&#20197;&#36873;&#20013; Role &#30475;&#27880;&#20837;/&#36755;&#20986;&#21160;&#30011;</span>
  </div>
  <div class="ctrls">
    <button onclick="zb(-0.1)">&#128196;</button>
    <span class="zv" id="zv">100%</span>
    <button onclick="zb(0.1)">&#128197;</button>
    <button onclick="rv()">Reset</button>
  </div>
</div>
<div id="cwrap"><div id="svgc">
@@SVG@@
</div></div>
<div id="tt"></div>
<script>
const R=@@ROLES@@,F=@@FILES@@;
var z=1,px=0,py=0,dr=false,sx,sy;
function at(){document.getElementById('svgc').style.transform='translate('+px+'px,'+py+'px) scale('+z+')';document.getElementById('zv').textContent=Math.round(z*100)+'%';}
function zb(d){z=Math.max(0.15,Math.min(3,z+d));at();}
function rv(){z=1;px=0;py=0;at();}
var cw=document.getElementById('cwrap');
cw.addEventListener('wheel',function(e){e.preventDefault();zb(e.deltaY>0?-0.08:0.08);});
cw.addEventListener('mousedown',function(e){if(e.target.closest('.node-role')||e.target.closest('.node-file'))return;dr=true;sx=e.clientX-px;sy=e.clientY-py;cw.style.cursor='grabbing';});
document.addEventListener('mousemove',function(e){if(!dr)return;px=e.clientX-sx;py=e.clientY-sy;at();});
document.addEventListener('mouseup',function(){dr=false;cw.style.cursor='';});

function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML;}
function showTT(h,e){var t=document.getElementById('tt');t.innerHTML=h;t.style.display='block';pt(e);}
function pt(e){var t=document.getElementById('tt');var x=e.clientX+12,y=e.clientY+12;var tw=t.offsetWidth,th=t.offsetHeight;if(x+tw>innerWidth-8)x=e.clientX-tw-12;if(y+th>innerHeight-8)y=innerHeight-th-8;if(y<46)y=46;t.style.left=x+'px';t.style.top=y+'px';}
function hideTT(){document.getElementById('tt').style.display='none';}

// ═══ 悬停角色：高亮动画 ═══
function highlightRole(nid){
  var d=R[nid];if(!d)return;
  // dim everything
  document.querySelectorAll('.node-role,.node-file,.tree-dir').forEach(function(el){el.classList.add('node-dim');});
  // highlight this role
  var roleEl=document.querySelector('[data-nid="'+nid+'"]');
  if(roleEl)roleEl.classList.remove('node-dim');

  // highlight input files + green links
  d.input_files.forEach(function(path){
    var fid=findFileNid(path);if(!fid)return;
    var fel=document.querySelector('[data-nid="'+fid+'"]');
    if(fel){fel.classList.remove('node-dim');fel.classList.add('node-highlight');}
    var link=document.getElementById(fid+'__'+nid);
    if(link)link.classList.add('link-active-green');
  });

  // highlight knowledge + purple links
  d.kn_paths.forEach(function(path){
    var fid=findFileNid(path);if(!fid)return;
    var fel=document.querySelector('[data-nid="'+fid+'"]');
    if(fel){fel.classList.remove('node-dim');fel.classList.add('node-highlight');}
    var link=document.getElementById(fid+'__'+nid);
    if(link)link.classList.add('link-active-kn');
  });

  // highlight output files + red links
  d.output_files.forEach(function(path){
    var fid=findFileNid(path);if(!fid)return;
    var fel=document.querySelector('[data-nid="'+fid+'"]');
    if(fel){fel.classList.remove('node-dim');fel.classList.add('node-highlight');}
    var link=document.getElementById(nid+'__'+fid);
    if(link)link.classList.add('link-active-red');
  });

  // highlight verdict links from this role
  document.querySelectorAll('.link-verdict[data-from="'+nid+'"]').forEach(function(el){
    el.classList.remove('link-dim');
    el.style.strokeOpacity='0.8';
    var to=el.getAttribute('data-to');
    var tgt=document.querySelector('[data-nid="'+to+'"]');
    if(tgt)tgt.classList.remove('node-dim');
  });
  // verdict links to this role
  document.querySelectorAll('.link-verdict[data-to="'+nid+'"]').forEach(function(el){
    el.classList.remove('link-dim');
    el.style.strokeOpacity='0.8';
    var from=el.getAttribute('data-from');
    var src=document.querySelector('[data-nid="'+from+'"]');
    if(src)src.classList.remove('node-dim');
  });
}

function clearHighlight(){
  document.querySelectorAll('.node-dim').forEach(function(el){el.classList.remove('node-dim');});
  document.querySelectorAll('.node-highlight').forEach(function(el){el.classList.remove('node-highlight');});
  document.querySelectorAll('.link-active-green,.link-active-kn,.link-active-red').forEach(function(el){el.classList.remove('link-active-green','link-active-kn','link-active-red');});
  document.querySelectorAll('.link-verdict').forEach(function(el){el.style.strokeOpacity='';});
}

function findFileNid(path){
  var el=document.querySelector('[data-path="'+CSS.escape(path)+'"]');
  return el?el.getAttribute('data-nid'):null;
}

function roleTT(nid,e){
  var d=R[nid];if(!d)return;
  var h='<div class="th">'+esc(d.name)+'</div><div class="tb">';
  h+='<div class="ts"><h4>&#9881; Skill</h4><div class="tr"><span class="fp">'+(d.skill_exists?'&#9989;':'&#10060;')+' '+esc(d.skill)+'</span></div></div>';
  if(d.knowledge.length){h+='<div class="ts"><h4>&#128218; Knowledge ('+d.knowledge.length+')</h4>';d.knowledge.forEach(function(k){h+='<div class="tr"><span class="fn cat-kn">'+(k.exists?'&#9989;':'&#10060;')+' '+esc(k.name)+'</span><span class="fp">'+esc(k.path)+'</span></div>';});h+='</div>';}
  if(d.inputs.length){h+='<div class="ts"><h4>&#128229; Inputs ('+d.inputs.length+')</h4>';d.inputs.forEach(function(i){var c=i.cat==='knowledge'?'cat-kn':i.cat==='workspace'?'cat-ws':'cat-ext';h+='<div class="tr"><span class="fn '+c+'">'+(i.exists?'&#9989;':'&#10060;')+' '+esc(i.name)+'</span><span class="fp">'+esc(i.path)+'</span></div>';});h+='</div>';}
  if(d.outputs.length){h+='<div class="ts"><h4>&#128226; Outputs ('+d.outputs.length+')</h4>';d.outputs.forEach(function(o){var c=o.cat==='knowledge'?'cat-kn':o.cat==='workspace'?'cat-ws':'cat-ext';h+='<div class="tr"><span class="fn '+c+'">'+(o.exists?'&#9989;':'&#10060;')+' '+esc(o.name)+'</span><span class="fp">'+esc(o.path)+'</span></div>';});h+='</div>';}
  if(d.verdicts.length){h+='<div class="ts"><h4>&#9878; Verdict</h4>';d.verdicts.forEach(function(v){h+='<span class="vt">'+esc(v)+'</span>';});h+='</div>';}
  if(d.out_edges.length){h+='<div class="ts"><h4>&#128279; Out</h4>';d.out_edges.forEach(function(e){var ex='';if(e.max)ex+=' x'+e.max;if(e.c)ex+=' +'+e.c;h+='<div class="er"><span class="ev">'+esc(e.v)+'</span> &#8594; <span class="et">'+esc(e.t)+'</span><span style="color:#475569">'+ex+'</span></div>';});h+='</div>';}
  h+='</div>';
  showTT(h,e);
}

function fileTT(nid,e){
  var d=F[nid];if(!d)return;
  var cl={knowledge:['cat-kn','#a5b4fc','Knowledge'],workspace:['cat-ws','#4ade80','Workspace'],external:['cat-ext','#fbbf24','External']}[d.cat];
  var m=d.exists?'&#9989;':'&#10060;';
  var h='<div class="th" style="color:'+cl[1]+'">'+m+' '+esc(d.name)+'</div><div class="tb">';
  h+='<div class="ts"><h4>Path</h4><div class="tr"><span class="fp">'+esc(d.path)+'</span></div></div>';
  h+='<div class="ts"><h4>Type</h4><div class="tr"><span class="'+cl[0]+'">'+cl[2]+'</span></div></div>';
  if(d.producers.length){h+='<div class="ts"><h4>&#9999; &#30001;&#35841;&#29983;&#20135;</h4>';d.producers.forEach(function(p){h+='<div class="er"><span class="et">'+esc(p)+'</span></div>';});h+='</div>';}
  if(d.consumers.length){h+='<div class="ts"><h4>&#128064; &#34987;&#35841;&#35835;&#21462;</h4>';d.consumers.forEach(function(c){h+='<div class="er"><span class="et">'+esc(c)+'</span></div>';});h+='</div>';}
  h+='</div>';
  showTT(h,e);
}

// bind events
setTimeout(function(){
  document.querySelectorAll('.node-role').forEach(function(el){
    var nid=el.getAttribute('data-nid');
    el.addEventListener('mouseenter',function(e){clearHighlight();highlightRole(nid);roleTT(nid,e);});
    el.addEventListener('mousemove',pt);
    el.addEventListener('mouseleave',function(){clearHighlight();hideTT();});
  });
  document.querySelectorAll('.node-file').forEach(function(el){
    var nid=el.getAttribute('data-nid');
    el.addEventListener('mouseenter',function(e){fileTT(nid,e);});
    el.addEventListener('mousemove',pt);
    el.addEventListener('mouseleave',hideTT);
  });
},200);
</script>
</body></html>'''

    result = template
    result = result.replace('@@TITLE@@', app_name)
    result = result.replace('@@APP_NAME@@', app_name)
    result = result.replace('@@SVG@@', f'<svg width="{W}" height="{H}" xmlns="http://www.w3.org/2000/svg" style="background:#0f172a">\n{svg_inner}\n</svg>')
    result = result.replace('@@ROLES@@', roles_json)
    result = result.replace('@@FILES@@', files_json)
    return result


# ═══ 主入口 ═══

def main():
    if len(sys.argv) < 2:
        print("用法: python3 app_inspector.py <app.yaml> [--open]")
        sys.exit(1)
    yaml_path = sys.argv[1]
    do_open = '--open' in sys.argv
    if not os.path.exists(yaml_path):
        print(f"文件不存在: {yaml_path}")
        sys.exit(1)

    model = AppYamlParser(yaml_path).parse()
    layers = model.topological_layers()
    print(f"\n  \U0001f5fa {model.app_name}")
    for i, layer in enumerate(layers):
        _sep = ' \u2192 '
        print(f"    L{i}: {_sep.join(layer)}")

    out = model.app_dir / f"_app_inspector_{model.app_name}.html"
    out.write_text(generate(model), encoding='utf-8')
    print(f"\n  \U0001f4c4 {out}")
    if do_open:
        if sys.platform == 'darwin':
            subprocess.call(['open', str(out)])
        elif sys.platform == 'win32':
            os.startfile(str(out))
        else:
            subprocess.call(['xdg-open', str(out)])


if __name__ == '__main__':
    main()
