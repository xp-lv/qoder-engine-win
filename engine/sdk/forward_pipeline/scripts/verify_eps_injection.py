"""验证任意 epsi 分布：跑两个不同 CSV 对比结果。

跑两次：
  A. uniform_eps1.csv   — 全部 eps_r=1（背景场，应无散射）
  B. hollow_sphere_eps.csv — 空心球壳 eps_r=5（应产生散射）

如果 ||E_s||_B > ||E_s||_A，证明 eps_r 真正影响求解。
"""
import sys
import io
import csv
import subprocess
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

PROJECT_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(PROJECT_ROOT))

WORK = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/compare_run"
WORK.mkdir(parents=True, exist_ok=True)

# --- 复用 run_simple_forward.py 的 MATLAB 模板逻辑 ---
SDK_MATLAB = PROJECT_ROOT / "engine/sdk/forward_pipeline/matlab"
MPH = PROJECT_ROOT / "COMSOL/livelink_model.mph"


def make_runner_script(csv_path: Path, output_mat: Path, label: str) -> str:
    """生成一个 MATLAB runner 脚本。"""
    TEMPLATE = r'''
addpath('<<SDK_MATLAB>>');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

params = struct();
params.model_path = '<<MPH>>';
params.eps_real_csv = '<<EPS_CSV>>';
params.freq_list = [1e9];
params.n_directions = 64;
params.measurement_R = 0.26;
params.output_path = '<<OUT_MAT>>';

% 简化：用 CSV 自身的前 3 列作为 voxel positions（只取前 100 个加速）
csv_data = readmatrix('<<EPS_CSV>>');
params.voxel_positions = csv_data(1:min(100, size(csv_data,1)), 1:3);
fprintf('[<<LABEL>>] voxel_positions: %d x %d\n', size(params.voxel_positions));

result = simple_forward_solve(params);

fprintf('\n[<<LABEL>>] === Result ===\n');
fprintf('[<<LABEL>>] status: %s\n', result.status);
if strcmp(result.status, 'error')
    fprintf('[<<LABEL>>] error: %s\n', result.error_msg);
end
if isfield(result, 'scattered_field')
    Es = result.scattered_field.E_s;
    fprintf('[<<LABEL>>] ||E_s|| = %.4e\n', sqrt(sum(abs(Es(:)).^2)));
end

fid = fopen('<<OUT_FLAG>>', 'w');
fprintf(fid, '%d\n', strcmp(result.status, 'success'));
fclose(fid);

clearvars m result;
fprintf('[<<LABEL>>] DONE\n');
'''
    return (TEMPLATE
        .replace("<<SDK_MATLAB>>", str(SDK_MATLAB).replace("\\", "/"))
        .replace("<<MPH>>", str(MPH).replace("\\", "/"))
        .replace("<<EPS_CSV>>", str(csv_path).replace("\\", "/"))
        .replace("<<OUT_MAT>>", str(output_mat).replace("\\", "/"))
        .replace("<<OUT_FLAG>>", str(output_mat.with_suffix(".flag")).replace("\\", "/"))
        .replace("<<LABEL>>", label))


def gen_uniform_eps1_csv(out_path: Path, n=9261):
    """全 eps_r=1 的 CSV（背景场）。"""
    import numpy as np
    coord = np.arange(-0.20, 0.20 + 1e-9, 0.02)
    X, Y, Z = np.meshgrid(coord, coord, coord, indexing="ij")
    data = np.column_stack([X.flatten(), Y.flatten(), Z.flatten(), np.ones(len(X.flatten()))])
    np.savetxt(str(out_path), data, delimiter=",", fmt="%.6f")
    return out_path


def run_one(csv_path: Path, label: str, work_dir: Path):
    work_dir.mkdir(parents=True, exist_ok=True)
    out_mat = work_dir / f"{label}_scatter.mat"

    # 生成 runner 脚本
    script_path = work_dir / f"run_{label}.m"
    script_path.write_text(make_runner_script(csv_path, out_mat, label), encoding="utf-8")

    # 用 livelink_runner
    runner = PROJECT_ROOT / "engine/sdk/forward_pipeline/scripts/livelink_runner.py"
    cmd = ["python", "-X", "utf8", str(runner), str(script_path), str(work_dir)]
    print(f"\n{'='*60}\n[{label}] Running with CSV: {csv_path.name}\n{'='*60}\n")
    proc = subprocess.run(cmd, env={**__import__('os').environ, "PYTHONIOENCODING": "utf-8"})
    return proc.returncode, out_mat


def main():
    # 准备两个 CSV
    eps1_csv = WORK / "uniform_eps1.csv"
    gen_uniform_eps1_csv(eps1_csv)
    print(f"[A] uniform eps_r=1 CSV: {eps1_csv}")

    eps_hollow = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/hollow_sphere_eps.csv"
    print(f"[B] hollow sphere eps_r=5 CSV: {eps_hollow}")

    # 跑 A
    rc_a, _ = run_one(eps1_csv, "A_eps1", WORK / "A")
    # 跑 B
    rc_b, _ = run_one(eps_hollow, "B_hollow", WORK / "B")

    print(f"\n{'='*60}\nFINAL\n{'='*60}")
    print(f"A (eps_r=1 background): rc={rc_a}")
    print(f"B (hollow sphere eps_r=5): rc={rc_b}")

    # 解析日志，对比 ||E_s||
    # runner 已经把 MATLAB 输出打到 stdout，我们 grep 一下
    print("\n看上面的 [A_eps1] ||E_s|| 和 [B_hollow] ||E_s||：")
    print("  - 如果 B > A 显著 → eps_r 生效（散射体产生散射）")
    print("  - 如果 A ≈ B → eps_r 没生效（仍然用 .mph 默认材料）")


if __name__ == "__main__":
    main()
