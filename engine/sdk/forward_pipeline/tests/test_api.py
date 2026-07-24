"""api.py 的单元测试（mock MatlabRunner，无需真实 COMSOL/MATLAB）。"""

from __future__ import annotations

import json
import os
from pathlib import Path
from unittest import mock

import pytest

from engine.sdk.forward_pipeline.api import (
    AdjointResult,
    ForwardPipeline,
    ForwardResult,
)
from engine.sdk.forward_pipeline.matlab_runner import RunResult


# ----------------------------------------------------------------------
# fixtures
# ----------------------------------------------------------------------
@pytest.fixture
def tmp_workspace(tmp_path):
    """构造一个临时工作区，含所有输入文件。"""
    eps_real = tmp_path / "eps_real.csv"
    eps_real.write_text("0,0,0,1.0\n0.1,0,0,2.5\n", encoding="ascii")

    eps_imag = tmp_path / "eps_imag.csv"
    eps_imag.write_text("0,0,0,0.0\n0.1,0,0,0.1\n", encoding="ascii")

    model = tmp_path / "model.mph"
    model.write_bytes(b"FAKE_MPH_v1")

    f_adj = tmp_path / "f_adj.mat"
    f_adj.write_bytes(b"FAKE_FADJ")

    forward_mat = tmp_path / "forward_out.mat"
    forward_mat.write_bytes(b"FAKE_FWD_OUT")

    voxel_mat = tmp_path / "voxel.mat"
    voxel_mat.write_bytes(b"FAKE_VOXEL")

    output_dir = tmp_path / "outputs"
    output_dir.mkdir()

    cache_root = tmp_path / ".cache"

    return {
        "root": tmp_path,
        "eps_real": str(eps_real),
        "eps_imag": str(eps_imag),
        "model": str(model),
        "f_adj": str(f_adj),
        "forward_mat": str(forward_mat),
        "voxel_mat": str(voxel_mat),
        "output_dir": str(output_dir),
        "cache_root": str(cache_root),
    }


def _make_pipeline(tmp_workspace) -> ForwardPipeline:
    return ForwardPipeline(
        comsol_server_path="C:/fake/comsolmphserver.exe",
        mli_path="C:/fake/mli",
        matlab_exe="matlab.exe",
        cache_root=tmp_workspace["cache_root"],
    )


def _make_fake_run_result_success(work_dir: str) -> RunResult:
    """模拟 MATLAB 成功运行：在工作目录里写入产出 + exit.flag=0。"""
    work_path = Path(work_dir)
    work_path.mkdir(parents=True, exist_ok=True)
    # MATLAB 写的产出文件
    (work_path / "J_obs_data.mat").write_bytes(b"JOB_DATA")
    (work_path / "forward_dataset.json").write_text('{"phantom_type": "single_layer"}')
    v5a = {"passed": True, "rel_error": 0.03, "status": "success", "tol": 0.05}
    (work_path / "v5a_result.json").write_text(json.dumps(v5a))
    # exit.flag
    (work_path / "exit.flag").write_text("0\n", encoding="ascii")
    return RunResult(
        exit_code=0,
        timed_out=False,
        stdout="",
        stderr="",
        log_path=str(work_path / "pipeline.log"),
        work_dir=work_dir,
        duration_sec=1.0,
    )


# ----------------------------------------------------------------------
# 参数校验
# ----------------------------------------------------------------------
class TestForwardValidation:
    def test_missing_eps_real(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)
        result = pipe.solve_forward(
            eps_real_csv="/nonexistent.csv",
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            output_dir=tmp_workspace["output_dir"],
        )
        assert result.status == "error"
        assert result.stage == "param_check"
        assert "eps_real_csv" in result.error_msg

    def test_missing_model(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)
        result = pipe.solve_forward(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path="/nonexistent.mph",
            output_dir=tmp_workspace["output_dir"],
        )
        assert result.status == "error"
        assert "model_path" in result.error_msg

    def test_missing_output_dir(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)
        result = pipe.solve_forward(
            eps_real_csv=tmp_workspace["eps_real"],
            eps_imag_csv="",
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            output_dir="",
        )
        assert result.status == "error"
        assert "output_dir" in result.error_msg


