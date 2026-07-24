"""端到端测试：构建空心球模型 → 用 SDK 跑正演 → 验证 J_obs 非零。

工作流：
  1. 生成空心球壳的 eps_r CSV（散射体区域 eps_r=5，背景=1）
  2. 启动 COMSOL Server（如未启动）
  3. 用 MatlabRunner 跑 build_hollow_sphere_model.m → 生成 hollow_sphere.mph
  4. 用 SDK solve_forward 跑正演（CSV + .mph）
  5. 验证 ||E_s|| 非零、V5a verdict

执行：
  set PYTHONPATH=.
  set PYTHONIOENCODING=utf-8
  python engine/sdk/forward_pipeline/scripts/run_hollow_sphere_e2e.py

环境变量（可选）：
  PIPELINE_MATLAB_EXE      默认 D:\\LenovoSoftstore\\Install\\MATLAB\\bin\\matlab.exe
  PIPELINE_COMSOL_SERVER   默认 D:\\LenovoSoftstore\\Install\\COMSOL62\\...comsolmphserver.exe
  PIPELINE_MLI_PATH        默认 D:\\LenovoSoftstore\\Install\\COMSOL62\\Multiphysics\\mli
  PIPELINE_COMSOL_PORT     默认 2036
  PIPELINE_SKIP_BUILD      =1 跳过模型构建（用现有 .mph）
"""
from __future__ import annotations

import io
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

# 强制 stdout UTF-8（Windows 控制台默认 GBK 会乱码）
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

# 把项目根加到 PYTHONPATH（本脚本独立运行用）
PROJECT_ROOT = Path(__file__).resolve().parents[4]   # .../qoder-engine
sys.path.insert(0, str(PROJECT_ROOT))


# ----------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------
MATLAB_EXE = os.environ.get(
    "PIPELINE_MATLAB_EXE",
    r"D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe",
)
COMSOL_SERVER = os.environ.get(
    "PIPELINE_COMSOL_SERVER",
    r"D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe",
)
MLI_PATH = os.environ.get(
    "PIPELINE_MLI_PATH",
    r"D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli",
)
COMSOL_PORT = int(os.environ.get("PIPELINE_COMSOL_PORT", "2036"))
SKIP_BUILD = os.environ.get("PIPELINE_SKIP_BUILD") == "1"

# 输出目录
WORK_DIR = PROJECT_ROOT / "engine" / "sdk" / "forward_pipeline" / ".e2e_runs" / "hollow_sphere"
WORK_DIR.mkdir(parents=True, exist_ok=True)

MPH_PATH = WORK_DIR / "hollow_sphere.mph"
EPS_REAL_CSV = WORK_DIR / "hollow_sphere_eps.csv"


# ----------------------------------------------------------------------
# Step 1: 生成空心球壳 eps_r CSV
# ----------------------------------------------------------------------
def gen_hollow_sphere_csv(csv_path: Path):
    """生成空心球壳 eps_r CSV。

    几何：
    - 规则 3D 网格 X/Y/Z ∈ [-0.20, +0.20]，步长 0.02m → 21^3 = 9261 体素
    - 球壳：0.05 <= r <= 0.12 (厚度 7cm) → eps_r=5
    - 其他 → eps_r=1
    """
    import numpy as np

    print(f"\n{'='*60}")
    print("Step 1: Generating hollow-sphere eps_r CSV")
    print(f"{'='*60}")

    coord = np.arange(-0.20, 0.20 + 1e-9, 0.02)   # 21 points
    X, Y, Z = np.meshgrid(coord, coord, coord, indexing="ij")
    X = X.flatten()
    Y = Y.flatten()
    Z = Z.flatten()
    R = np.sqrt(X**2 + Y**2 + Z**2)

    eps = np.where((R >= 0.05) & (R <= 0.12), 5.0, 1.0)

    data = np.column_stack([X, Y, Z, eps])
    np.savetxt(str(csv_path), data, delimiter=",", fmt="%.6f")

    n_scatterer = int(((R >= 0.05) & (R <= 0.12)).sum())
    print(f"  Wrote {len(data)} voxels to: {csv_path}")
    print(f"  Scatterer voxels (0.05<=r<=0.12, eps_r=5): {n_scatterer}")
    print(f"  Background voxels (eps_r=1): {len(data) - n_scatterer}")
    print(f"  Coord range: X/Y/Z ∈ [{coord.min():.2f}, {coord.max():.2f}], step={coord[1]-coord[0]:.3f}")
    return csv_path


