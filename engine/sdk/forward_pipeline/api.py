"""COMSOL Forward Pipeline SDK - Python API.

提供 ForwardPipeline 类，封装 MATLAB 子进程调用 + SHA-256 缓存。

使用示例
--------
    from engine.sdk.forward_pipeline.api import ForwardPipeline

    pipe = ForwardPipeline(
        comsol_server_path=r"C:\\Program Files\\COMSOL\\COMSOL62\\Multiphysics\\bin\\win64\\comsolmphserver.exe",
        mli_path=r"C:\\Program Files\\COMSOL\\COMSOL62\\Multiphysics\\mli",
        matlab_exe=r"D:\\LenovoSoftstore\\Install\\MATLAB\\R2023b\\bin\\matlab.exe",
    )

    result = pipe.solve_forward(
        eps_real_csv=r"C:\\path\\to\\eps_real.csv",
        eps_imag_csv=r"C:\\path\\to\\eps_imag.csv",
        freq_list=[0.8e9, 1.0e9],
        model_path=r"C:\\path\\to\\model.mph",
        output_dir=r"C:\\path\\to\\outputs",
    )
    print(result.status, result.mat_path, result.v5a_verdict)
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from engine.sdk.forward_pipeline.cache import (
    CacheManager,
    build_adjoint_key,
    build_forward_key,
)
from engine.sdk.forward_pipeline.matlab_runner import MatlabRunner, RunResult


# ----------------------------------------------------------------------
# Result dataclasses
# ----------------------------------------------------------------------
@dataclass
class ForwardResult:
    """solve_forward() 的返回值。"""

    status: str                          # 'success' / 'error' / 'cached'
    stage: str = ""                      # 失败阶段 tag（仅 error 时有意义）
    error_msg: str = ""
    mat_path: str = ""                   # J_obs_data.mat（绝对路径）
    json_path: str = ""                  # forward_dataset.json（绝对路径）
    v5a_verdict: str = ""                # 'pass' / 'fail' / 'skipped' / ''
    v5a_rel_error: float = 0.0
    cache_hit: bool = False
    duration_sec: float = 0.0
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class AdjointResult:
    """solve_adjoint() 的返回值。"""

    status: str                          # 'success' / 'error' / 'cached'
    stage: str = ""
    error_msg: str = ""
    adjoint_mat_path: str = ""
    cache_hit: bool = False
    duration_sec: float = 0.0
    metadata: Dict[str, Any] = field(default_factory=dict)


# ----------------------------------------------------------------------
# ForwardPipeline
# ----------------------------------------------------------------------
class ForwardPipeline:
    """COMSOL 频域电磁正演/伴随管线 SDK。

    生命周期：
    - 同一实例可多次调 solve_forward/solve_adjoint，共享缓存。
    - MATLAB 子进程每次 run 独立启停（COMSOL Server 可复用外部已起的实例）。

    缓存策略：
    - SHA-256 输入哈希；相同输入返回 cached 结果，不重跑 COMSOL。
    - 缓存位置：cache_root（默认 engine/sdk/forward_pipeline/.cache）。

    参数校验：
    - 必填路径在 solve_* 入口 fail-fast 检查。
    """

    def __init__(
        self,
        comsol_server_path: str,
        mli_path: str,
        matlab_exe: str = "matlab.exe",
        comsol_port: int = 2036,
        cache_root: Optional[str] = None,
        startup_timeout: int = 240,
        run_timeout: int = 1800,
    ):
        self.comsol_server_path = comsol_server_path
        self.mli_path = mli_path
        self.matlab_exe = matlab_exe
        self.comsol_port = int(comsol_port)
        self.startup_timeout = int(startup_timeout)
        self.run_timeout = int(run_timeout)

        self.cache = CacheManager(cache_root=cache_root)
        self.runner = MatlabRunner(matlab_exe=matlab_exe)

    # ------------------------------------------------------------------
    # solve_forward
    # ------------------------------------------------------------------
    def solve_forward(
        self,
        eps_real_csv: str,
        eps_imag_csv: str,
        freq_list: List[float],
        model_path: str,
        output_dir: str,
        n_directions: int = 64,
        measurement_R: float = 0.26,
        run_v5a: bool = True,
        tol: float = 0.05,
        phantom_type: str = "single_layer",
        use_cache: bool = True,
        timeout: Optional[int] = None,
    ) -> ForwardResult:
        """执行一次正演管线。

        Args:
            eps_real_csv: 介电常数实部 CSV 路径。
            eps_imag_csv: 介电常数虚部 CSV 路径（可空字符串）。
            freq_list: 频率列表 [Hz]，如 [0.8e9, 1.0e9]。
            model_path: COMSOL .mph 模型文件路径。
            output_dir: 输出目录（J_obs_data.mat 等会写到这里）。
            n_directions: Fibonacci 方向数，默认 64。
            measurement_R: 测量球面半径 [m]，默认 0.26。
            run_v5a: 是否运行 V5a 一致性检查，默认 True。
            tol: V5a 相对误差容限，默认 0.05（5%）。
            phantom_type: 仿体类型字符串，默认 'single_layer'。
            use_cache: 是否使用缓存，默认 True。
            timeout: 单次 run 超时秒数，None 用实例默认值。

        Returns:
            ForwardResult。
        """
        start_time = time.time()
        result = ForwardResult(status="error")

        # ----- 参数校验 -----
        err = self._validate_forward_inputs(
            eps_real_csv, eps_imag_csv, model_path, output_dir
        )
        if err:
            result.error_msg = err
            result.stage = "param_check"
            return result

        # ----- 构造缓存键 -----
        try:
            key = build_forward_key(
                eps_real_csv=eps_real_csv,
                eps_imag_csv=eps_imag_csv,
                freq_list=freq_list,
                model_path=model_path,
                n_directions=n_directions,
                measurement_R=measurement_R,
            )
        except FileNotFoundError as e:
            result.error_msg = str(e)
            result.stage = "key_build"
            return result

        key_hash = key.to_hash()

        # ----- 缓存命中检查 -----
        if use_cache:
            cached_dir = self.cache.lookup_forward(key_hash)
            if cached_dir is not None:
                return self._build_cached_forward_result(
                    cached_dir, key_hash, start_time
                )

        # ----- 准备工作目录 -----
        Path(output_dir).mkdir(parents=True, exist_ok=True)
        work_dir = Path(output_dir) / f".run_forward_{key_hash}"
        if work_dir.exists():
            shutil.rmtree(work_dir, ignore_errors=True)
        work_dir.mkdir(parents=True)

        # forward_solve 写散射场到这个 .mat（compute_jobs 读取）
        scatter_mat = str(work_dir / "forward_scattered_field.mat")
        mat_path = str(work_dir / "J_obs_data.mat")
        json_path = str(work_dir / "forward_dataset.json")

        # ----- 构造 params.json -----
        params = {
            "eps_real_csv": os.path.abspath(eps_real_csv),
            "eps_imag_csv": os.path.abspath(eps_imag_csv) if eps_imag_csv else "",
            "freq_list": list(freq_list),
            "model_path": os.path.abspath(model_path),
            "output_path": scatter_mat,
            "mat_path": mat_path,
            "json_path": json_path,
            "comsol_server_path": self.comsol_server_path,
            "mli_path": self.mli_path,
            "comsol_port": self.comsol_port,
            "comsol_startup_timeout": self.startup_timeout,
            "n_directions": int(n_directions),
            "measurement_R": float(measurement_R),
            "run_v5a": bool(run_v5a),
            "tol": float(tol),
            "phantom_type": phantom_type,
        }

        log_path = str(work_dir / "pipeline.log")

        # ----- 调用 MATLAB -----
        try:
            run_result = self.runner.run(
                entry_function="run_forward_pipeline",
                params=params,
                work_dir=str(work_dir),
                log_path=log_path,
                timeout=timeout or self.run_timeout,
            )
        except Exception as e:
            result.error_msg = f"Runner exception: {e}"
            result.stage = "runner"
            result.duration_sec = time.time() - start_time
            return result

        result.duration_sec = time.time() - start_time

        # ----- 处理结果 -----
        if run_result.exit_code != 0:
            result.stage = "matlab_failed"
            if run_result.timed_out:
                result.error_msg = f"MATLAB timed out after {run_result.duration_sec:.1f}s"
            else:
                result.error_msg = f"MATLAB exit_code={run_result.exit_code}. See log: {run_result.log_path}"
            return result

        # 验证产出文件
        if not os.path.isfile(mat_path):
            result.stage = "missing_mat"
            result.error_msg = f"MATLAB succeeded but {mat_path} not found"
            return result

        # 读取 v5a_result.json（如果存在）
        v5a_json_path = work_dir / "v5a_result.json"
        v5a_verdict = ""
        v5a_rel_error = 0.0
        if v5a_json_path.is_file():
            try:
                v5a = json.loads(v5a_json_path.read_text(encoding="utf-8"))
                if v5a.get("passed"):
                    v5a_verdict = "pass"
                elif v5a.get("status") == "skipped":
                    v5a_verdict = "skipped"
                else:
                    v5a_verdict = "fail"
                v5a_rel_error = float(v5a.get("rel_error", 0.0))
            except (json.JSONDecodeError, ValueError, OSError):
                v5a_verdict = ""
                v5a_rel_error = 0.0

        # ----- 写入缓存 -----
        if use_cache:
            try:
                cached = self.cache.store_forward(
                    key,
                    source_dir=str(work_dir),
                    snapshot_extras={
                        "phantom_type": phantom_type,
                        "run_v5a": run_v5a,
                        "tol": tol,
                    },
                )
                final_mat = str(cached / "J_obs_data.mat")
                final_json = str(cached / "forward_dataset.json")
            except Exception as e:
                # 缓存写入失败不影响主流程
                final_mat = mat_path
                final_json = json_path
        else:
            final_mat = mat_path
            final_json = json_path

        return ForwardResult(
            status="success",
            stage="done",
            mat_path=final_mat,
            json_path=final_json,
            v5a_verdict=v5a_verdict,
            v5a_rel_error=v5a_rel_error,
            cache_hit=False,
            duration_sec=result.duration_sec,
            metadata={
                "key_hash": key_hash,
                "work_dir": str(work_dir),
                "log_path": run_result.log_path,
            },
        )

    # ------------------------------------------------------------------
    # solve_adjoint
    # ------------------------------------------------------------------
    def solve_adjoint(
        self,
        forward_mat_path: str,
        f_adj_mat_path: str,
        voxel_positions_mat_path: str,
        freq_list: List[float],
        model_path: str,
        output_dir: str,
        use_cache: bool = True,
        timeout: Optional[int] = None,
    ) -> AdjointResult:
        """执行一次伴随管线。

        Args:
            forward_mat_path: 正演产出的 .mat 路径（含 LU 因子索引等）。
            f_adj_mat_path: 伴随源 .mat 路径，必须含变量 f_adj [n_voxel x 3] 复数。
            voxel_positions_mat_path: 体素位置 .mat，含 r_voxel 或 voxel_positions。
            freq_list: 频率列表 [Hz]。
            model_path: .mph 模型文件路径。
            output_dir: 输出目录。
            use_cache: 是否使用缓存。
            timeout: 单次 run 超时秒数。

        Returns:
            AdjointResult。
        """
        start_time = time.time()
        result = AdjointResult(status="error")

        # 参数校验
        err = self._validate_adjoint_inputs(
            forward_mat_path, f_adj_mat_path,
            voxel_positions_mat_path, model_path, output_dir,
        )
        if err:
            result.error_msg = err
            result.stage = "param_check"
            return result

        # 缓存键
        try:
            key = build_adjoint_key(
                forward_mat_path=forward_mat_path,
                f_adj_mat_path=f_adj_mat_path,
                voxel_positions_mat_path=voxel_positions_mat_path,
                freq_list=freq_list,
                model_path=model_path,
            )
        except FileNotFoundError as e:
            result.error_msg = str(e)
            result.stage = "key_build"
            return result

        key_hash = key.to_hash()

        if use_cache:
            cached_dir = self.cache.lookup_adjoint(key_hash)
            if cached_dir is not None:
                return self._build_cached_adjoint_result(
                    cached_dir, key_hash, start_time
                )

        Path(output_dir).mkdir(parents=True, exist_ok=True)
        work_dir = Path(output_dir) / f".run_adjoint_{key_hash}"
        if work_dir.exists():
            shutil.rmtree(work_dir, ignore_errors=True)
        work_dir.mkdir(parents=True)

        adjoint_mat = str(work_dir / "adjoint_field.mat")

        params = {
            "forward_mat_path": os.path.abspath(forward_mat_path),
            "f_adj_mat_path": os.path.abspath(f_adj_mat_path),
            "voxel_positions_mat_path": os.path.abspath(voxel_positions_mat_path),
            "freq_list": list(freq_list),
            "model_path": os.path.abspath(model_path),
            "output_path": adjoint_mat,
            "comsol_server_path": self.comsol_server_path,
            "mli_path": self.mli_path,
            "comsol_port": self.comsol_port,
            "comsol_startup_timeout": self.startup_timeout,
            "livelink_port": self.comsol_port,
        }
        log_path = str(work_dir / "pipeline.log")

        try:
            run_result = self.runner.run(
                entry_function="run_adjoint_pipeline",
                params=params,
                work_dir=str(work_dir),
                log_path=log_path,
                timeout=timeout or self.run_timeout,
            )
        except Exception as e:
            result.error_msg = f"Runner exception: {e}"
            result.stage = "runner"
            result.duration_sec = time.time() - start_time
            return result

        result.duration_sec = time.time() - start_time

        if run_result.exit_code != 0:
            result.stage = "matlab_failed"
            if run_result.timed_out:
                result.error_msg = f"MATLAB timed out after {run_result.duration_sec:.1f}s"
            else:
                result.error_msg = f"MATLAB exit_code={run_result.exit_code}. See log: {run_result.log_path}"
            return result

        if not os.path.isfile(adjoint_mat):
            result.stage = "missing_mat"
            result.error_msg = f"MATLAB succeeded but {adjoint_mat} not found"
            return result

        if use_cache:
            try:
                cached = self.cache.store_adjoint(
                    key,
                    source_dir=str(work_dir),
                    snapshot_extras={"freq_list": list(freq_list)},
                )
                final_mat = str(cached / "adjoint_field.mat")
            except Exception:
                final_mat = adjoint_mat
        else:
            final_mat = adjoint_mat

        return AdjointResult(
            status="success",
            stage="done",
            adjoint_mat_path=final_mat,
            cache_hit=False,
            duration_sec=result.duration_sec,
            metadata={
                "key_hash": key_hash,
                "work_dir": str(work_dir),
                "log_path": run_result.log_path,
            },
        )

    # ------------------------------------------------------------------
    # clear_cache
    # ------------------------------------------------------------------
    def clear_cache(self, older_than_days: Optional[int] = None) -> int:
        """清缓存。older_than_days=None 清全部。返回清除条目数。"""
        return self.cache.clear(older_than_days=older_than_days)

    def cache_stats(self) -> Dict[str, int]:
        """返回缓存统计。"""
        return self.cache.stats()

    # ==================================================================
    # 内部辅助方法
    # ==================================================================
    def _validate_forward_inputs(
        self,
        eps_real_csv: str,
        eps_imag_csv: str,
        model_path: str,
        output_dir: str,
    ) -> Optional[str]:
        """返回错误消息字符串，None 表示通过。"""
        if not eps_real_csv or not os.path.isfile(eps_real_csv):
            return f"eps_real_csv not found: {eps_real_csv!r}"
        if eps_imag_csv and not os.path.isfile(eps_imag_csv):
            return f"eps_imag_csv not found: {eps_imag_csv!r}"
        if not model_path or not os.path.isfile(model_path):
            return f"model_path not found: {model_path!r}"
        if not output_dir:
            return "output_dir is required"
        return None

    def _validate_adjoint_inputs(
        self,
        forward_mat_path: str,
        f_adj_mat_path: str,
        voxel_positions_mat_path: str,
        model_path: str,
        output_dir: str,
    ) -> Optional[str]:
        for label, p in [
            ("forward_mat_path", forward_mat_path),
            ("f_adj_mat_path", f_adj_mat_path),
            ("voxel_positions_mat_path", voxel_positions_mat_path),
            ("model_path", model_path),
        ]:
            if not p or not os.path.isfile(p):
                return f"{label} not found: {p!r}"
        if not output_dir:
            return "output_dir is required"
        return None

    def _build_cached_forward_result(
        self, cached_dir: Path, key_hash: str, start_time: float
    ) -> ForwardResult:
        """从缓存目录构造 ForwardResult。"""
        mat_path = cached_dir / "J_obs_data.mat"
        json_path = cached_dir / "forward_dataset.json"
        v5a_json = cached_dir / "v5a_result.json"

        v5a_verdict = ""
        v5a_rel_error = 0.0
        if v5a_json.is_file():
            try:
                v5a = json.loads(v5a_json.read_text(encoding="utf-8"))
                if v5a.get("passed"):
                    v5a_verdict = "pass"
                elif v5a.get("status") == "skipped":
                    v5a_verdict = "skipped"
                else:
                    v5a_verdict = "fail"
                v5a_rel_error = float(v5a.get("rel_error", 0.0))
            except (json.JSONDecodeError, ValueError, OSError):
                pass

        return ForwardResult(
            status="cached",
            stage="cache_hit",
            mat_path=str(mat_path),
            json_path=str(json_path) if json_path.is_file() else "",
            v5a_verdict=v5a_verdict,
            v5a_rel_error=v5a_rel_error,
            cache_hit=True,
            duration_sec=time.time() - start_time,
            metadata={"key_hash": key_hash, "source": "cache"},
        )

    def _build_cached_adjoint_result(
        self, cached_dir: Path, key_hash: str, start_time: float
    ) -> AdjointResult:
        return AdjointResult(
            status="cached",
            stage="cache_hit",
            adjoint_mat_path=str(cached_dir / "adjoint_field.mat"),
            cache_hit=True,
            duration_sec=time.time() - start_time,
            metadata={"key_hash": key_hash, "source": "cache"},
        )
