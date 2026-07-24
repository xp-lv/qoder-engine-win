"""cache.py 的单元测试（纯 Python，无外部依赖）。"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

import pytest

from engine.sdk.forward_pipeline.cache import (
    SDK_VERSION,
    CacheManager,
    build_adjoint_key,
    build_forward_key,
)


# ----------------------------------------------------------------------
# fixtures
# ----------------------------------------------------------------------
@pytest.fixture
def tmp_workspace(tmp_path):
    """构造一个临时工作区，含正演/伴随所需的输入文件。"""
    eps_real = tmp_path / "eps_real.csv"
    eps_real.write_text("0,0,0,1.0\n0.1,0,0,2.5\n", encoding="ascii")

    eps_imag = tmp_path / "eps_imag.csv"
    eps_imag.write_text("0,0,0,0.0\n0.1,0,0,0.1\n", encoding="ascii")

    model = tmp_path / "model.mph"
    model.write_bytes(b"FAKE_MPH_CONTENT_v1")

    f_adj = tmp_path / "f_adj.mat"
    f_adj.write_bytes(b"FAKE_F_ADJ_v1")

    forward_mat = tmp_path / "forward_out.mat"
    forward_mat.write_bytes(b"FAKE_FORWARD_OUT_v1")

    voxel_mat = tmp_path / "voxel.mat"
    voxel_mat.write_bytes(b"FAKE_VOXEL_v1")

    cache_root = tmp_path / ".cache"
    return {
        "root": tmp_path,
        "eps_real": str(eps_real),
        "eps_imag": str(eps_imag),
        "model": str(model),
        "f_adj": str(f_adj),
        "forward_mat": str(forward_mat),
        "voxel_mat": str(voxel_mat),
        "cache_root": str(cache_root),
    }


# ----------------------------------------------------------------------
# CacheKey 哈希一致性
# ----------------------------------------------------------------------
class TestForwardKeyConsistency:
    def test_same_inputs_same_hash(self, tmp_workspace):
        kwargs = dict(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv=tmp_workspace["eps_imag"],
            freq_list=[0.8e9, 1.0e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        k1 = build_forward_key(**kwargs)
        k2 = build_forward_key(**kwargs)
        assert k1.to_hash() == k2.to_hash(), "identical inputs must hash equally"

    def test_eps_real_content_change_invalidates(self, tmp_workspace):
        k1 = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv=tmp_workspace["eps_imag"],
            freq_list=[0.8e9, 1.0e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        # 改 eps_real 内容
        Path(tmp_workspace["eps_real"]).write_text("0,0,0,9.9\n", encoding="ascii")
        k2 = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv=tmp_workspace["eps_imag"],
            freq_list=[0.8e9, 1.0e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        assert k1.to_hash() != k2.to_hash(), "content change must invalidate hash"

    def test_freq_list_order_matters(self, tmp_workspace):
        # freq_list 是有序的——顺序不同视为不同输入
        k1 = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv=tmp_workspace["eps_imag"],
            freq_list=[0.8e9, 1.0e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        k2 = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv=tmp_workspace["eps_imag"],
            freq_list=[1.0e9, 0.8e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        assert k1.to_hash() != k2.to_hash()

    def test_n_directions_change_invalidates(self, tmp_workspace):
        common = dict(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv=tmp_workspace["eps_imag"],
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            measurement_R=0.26,
        )
        k1 = build_forward_key(n_directions=64, **common)
        k2 = build_forward_key(n_directions=128, **common)
        assert k1.to_hash() != k2.to_hash()

    def test_missing_eps_real_raises(self, tmp_workspace):
        with pytest.raises(FileNotFoundError):
            build_forward_key(
                eps_real_csv=str(tmp_workspace["root"] / "nonexistent.csv"),
                eps_imag_csv=tmp_workspace["eps_imag"],
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                n_directions=64,
                measurement_R=0.26,
            )

    def test_missing_model_raises(self, tmp_workspace):
        with pytest.raises(FileNotFoundError):
            build_forward_key(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv=tmp_workspace["eps_imag"],
                freq_list=[0.8e9],
                model_path=str(tmp_workspace["root"] / "no.mph"),
                n_directions=64,
                measurement_R=0.26,
            )

    def test_eps_imag_optional(self, tmp_workspace):
        """eps_imag_csv 为空字符串时仍可哈希。"""
        k = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        assert len(k.to_hash()) == 16
        assert k.eps_imag_hash == ""


class TestAdjointKeyConsistency:
    def test_same_inputs_same_hash(self, tmp_workspace):
        common = dict(
            forward_mat_path=tmp_workspace["forward_mat"],
            voxel_positions_mat_path=tmp_workspace["voxel_mat"],
            freq_list=[0.8e9, 1.0e9],
            model_path=tmp_workspace["model"],
        )
        k1 = build_adjoint_key(f_adj_mat_path=tmp_workspace["f_adj"], **common)
        k2 = build_adjoint_key(f_adj_mat_path=tmp_workspace["f_adj"], **common)
        assert k1.to_hash() == k2.to_hash()

    def test_f_adj_change_invalidates(self, tmp_workspace):
        common = dict(
            forward_mat_path=tmp_workspace["forward_mat"],
            voxel_positions_mat_path=tmp_workspace["voxel_mat"],
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
        )
        k1 = build_adjoint_key(f_adj_mat_path=tmp_workspace["f_adj"], **common)
        Path(tmp_workspace["f_adj"]).write_bytes(b"DIFFERENT_F_ADJ")
        k2 = build_adjoint_key(f_adj_mat_path=tmp_workspace["f_adj"], **common)
        assert k1.to_hash() != k2.to_hash()


# ----------------------------------------------------------------------
# SDK_VERSION 强制失效
# ----------------------------------------------------------------------
class TestSdkVersionInvalidation:
    def test_sdk_version_in_hash(self, tmp_workspace):
        """SDK_VERSION 变化应使哈希变化（通过 monkeypatch 模拟）。"""
        import engine.sdk.forward_pipeline.cache as cache_mod

        original = cache_mod.SDK_VERSION
        try:
            cache_mod.SDK_VERSION = "1.0.0"
            k1 = build_forward_key(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                n_directions=64,
                measurement_R=0.26,
            )
            cache_mod.SDK_VERSION = "2.0.0"
            k2 = build_forward_key(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                n_directions=64,
                measurement_R=0.26,
            )
            assert k1.to_hash() != k2.to_hash()
        finally:
            cache_mod.SDK_VERSION = original


# ----------------------------------------------------------------------
# CacheManager lookup/store/clear
# ----------------------------------------------------------------------
class TestCacheManager:
    def test_store_and_lookup_forward(self, tmp_workspace):
        cm = CacheManager(cache_root=tmp_workspace["cache_root"])
        key = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )

        # 先 lookup：未命中
        assert cm.lookup_forward(key.to_hash()) is None

        # 构造一个 source_dir 模拟 MATLAB 产出
        src = tmp_workspace["root"] / "run_output"
        src.mkdir()
        (src / "J_obs_data.mat").write_bytes(b"JOB_DATA")
        (src / "forward_dataset.json").write_text("{}")
        (src / "v5a_result.json").write_text('{"passed": true}')

        target = cm.store_forward(key, str(src))
        assert target.exists()
        assert (target / "J_obs_data.mat").is_file()

        # 再次 lookup：命中
        hit = cm.lookup_forward(key.to_hash())
        assert hit is not None
        assert (hit / "J_obs_data.mat").is_file()

    def test_store_forward_missing_marker_raises(self, tmp_workspace):
        cm = CacheManager(cache_root=tmp_workspace["cache_root"])
        key = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        src = tmp_workspace["root"] / "bad_output"
        src.mkdir()
        # 不放 J_obs_data.mat
        (src / "other.txt").write_text("x")
        with pytest.raises(FileNotFoundError):
            cm.store_forward(key, str(src))

    def test_store_and_lookup_adjoint(self, tmp_workspace):
        cm = CacheManager(cache_root=tmp_workspace["cache_root"])
        key = build_adjoint_key(
            forward_mat_path=tmp_workspace["forward_mat"],
            f_adj_mat_path=tmp_workspace["f_adj"],
            voxel_positions_mat_path=tmp_workspace["voxel_mat"],
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
        )

        assert cm.lookup_adjoint(key.to_hash()) is None

        src = tmp_workspace["root"] / "adj_output"
        src.mkdir()
        (src / "adjoint_field.mat").write_bytes(b"LAMBDA")

        target = cm.store_adjoint(key, str(src))
        assert target.exists()

        hit = cm.lookup_adjoint(key.to_hash())
        assert hit is not None
        assert (hit / "adjoint_field.mat").is_file()

    def test_store_is_idempotent(self, tmp_workspace):
        """对同一 key 多次 store 不报错。"""
        cm = CacheManager(cache_root=tmp_workspace["cache_root"])
        key = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        src = tmp_workspace["root"] / "src"
        src.mkdir()
        (src / "J_obs_data.mat").write_bytes(b"X")

        t1 = cm.store_forward(key, str(src))
        t2 = cm.store_forward(key, str(src))
        assert t1 == t2

    def test_clear_all(self, tmp_workspace):
        cm = CacheManager(cache_root=tmp_workspace["cache_root"])
        key = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        src = tmp_workspace["root"] / "src"
        src.mkdir()
        (src / "J_obs_data.mat").write_bytes(b"X")
        cm.store_forward(key, str(src))

        n = cm.clear()
        assert n == 1
        assert cm.lookup_forward(key.to_hash()) is None

    def test_clear_respects_age(self, tmp_workspace):
        """older_than_days 参数应只清旧条目。"""
        import time as time_mod

        cm = CacheManager(cache_root=tmp_workspace["cache_root"])
        key = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        src = tmp_workspace["root"] / "src"
        src.mkdir()
        (src / "J_obs_data.mat").write_bytes(b"X")
        cm.store_forward(key, str(src))

        # 把缓存条目的 mtime 改到 10 天前
        entry_dir = cm.cache_root / key.to_hash()
        old_time = time_mod.time() - 10 * 86400
        os.utime(entry_dir, (old_time, old_time))

        # older_than_days=5 → 应清除（10 > 5）
        assert cm.clear(older_than_days=5) == 1
        # 再清一次应该没东西
        assert cm.clear(older_than_days=5) == 0

    def test_stats(self, tmp_workspace):
        cm = CacheManager(cache_root=tmp_workspace["cache_root"])
        assert cm.stats()["entries"] == 0

        key = build_forward_key(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            n_directions=64,
            measurement_R=0.26,
        )
        src = tmp_workspace["root"] / "src"
        src.mkdir()
        (src / "J_obs_data.mat").write_bytes(b"X" * 100)
        cm.store_forward(key, str(src))

        s = cm.stats()
        assert s["entries"] == 1
        assert s["total_bytes"] > 0


# ----------------------------------------------------------------------
# 默认 cache_root 路径
# ----------------------------------------------------------------------
class TestDefaultCacheRoot:
    def test_default_cache_root_is_under_sdk(self):
        """未指定 cache_root 时，默认在 forward_pipeline/.cache 下。"""
        from pathlib import Path
        import engine.sdk.forward_pipeline.cache as cache_mod

        cm = CacheManager()
        expected_parent = Path(cache_mod.__file__).parent / ".cache"
        assert Path(cm.cache_root) == expected_parent