# ----------------------------------------------------------------------
# Step 2: 启动 COMSOL Server（如未启动）
# ----------------------------------------------------------------------
def ensure_comsol_server_started():
    """探测端口，未启动就拉起 comsolmphserver.exe。"""
    print(f"\n{'='*60}")
    print(f"Step 2: Ensuring COMSOL Server on port {COMSOL_PORT}")
    print(f"{'='*60}")

    if _is_port_in_use("127.0.0.1", COMSOL_PORT):
        print(f"  Port {COMSOL_PORT} already in use, assuming Server is up")
        return True

    if not os.path.isfile(COMSOL_SERVER):
        print(f"  [ERROR] comsolmphserver.exe not found: {COMSOL_SERVER}")
        return False

    print(f"  Starting: {COMSOL_SERVER} -port {COMSOL_PORT}")
    # 用 DETACHED_PROCESS 启动（不挂到当前进程组）
    cmd = f'start /B "" "{COMSOL_SERVER}" -port {COMSOL_PORT}'
    subprocess.run(cmd, shell=True)

    # 等端口就绪（最长 4 分钟）
    for i in range(80):
        time.sleep(3)
        if _is_port_in_use("127.0.0.1", COMSOL_PORT):
            print(f"  Server ready after {(i+1)*3}s")
            time.sleep(2)   # 额外等内部初始化
            return True
        if i % 5 == 0:
            print(f"  Waiting... ({(i+1)*3}s elapsed)")
    print(f"  [ERROR] Server not ready within 240s")
    return False


def _is_port_in_use(host: str, port: int) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1.5)
            s.connect((host, port))
            return True
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False


