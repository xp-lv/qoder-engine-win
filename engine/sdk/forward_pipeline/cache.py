"""SHA-256 输入哈希缓存 for COMSOL Forward Pipeline SDK.

设计目标
--------
1. 相同输入（eps_real_csv 内容、model_path 内容、freq_list 等）直接返回 cached 结果，不重跑 COMSOL。
2. 哈希基于文件**内容**而非路径，避免"同名不同内容"导致的错误命中。
3. SDK_VERSION 参与哈希，强制版本失效（SDK 升级后所有缓存自动失效）。
4. 原子写入：先写到 .tmp/ 再 rename，避免并发或中断产生半成品缓存。

缓存目录布局
------------
    <cache_root>/
    └── <sha256[:16]>/
        ├── input.json              # 输入参数快照（可读性 + 调试）
        ├── forward/
        │   ├── J_obs_data.mat
        │   ├── forward_dataset.json
        │   └── v5a_result.json
        └── adjoint/
            └── adjoint_field.mat
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional


# SDK 版本号，参与哈希计算。升级时递增可强制所有缓存失效。
SDK_VERSION = "1.0.0"

# 哈希截断长度（取 SHA-256 前 16 个十六进制字符）
HASH_PREFIX_LEN = 16


def _sha256_file(path: str, chunk_size: int = 1 << 20) -> str:
    """计算文件内容的 SHA-256，以 1MB 块流式读取避免大文件 OOM。"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _normalize_freq_list(freq_list: List[float]) -> str:
    """规范化频率列表：排序无关的精确表示，避免浮点抖动。"""
    return json.dumps([float(f) for f in freq_list], sort_keys=True)


@dataclass
class CacheKey:
    """缓存键的所有组成部分（用于调试和日志）。"""

    sdk_version: str
    eps_real_hash: str           # eps_real_csv 内容哈希
    eps_imag_hash: str           # eps_imag_csv 内容哈希（'' 表示无）
    model_hash: str              # .mph 模型文件内容哈希
    freq_repr: str               # 规范化频率列表
    n_directions: int
    measurement_R: float
    # 伴随专用
    f_adj_hash: str = ""         # 伴随源 .mat 内容哈希
    forward_mat_hash: str = ""   # 正演产出 .mat 内容哈希（伴随缓存依赖）

    def to_hash(self) -> str:
        """合成 SHA-256 哈希（截断到 HASH_PREFIX_LEN）。"""
        parts = [
            self.sdk_version,
            self.eps_real_hash,
            self.eps_imag_hash,
            self.model_hash,
            self.freq_repr,
            f"n_dir={self.n_directions}",
            f"R={self.measurement_R:.6f}",
        ]
        if self.f_adj_hash:
            parts.append(f"f_adj={self.f_adj_hash}")
        if self.forward_mat_hash:
            parts.append(f"fwd_mat={self.forward_mat_hash}")
        blob = "\n".join(parts).encode("utf-8")
        return _sha256_bytes(blob)[:HASH_PREFIX_LEN]

    def to_snapshot(self) -> Dict[str, Any]:
        """生成 input.json 快照（人类可读，便于调试缓存命中/未命中）。"""
        return {
            "sdk_version": self.sdk_version,
            "eps_real_hash": self.eps_real_hash,
            "eps_imag_hash": self.eps_imag_hash,
            "model_hash": self.model_hash,
            "freq_repr": self.freq_repr,
            "n_directions": self.n_directions,
            "measurement_R": self.measurement_R,
            "f_adj_hash": self.f_adj_hash,
            "forward_mat_hash": self.forward_mat_hash,
        }