class TestAdjointValidation:
    def test_missing_forward_mat(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)
        result = pipe.solve_adjoint(
            forward_mat_path="/no.mat",
            f_adj_mat_path=tmp_workspace["f_adj"],
            voxel_positions_mat_path=tmp_workspace["voxel_mat"],
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            output_dir=tmp_workspace["output_dir"],
        )
        assert result.status == "error"
        assert "forward_mat_path" in result.error_msg

    def test_missing_f_adj(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)
        result = pipe.solve_adjoint(
            forward_mat_path=tmp_workspace["forward_mat"],
            f_adj_mat_path="/no.mat",
            voxel_positions_mat_path=tmp_workspace["voxel_mat"],
            freq_list=[0.8e9],
            model_path=tmp_workspace["model"],
            output_dir=tmp_workspace["output_dir"],
        )
        assert result.status == "error"
        assert "f_adj_mat_path" in result.error_msg


# ----------------------------------------------------------------------
# 缓存命中分支
# ----------------------------------------------------------------------
class TestCacheHit:
    def test_forward_cache_hit_after_store(self, tmp_workspace):
        """先跑一次（mock runner），第二次应 cache_hit。"""
        pipe = _make_pipeline(tmp_workspace)

        # Mock runner.run 写产出 + 返回 success
        call_count = {"n": 0}
        def fake_run(*args, **kwargs):
            call_count["n"] += 1
            work_dir = kwargs.get("work_dir") or args[2]
            return _make_fake_run_result_success(work_dir)

        with mock.patch.object(pipe.runner, "run", side_effect=fake_run):
            r1 = pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
            assert r1.status == "success"
            assert r1.cache_hit is False
            assert r1.v5a_verdict == "pass"
            assert r1.v5a_rel_error == 0.03

            # 第二次：应该 cache hit
            r2 = pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
            assert r2.status == "cached"
            assert r2.cache_hit is True
            # runner 只应被调一次
            assert call_count["n"] == 1

    def test_use_cache_false_skips_lookup(self, tmp_workspace):
        """use_cache=False 时不应查询缓存。"""
        pipe = _make_pipeline(tmp_workspace)

        # 预填充缓存
        def fake_run(*args, **kwargs):
            work_dir = kwargs.get("work_dir") or args[2]
            return _make_fake_run_result_success(work_dir)

        with mock.patch.object(pipe.runner, "run", side_effect=fake_run):
            pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )

            # 第二次 use_cache=False 应该重新调 runner
            call_count = {"n": 0}
            def counting_run(*args, **kwargs):
                call_count["n"] += 1
                work_dir = kwargs.get("work_dir") or args[2]
                return _make_fake_run_result_success(work_dir)

            with mock.patch.object(pipe.runner, "run", side_effect=counting_run):
                r = pipe.solve_forward(
                    eps_real_csv=tmp_workspace["eps_real"],
                    eps_imag_csv="",
                    freq_list=[0.8e9],
                    model_path=tmp_workspace["model"],
                    output_dir=tmp_workspace["output_dir"],
                    use_cache=False,
                )
                assert r.status == "success"
                assert r.cache_hit is False
                assert call_count["n"] == 1


# ----------------------------------------------------------------------
# 失败分支
# ----------------------------------------------------------------------
class TestFailurePaths:
    def test_matlab_nonzero_exit(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)

        def fake_run(*args, **kwargs):
            work_dir = kwargs.get("work_dir") or args[2]
            Path(work_dir).mkdir(parents=True, exist_ok=True)
            (Path(work_dir) / "exit.flag").write_text("1\n", encoding="ascii")
            return RunResult(
                exit_code=1, timed_out=False, stdout="", stderr="error",
                log_path=str(Path(work_dir) / "pipeline.log"),
                work_dir=work_dir, duration_sec=0.1,
            )

        with mock.patch.object(pipe.runner, "run", side_effect=fake_run):
            r = pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
        assert r.status == "error"
        assert r.stage == "matlab_failed"
        assert "exit_code=1" in r.error_msg

    def test_matlab_timeout(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)

        def fake_run(*args, **kwargs):
            work_dir = kwargs.get("work_dir") or args[2]
            return RunResult(
                exit_code=124, timed_out=True, stdout="", stderr="",
                log_path=str(Path(work_dir) / "pipeline.log"),
                work_dir=work_dir, duration_sec=999.0,
            )

        with mock.patch.object(pipe.runner, "run", side_effect=fake_run):
            r = pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
        assert r.status == "error"
        assert r.stage == "matlab_failed"
        assert "timed out" in r.error_msg

    def test_runner_exception(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)

        with mock.patch.object(
            pipe.runner, "run", side_effect=Exception("subprocess failed")
        ):
            r = pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
        assert r.status == "error"
        assert r.stage == "runner"

    def test_matlab_succeeded_but_mat_missing(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)

        def fake_run(*args, **kwargs):
            work_dir = kwargs.get("work_dir") or args[2]
            Path(work_dir).mkdir(parents=True, exist_ok=True)
            # 不写 J_obs_data.mat
            (Path(work_dir) / "exit.flag").write_text("0\n", encoding="ascii")
            return RunResult(
                exit_code=0, timed_out=False, stdout="", stderr="",
                log_path=str(Path(work_dir) / "pipeline.log"),
                work_dir=work_dir, duration_sec=0.1,
            )

        with mock.patch.object(pipe.runner, "run", side_effect=fake_run):
            r = pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
        assert r.status == "error"
        assert r.stage == "missing_mat"


