#!/usr/bin/env python3
"""state_io.py — STATE.json 唯一读写入口（v7.0: 移除写入后自动修复）。

所有对 STATE.json 的读写操作必须通过本模块完成。
禁止任何脚本自行实现 json.dump/os.replace/filelock 逻辑。

v7.0 变更：
  - 移除 _post_write_check_inplace / _apply_basic_fixes / _log_violations。
  - save_state 和 state_txn 退化为纯写入，不再在写入后执行不变量校验和自动修复。
  - 自动修复引入不确定性（合法瞬态窗口被误判），已全部删除。
  - 不变量检测保留在 state_health_check.py（仅报告，不修复）。

state_txn 上下文管理器 — STATE.json 写入的唯一规范机制。
  with state_txn(path) as st:          # 获取锁 + 读取
      st["key"] = value                # 修改
  # 退出时自动：写入 + 释放锁

  历史 API 兼容：
  - load_state: 只读，不加锁
  - save_state: 仅写入（已加锁），向后兼容
  - modify_state_locked: 回调式 RMW（state_txn 的函数版）
"""
import json, os, tempfile, sys
from contextlib import contextmanager
from filelock import acquire_lock, release_lock


def load_state(state_path):
    """安全读取 STATE.json，返回 dict。文件不存在或解析失败返回 None。"""
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _write_unlocked(state_path, state):
    """写入 STATE.json（tempfile + os.replace），不获取锁。

    调用者必须已持有 lock_path 文件锁。
    """
    d = os.path.dirname(state_path)
    if d:
        os.makedirs(d, exist_ok=True)
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


def save_state(state_path, state, validate=True):
    """★ STATE.json 唯一写入函数 ★ (v7.0: 纯写入，无写入后校验/修复)

    v7.0: 移除 _post_write_check_inplace 调用。
    save_state 退化为纯写入操作，不再引入自动修复的不确定性。
    不变量检测由 state_health_check.py 独立执行（仅报告）。

    Args:
        state_path: STATE.json 路径
        state: 要写入的 state dict
        validate: 已废弃（v7.0保留参数仅为向后兼容，不再有效果）
    """
    d = os.path.dirname(state_path)
    if d:
        os.makedirs(d, exist_ok=True)
    lock_path = state_path + ".lock"
    with open(lock_path, "w") as lock_file:
        if not acquire_lock(lock_file):
            raise RuntimeError("获取 STATE.json 文件锁失败")
        try:
            _write_unlocked(state_path, state)
        finally:
            release_lock(lock_file)


@contextmanager
def state_txn(state_path, timeout=60):
    """★ STATE.json 原子事务 ★ (v7.0: 纯写入，无写入后校验/修复)

    在单一文件锁内完成 读取 → 修改 → 写入。
    锁的生命周期绑定到 with 块，异常自动回滚（不写入）。

    用法：
        with state_txn(path) as st:       # 获取锁 + 读取最新 state
            st["key"] = value             # 直接修改 st
        # 正常退出 → 原子写入
        # 异常退出 → 不写入（磁盘状态不变），释放锁

    约束：with 块内禁止调用引擎脚本（subprocess 会死锁等待同一把锁）。

    Args:
        state_path: STATE.json 路径
        timeout: 获取锁超时秒数

    Yields:
        state dict（可安全修改）
    """
    d = os.path.dirname(state_path)
    if d:
        os.makedirs(d, exist_ok=True)
    lock_path = state_path + ".lock"
    with open(lock_path, "w") as lock_file:
        if not acquire_lock(lock_file, timeout):
            raise RuntimeError("获取 STATE.json 文件锁失败")
        try:
            st = load_state(state_path)
            if st is None:
                st = {}
            yield st
            # 正常退出 with 块 → 原子写入
            _write_unlocked(state_path, st)
        finally:
            # 异常路径：跳过 _write_unlocked，磁盘状态保持不变
            release_lock(lock_file)


def modify_state_locked(state_path, modifier_fn, timeout=60):
    """回调式原子 RMW（state_txn 的函数变体，用于不便用 with 的场景）。

    等价于：
        with state_txn(state_path, timeout) as st:
            modifier_fn(st)

    Args:
        state_path: STATE.json 路径
        modifier_fn: 接收当前 state dict，直接原地修改（无需返回值）
        timeout: 获取锁超时秒数

    Returns:
        修改后的 state dict
    """
    with state_txn(state_path, timeout) as st:
        modified = modifier_fn(st)
        if modified is not None and modified is not st:
            # 兼容旧约定：modifier_fn 返回新 dict（非原地修改）时替换
            st.clear()
            st.update(modified)
        return st