def build_forward_key(
    eps_real_csv: str,
    eps_imag_csv: str,
    freq_list: List[float],
    model_path: str,
    n_directions: int,
    measurement_R: float,
) -> CacheKey:
    """构造正演缓存键。"""
    if not os.path.isfile(eps_real_csv):
        raise FileNotFoundError(f"eps_real_csv not found: {eps_real_csv}")
    if not os.path.isfile(model_path):
        raise FileNotFoundError(f"model_path not found: {model_path}")

    eps_real_hash = _sha256_file(eps_real_csv)
    eps_imag_hash = _sha256_file(eps_imag_csv) if eps_imag_csv and os.path.isfile(eps_imag_csv) else ""
    model_hash = _sha256_file(model_path)

    return CacheKey(
        sdk_version=SDK_VERSION,
        eps_real_hash=eps_real_hash,
        eps_imag_hash=eps_imag_hash,
        model_hash=model_hash,
        freq_repr=_normalize_freq_list(freq_list),
        n_directions=int(n_directions),
        measurement_R=float(measurement_R),
    )


def build_adjoint_key(
    forward_mat_path: str,
    f_adj_mat_path: str,
    voxel_positions_mat_path: str,
    freq_list: List[float],
    model_path: str,
) -> CacheKey:
    """构造伴随缓存键。

    伴随场依赖：
    - 正演产出的 .mat（含 LU 因子索引 + E_total）
    - 伴随源 f_adj
    - 体素位置（决定加载位置）
    - 频率列表
    - .mph 模型（几何/网格）
    """
    for label, p in [
        ("forward_mat_path", forward_mat_path),
        ("f_adj_mat_path", f_adj_mat_path),
        ("voxel_positions_mat_path", voxel_positions_mat_path),
        ("model_path", model_path),
    ]:
        if not os.path.isfile(p):
            raise FileNotFoundError(f"{label} not found: {p}")

    return CacheKey(
        sdk_version=SDK_VERSION,
        # 伴随缓存不依赖 eps_real/imag（已被 forward_mat 编码）
        eps_real_hash="",
        eps_imag_hash="",
        model_hash=_sha256_file(model_path),
        freq_repr=_normalize_freq_list(freq_list),
        n_directions=0,                 # 伴随不涉及方向数
        measurement_R=0.0,
        f_adj_hash=_sha256_file(f_adj_mat_path),
        forward_mat_hash=_sha256_file(forward_mat_path),
    )