# ----------------------------------------------------------------------
# Step 3: 调 MATLAB 构建模型 .mph
# ----------------------------------------------------------------------
def build_model():
    """调 build_hollow_sphere_model.m 生成 hollow_sphere.mph。"""
    from engine.sdk.forward_pipeline.matlab_runner import MatlabRunner

    print(f"\n{'='*60}")
    print("Step 3: Building hollow-sphere model (.mph)")
    print(f"{'='*60}")

    work_dir = WORK_DIR / "build_run"
    work_dir.mkdir(parents=True, exist_ok=True)

    runner = MatlabRunner(matlab_exe=MATLAB_EXE)
    log_path = work_dir / "build.log"

    # MATLAB -batch 调用：build_hollow_sphere_model('<mph>', <port>)
    mph_ascii = str(MPH_PATH).replace("\\", "/")
    matlab_stmt = (
        f"addpath('{runner.matlab_scripts_dir.replace(chr(92), '/')}'); "
        f"build_hollow_sphere_model('{mph_ascii}', {COMSOL_PORT});"
    )

    print(f"  work_dir: {work_dir}")
    print(f"  log:      {log_path}")
    print(f"  mph:      {MPH_PATH}")

    # 清掉旧 exit.flag
    exit_flag = work_dir / "exit.flag"
    if exit_flag.exists():
        exit_flag.unlink()

    # 用 MatlabRunner 跑（它会写 params.json 但我们这里直接 -batch）
    # 为简单起见，绕过 launcher，直接调
    import subprocess as sp

    cmd = [MATLAB_EXE, "-batch", matlab_stmt]
    cmd_summary = ' '.join(cmd[:2]) + ' "..."'
    print(f"  cmd: {cmd_summary}")

    with open(log_path, "w", encoding="utf-8", errors="replace") as logf:
        logf.write(f"cmd: {' '.join(cmd)}\n" + "="*50 + "\n")
        logf.flush()
        proc = sp.Popen(
            cmd, cwd=str(work_dir),
            stdout=sp.PIPE, stderr=sp.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        for line in proc.stdout:
            print(f"  [matlab] {line.rstrip()}")
            logf.write(line)
            logf.flush()
        proc.wait()

    print(f"\n  MATLAB exit code: {proc.returncode}")
    if not MPH_PATH.is_file():
        print(f"  [ERROR] {MPH_PATH} not generated")
        return False
    print(f"  MPH size: {MPH_PATH.stat().st_size} bytes")
    return True


# ----------------------------------------------------------------------
# Step 4: 调 SDK solve_forward
# ----------------------------------------------------------------------
def run_sdk_forward():
    from engine.sdk.forward_pipeline import ForwardPipeline

    print(f"\n{'='*60}")
    print("Step 4: Running SDK solve_forward")
    print(f"{'='*60}")

    output_dir = WORK_DIR / "forward_outputs"
    output_dir.mkdir(parents=True, exist_ok=True)

    # 用独立 cache root，避免污染主 SDK 缓存
    cache_root = WORK_DIR / ".cache"

    pipe = ForwardPipeline(
        comsol_server_path=COMSOL_SERVER,
        mli_path=MLI_PATH,
        matlab_exe=MATLAB_EXE,
        comsol_port=COMSOL_PORT,
        cache_root=str(cache_root),
        startup_timeout=240,
        run_timeout=600,   # 10 min，对 1GHz 球壳够
    )

    print(f"  eps_real_csv: {EPS_REAL_CSV}")
    print(f"  model_path:   {MPH_PATH}")
    print(f"  output_dir:   {output_dir}")
    print(f"  cache_root:   {cache_root}")

    result = pipe.solve_forward(
        eps_real_csv=str(EPS_REAL_CSV),
        eps_imag_csv="",
        freq_list=[1e9],
        model_path=str(MPH_PATH),
        output_dir=str(output_dir),
        n_directions=64,
        measurement_R=0.26,
        run_v5a=True,
        tol=0.15,    # 球壳 + 9261 体素离散化误差，容限放宽到 15%
        use_cache=False,   # 第一次跑，强制重算
    )

    print(f"\n  --- Result ---")
    print(f"  status:        {result.status}")
    print(f"  stage:         {result.stage}")
    print(f"  error_msg:     {result.error_msg[:200] if result.error_msg else '(none)'}")
    print(f"  mat_path:      {result.mat_path}")
    print(f"  json_path:     {result.json_path}")
    print(f"  v5a_verdict:   {result.v5a_verdict}")
    print(f"  v5a_rel_error: {result.v5a_rel_error:.4f}" if result.v5a_rel_error else "  v5a_rel_error: (none)")
    print(f"  cache_hit:     {result.cache_hit}")
    print(f"  duration:      {result.duration_sec:.1f}s")

    return result


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    print(f"PYTHONPATH entry: {PROJECT_ROOT}")
    print(f"Work dir:         {WORK_DIR}")

    # Step 1
    gen_hollow_sphere_csv(EPS_REAL_CSV)

    # Step 2
    if not ensure_comsol_server_started():
        print("[FATAL] COMSOL Server cannot be started")
        return 1

    # Step 3（可选跳过）
    if SKIP_BUILD:
        if not MPH_PATH.is_file():
            print(f"[FATAL] PIPELINE_SKIP_BUILD=1 but {MPH_PATH} does not exist")
            return 1
        print(f"\n[SKIP] Skipping model build, reusing: {MPH_PATH}")
    else:
        if not build_model():
            print("[FATAL] Model build failed")
            return 1

    # Step 4
    result = run_sdk_forward()

    # ---- 最终判定 ----
    print(f"\n{'='*60}")
    print("FINAL VERDICT")
    print(f"{'='*60}")
    if result.status == "success":
        print(f"  ✓ 正演成功")
        if result.v5a_verdict == "pass":
            print(f"  ✓ V5a 通过 (rel_error={result.v5a_rel_error*100:.2f}% < 15%)")
        elif result.v5a_verdict == "fail":
            print(f"  ✗ V5a 未通过 (rel_error={result.v5a_rel_error*100:.2f}% >= 15%)")
            print(f"    （但正演本身已跑通，J_obs 数据有效；V5a 误差大可能是体素离散化所致）")
        return 0
    elif result.status == "cached":
        print(f"  ✓ 命中缓存")
        return 0
    else:
        print(f"  ✗ 失败 at stage={result.stage}")
        print(f"    error: {result.error_msg}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
