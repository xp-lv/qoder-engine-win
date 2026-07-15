#!/usr/bin/env python3
"""state_io.py — STATE.json 唯一读写入口。

所有对 STATE.json 的读写操作必须通过本模块完成。
禁止任何脚本自行实现 json.dump/os.replace/filelock 逻辑。

Usage:
  from state_io import load_state, save_state

  state = load_state(state_path)       # 读
  state["step_status"][step] = {...}   # 改
  save_state(state_path, state)        # 写（原子 + 文件锁）
"""
import json, os, tempfile, sys
from filelock import acquire_lock, release_lock


def load_state(state_path):
    """安全读取 STATE.json，返回 dict。文件不存在或解析失败返回 None。

    Windows 适配：读取使用 encoding='utf-8-sig'（自动跳过 BOM 头）。
    """
    try:
        with open(state_path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None


def save_state(state_path, state):
    """★ STATE.json 唯一写入函数 ★

    原子写入（tempfile + os.replace）+ 文件锁保护。
    所有脚本必须通过此函数写 STATE.json，禁止自行实现写入逻辑。

    Windows 适配：写入使用 encoding='utf-8'（不加 BOM）。
    """
    d = os.path.dirname(state_path)
    if d:
        os.makedirs(d, exist_ok=True)

    lock_path = state_path + ".lock"
    with open(lock_path, "w", encoding="utf-8") as lock_file:
        if not acquire_lock(lock_file):
            raise RuntimeError("获取 STATE.json 文件锁失败")

        try:
            fd, tmp_path = tempfile.mkstemp(suffix=".tmp", dir=d or ".")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(state, f, ensure_ascii=False, indent=2)
                os.replace(tmp_path, state_path)
            except Exception:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                raise
        finally:
            release_lock(lock_file)