class CacheManager:
    """缓存目录管理：lookup / store / clear。

    所有操作都是**幂等**的：
    - lookup 命中条件：缓存目录存在且包含 marker 文件
    - store 采用 tmp + rename 的原子写入
    """

    FORWARD_MARKER = "J_obs_data.mat"      # 命中正演缓存的充要文件
    ADJOINT_MARKER = "adjoint_field.mat"   # 命中伴随缓存的充要文件

    def __init__(self, cache_root: Optional[str] = None):
        if cache_root is None:
            cache_root = str(Path(__file__).parent / ".cache")
        self.cache_root = Path(cache_root)
        self.cache_root.mkdir(parents=True, exist_ok=True)

    def _entry_dir(self, key_hash: str) -> Path:
        return self.cache_root / key_hash

    def _forward_dir(self, key_hash: str) -> Path:
        return self._entry_dir(key_hash) / "forward"

    def _adjoint_dir(self, key_hash: str) -> Path:
        return self._entry_dir(key_hash) / "adjoint"

    # ------------------------------------------------------------------
    # lookup
    # ------------------------------------------------------------------
    def lookup_forward(self, key_hash: str) -> Optional[Path]:
        """命中则返回 forward 目录 Path，否则 None。"""
        fwd_dir = self._forward_dir(key_hash)
        if (fwd_dir / self.FORWARD_MARKER).is_file():
            return fwd_dir
        return None

    def lookup_adjoint(self, key_hash: str) -> Optional[Path]:
        adj_dir = self._adjoint_dir(key_hash)
        if (adj_dir / self.ADJOINT_MARKER).is_file():
            return adj_dir
        return None

    # ------------------------------------------------------------------
    # store（原子写入）
    # ------------------------------------------------------------------
    def store_forward(
        self,
        key: CacheKey,
        source_dir: str,
        snapshot_extras: Optional[Dict[str, Any]] = None,
    ) -> Path:
        """把 source_dir 下的正演产出原子写入缓存。"""
        key_hash = key.to_hash()
        target = self._forward_dir(key_hash)
        if target.exists():
            # 已存在（可能并发）——视作幂等成功
            return target

        # 验证 source_dir 有必需文件
        source = Path(source_dir)
        required = ["J_obs_data.mat"]
        for r in required:
            if not (source / r).is_file():
                raise FileNotFoundError(
                    f"Cannot store forward cache: missing {r} in {source_dir}"
                )

        # 写 input.json 快照（先写到 entry_dir）
        entry = self._entry_dir(key_hash)
        entry.mkdir(parents=True, exist_ok=True)
        snapshot = key.to_snapshot()
        if snapshot_extras:
            snapshot["extras"] = snapshot_extras
        snapshot["created_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
        (entry / "input.json").write_text(
            json.dumps(snapshot, indent=2, ensure_ascii=False), encoding="utf-8"
        )

        # 原子复制 forward 产出
        tmp_dir = entry / (".tmp_forward_" + key_hash)
        if tmp_dir.exists():
            shutil.rmtree(tmp_dir, ignore_errors=True)
        tmp_dir.mkdir(parents=True)

        for item in source.iterdir():
            if item.name.startswith("."):
                continue
            if item.is_file():
                shutil.copy2(item, tmp_dir / item.name)

        os.replace(str(tmp_dir), str(target))
        return target

    def store_adjoint(
        self,
        key: CacheKey,
        source_dir: str,
        snapshot_extras: Optional[Dict[str, Any]] = None,
    ) -> Path:
        """把 source_dir 下的伴随产出原子写入缓存。"""
        key_hash = key.to_hash()
        target = self._adjoint_dir(key_hash)
        if target.exists():
            return target

        source = Path(source_dir)
        if not (source / "adjoint_field.mat").is_file():
            raise FileNotFoundError(
                f"Cannot store adjoint cache: missing adjoint_field.mat in {source_dir}"
            )

        entry = self._entry_dir(key_hash)
        entry.mkdir(parents=True, exist_ok=True)
        # 复用或创建 input.json
        snapshot = key.to_snapshot()
        if snapshot_extras:
            snapshot["extras"] = snapshot_extras
        snapshot["created_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
        adj_snapshot_path = entry / "input_adjoint.json"
        adj_snapshot_path.write_text(
            json.dumps(snapshot, indent=2, ensure_ascii=False), encoding="utf-8"
        )

        tmp_dir = entry / (".tmp_adjoint_" + key_hash)
        if tmp_dir.exists():
            shutil.rmtree(tmp_dir, ignore_errors=True)
        tmp_dir.mkdir(parents=True)

        for item in source.iterdir():
            if item.name.startswith("."):
                continue
            if item.is_file():
                shutil.copy2(item, tmp_dir / item.name)

        os.replace(str(tmp_dir), str(target))
        return target

    # ------------------------------------------------------------------
    # clear
    # ------------------------------------------------------------------
    def clear(self, older_than_days: Optional[int] = None) -> int:
        """清缓存。

        Args:
            older_than_days: 仅清除早于 N 天的条目；None 表示全清。
        Returns:
            清除的条目数。
        """
        if not self.cache_root.exists():
            return 0

        count = 0
        now = time.time()
        for entry in self.cache_root.iterdir():
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            if older_than_days is not None:
                mtime = entry.stat().st_mtime
                age_days = (now - mtime) / 86400
                if age_days < older_than_days:
                    continue
            shutil.rmtree(entry, ignore_errors=True)
            count += 1
        return count

    def stats(self) -> Dict[str, int]:
        """返回缓存统计（条目数、总字节数）。"""
        if not self.cache_root.exists():
            return {"entries": 0, "total_bytes": 0}
        entries = 0
        total = 0
        for entry in self.cache_root.iterdir():
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            entries += 1
            for root, _, files in os.walk(entry):
                for f in files:
                    total += os.path.getsize(os.path.join(root, f))
        return {"entries": entries, "total_bytes": total}
