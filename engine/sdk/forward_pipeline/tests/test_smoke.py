"""端到端冒烟测试（@slow，需真实 COMSOL/MATLAB 环境）。

默认不在 CI 中运行。手动执行：

    set PYTHONPATH=.
    python -m pytest engine/sdk/forward_pipeline/tests/test_smoke.py -v -m slow

前置条件：
    1. MATLAB R2023b 已安装，matlab.exe 在 PATH 或路径已知
    2. COMSOL 6.2 已安装，comsolmphserver.exe 路径已知
    3. LiveLink for MATLAB 已启用
    4. 物理内存 >= 32 GB
    5. 准备好一个 .mph 模型文件 + eps_real.csv / eps_imag.csv 输入

可通过环境变量覆盖默认路径：
    PIPELINE_MATLAB_EXE
    PIPELINE_COMSOL_SERVER
    PIPELINE_MLI_PATH
    PIPELINE_MODEL_PATH
    PIPELINE_EPS_REAL_CSV
    PIPELINE_EPS_IMAG_CSV
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest

slow = pytest.mark.slow
skip_no_env = pytest.mark.skipif(
    not all([
        os.environ.get("PIPELINE_MATLAB_EXE"),
        os.environ.get("PIPELINE_COMSOL_SERVER"),
        os.environ.get("PIPELINE_MLI_PATH"),
        os.environ.get("PIPELINE_MODEL_PATH"),
        os.environ.get("PIPELINE_EPS_REAL_CSV"),
    ]),
    reason="Set PIPELINE_* env vars to run smoke tests (requires real COMSOL)",
)


@pytest.fixture
def smoke_pipeline(tmp_path):
    """构造一个指向真实 COMSOL/MATLAB 的 ForwardPipeline 实例。"""
    from engine.sdk.forward_pipeline import ForwardPipeline

    return ForwardPipeline(
        comsol_server_path=os.environ["PIPELINE_COMSOL_SERVER"],
        mli_path=os.environ["PIPELINE_MLI_PATH"],
        matlab_exe=os.environ["PIPELINE_MATLAB_EXE"],
        comsol_port=int(os.environ.get("PIPELINE_COMSOL_PORT", "2036")),
        cache_root=str(tmp_path / ".cache"),
        startup_timeout=int(os.environ.get("PIPELINE_STARTUP_TIMEOUT", "240")),
        run_timeout=int(os.environ.get("PIPELINE_RUN_TIMEOUT", "1800")),
    )


@slow
@skip_no_env
class TestSmokeForward:
    """正演管线端到端冒烟。"""

    def test_first_run_success(self, smoke_pipeline, tmp_path):
        """第一次跑应 success，第二次应 cached。"""
        output_dir = tmp_path / "outputs"
        output_dir.mkdir()

        eps_imag = os.environ.get("PIPELINE_EPS_IMAG_CSV", "")

        r1 = smoke_pipeline.solve_forward(
            eps_real_csv=os.environ["PIPELINE_EPS_REAL_CSV"],
            eps_imag_csv=eps_imag,
            freq_list=[0.8e9, 1.0e9],
            model_path=os.environ["PIPELINE_MODEL_PATH"],
            output_dir=str(output_dir),
            n_directions=64,
            measurement_R=0.26,
            run_v5a=True,
            tol=0.05,
        )

        assert r1.status == "success", f"First run failed: {r1.error_msg}"
        assert r1.cache_hit is False
        assert r1.mat_path and Path(r1.mat_path).is_file()
        assert r1.duration_sec > 0

        # 第二次应 cache hit
        r2 = smoke_pipeline.solve_forward(
            eps_real_csv=os.environ["PIPELINE_EPS_REAL_CSV"],
            eps_imag_csv=eps_imag,
            freq_list=[0.8e9, 1.0e9],
            model_path=os.environ["PIPELINE_MODEL_PATH"],
            output_dir=str(output_dir),
            n_directions=64,
            measurement_R=0.26,
            run_v5a=True,
            tol=0.05,
        )
        assert r2.status == "cached"
        assert r2.cache_hit is True
        assert r2.mat_path and Path(r2.mat_path).is_file()

    def test_cache_invalidation_on_model_change(self, smoke_pipeline, tmp_path):
        """model_path 内容变化时应使缓存失效。

        注：本测试需要一个可修改的 .mph 文件副本。如果原文件不可写，
        可手动准备两个不同的 .mph。
        """
        if not os.environ.get("PIPELINE_MODEL_PATH_2"):
            pytest.skip("Set PIPELINE_MODEL_PATH_2 to test model-change invalidation")

        output_dir = tmp_path / "outputs_inv"
        output_dir.mkdir()

        eps_imag = os.environ.get("PIPELINE_EPS_IMAG_CSV", "")

        # 用 model 1
        r1 = smoke_pipeline.solve_forward(
            eps_real_csv=os.environ["PIPELINE_EPS_REAL_CSV"],
            eps_imag_csv=eps_imag,
            freq_list=[0.8e9],
            model_path=os.environ["PIPELINE_MODEL_PATH"],
            output_dir=str(output_dir),
        )
        assert r1.status in ("success", "cached")

        # 用 model 2（不同内容）→ 应重新跑
        r2 = smoke_pipeline.solve_forward(
            eps_real_csv=os.environ["PIPELINE_EPS_REAL_CSV"],
            eps_imag_csv=eps_imag,
            freq_list=[0.8e9],
            model_path=os.environ["PIPELINE_MODEL_PATH_2"],
            output_dir=str(output_dir),
        )
        assert r2.status == "success", f"Second model run failed: {r2.error_msg}"
        assert r2.cache_hit is False


@slow
@skip_no_env
class TestSmokeAdjoint:
    """伴随管线端到端冒烟。

    前置：需要先跑过正演，把 J_obs_data.mat 路径通过 PIPELINE_FORWARD_MAT 传入。
    还需要构造 f_adj.mat（含变量 f_adj）和 voxel_positions.mat（含 r_voxel）。
    """

    def test_adjoint_runs(self, smoke_pipeline, tmp_path):
        forward_mat = os.environ.get("PIPELINE_FORWARD_MAT")
        f_adj_mat = os.environ.get("PIPELINE_F_ADJ_MAT")
        voxel_mat = os.environ.get("PIPELINE_VOXEL_MAT")

        if not all([forward_mat, f_adj_mat, voxel_mat]):
            pytest.skip("Set PIPELINE_FORWARD_MAT / PIPELINE_F_ADJ_MAT / PIPELINE_VOXEL_MAT")

        output_dir = tmp_path / "adjoint_outputs"
        output_dir.mkdir()

        r = smoke_pipeline.solve_adjoint(
            forward_mat_path=forward_mat,
            f_adj_mat_path=f_adj_mat,
            voxel_positions_mat_path=voxel_mat,
            freq_list=[0.8e9, 1.0e9],
            model_path=os.environ["PIPELINE_MODEL_PATH"],
            output_dir=str(output_dir),
        )

        assert r.status == "success", f"Adjoint failed: {r.error_msg}"
        assert r.adjoint_mat_path and Path(r.adjoint_mat_path).is_file()