# ----------------------------------------------------------------------
# 缓存内容变化导致失效
# ----------------------------------------------------------------------
class TestCacheInvalidation:
    def test_eps_real_change_invalidates(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)

        call_count = {"n": 0}
        def counting_run(*args, **kwargs):
            call_count["n"] += 1
            work_dir = kwargs.get("work_dir") or args[2]
            return _make_fake_run_result_success(work_dir)

        with mock.patch.object(pipe.runner, "run", side_effect=counting_run):
            # 第一次
            pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
            # 改 eps_real 内容
            Path(tmp_workspace["eps_real"]).write_text("0,0,0,9.9\n", encoding="ascii")
            # 第二次应重新跑
            pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
        assert call_count["n"] == 2


# ----------------------------------------------------------------------
# Adjoint 完整路径
# ----------------------------------------------------------------------
class TestAdjointFull:
    def test_adjoint_success_and_cache(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)

        call_count = {"n": 0}
        def fake_run(*args, **kwargs):
            call_count["n"] += 1
            work_dir = kwargs.get("work_dir") or args[2]
            Path(work_dir).mkdir(parents=True, exist_ok=True)
            (Path(work_dir) / "adjoint_field.mat").write_bytes(b"LAMBDA")
            (Path(work_dir) / "exit.flag").write_text("0\n", encoding="ascii")
            return RunResult(
                exit_code=0, timed_out=False, stdout="", stderr="",
                log_path=str(Path(work_dir) / "pipeline.log"),
                work_dir=work_dir, duration_sec=1.0,
            )

        with mock.patch.object(pipe.runner, "run", side_effect=fake_run):
            r1 = pipe.solve_adjoint(
                forward_mat_path=tmp_workspace["forward_mat"],
                f_adj_mat_path=tmp_workspace["f_adj"],
                voxel_positions_mat_path=tmp_workspace["voxel_mat"],
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
            assert r1.status == "success"
            assert r1.cache_hit is False
            assert os.path.isfile(r1.adjoint_mat_path)

            # 第二次应 cache hit
            r2 = pipe.solve_adjoint(
                forward_mat_path=tmp_workspace["forward_mat"],
                f_adj_mat_path=tmp_workspace["f_adj"],
                voxel_positions_mat_path=tmp_workspace["voxel_mat"],
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )
            assert r2.status == "cached"
            assert r2.cache_hit is True
            assert call_count["n"] == 1


# ----------------------------------------------------------------------
# clear_cache / cache_stats
# ----------------------------------------------------------------------
class TestCacheManagement:
    def test_clear_cache(self, tmp_workspace):
        pipe = _make_pipeline(tmp_workspace)

        def fake_run(*args, **kwargs):
            work_dir = kwargs.get("work_dir") or args[2]
            return _make_fake_run_result_success(work_dir)

        with mock.patch.object(pipe.runner, "run", side_effect=fake_run):
            pipe.solve_forward(
                eps_real_csv=tmp_workspace["eps_real"],
                eps_imag_csv="",
                freq_list=[0.8e9],
                model_path=tmp_workspace["model"],
                output_dir=tmp_workspace["output_dir"],
            )

        stats = pipe.cache_stats()
        assert stats["entries"] == 1
        n = pipe.clear_cache()
        assert n == 1
        assert pipe.cache_stats()["entries"] == 0


# ----------------------------------------------------------------------
# 包导入
# ----------------------------------------------------------------------
class TestPackageImports:
    def test_import_from_package(self):
        from engine.sdk.forward_pipeline import (
            SDK_VERSION,
            AdjointResult,
            ForwardPipeline,
            ForwardResult,
        )
        assert isinstance(SDK_VERSION, str)
        assert ForwardPipeline is not None
        assert ForwardResult is not None
        assert AdjointResult is not None
