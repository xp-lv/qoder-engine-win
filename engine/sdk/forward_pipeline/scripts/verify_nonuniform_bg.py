"""DBIM 两步流程验证：
1. 步骤 1：eps_r=1（无散射体）+ 均匀背景场 +z → 得到背景场分布 E_total_bg
2. 步骤 2：eps_r=1（无散射体）+ 非均匀背景场（用步骤 1 的 E_total_bg）→ 应得到 ||E_s|| ≈ 0

物理含义：
  步骤 1 算的是"无散射体时空间中的场分布" E_bg_actual(x,y,z)
  步骤 2 把 E_bg_actual 作为背景场，再算一次"无散射体的总场"
       总场应该 = 背景场 + 0（因为无散射）
       所以 ||E_s||（散射场）应该接近 0

如果 ||E_s||_step2 ≈ 0，说明非均匀背景场注入完全正确。
"""
import sys
import io
import os
import subprocess
import numpy as np
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

PROJECT_ROOT = Path(__file__).resolve().parents[4]
WORK = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/dbim_test"
WORK.mkdir(parents=True, exist_ok=True)

SDK_MATLAB = PROJECT_ROOT / "engine/sdk/forward_pipeline/matlab"
MPH = PROJECT_ROOT / "COMSOL/livelink_model.mph"

# 统一的体素网格（与 hollow_sphere_eps.csv 一致）
coord = np.arange(-0.20, 0.20 + 1e-9, 0.02)
X, Y, Z = np.meshgrid(coord, coord, coord, indexing="ij")
VOXEL_X = X.flatten()
VOXEL_Y = Y.flatten()
VOXEL_Z = Z.flatten()
N_VOXEL = len(VOXEL_X)
print(f"Voxel grid: {N_VOXEL} points ({len(coord)}^3)")


def gen_eps1_csv(out_path: Path):
    """eps_r=1 全域（无散射体）。"""
    data = np.column_stack([VOXEL_X, VOXEL_Y, VOXEL_Z, np.ones(N_VOXEL)])
    np.savetxt(str(out_path), data, delimiter=",", fmt="%.6f")
    return out_path


def write_bg_csv_from_step1(step1_mat: Path, bg_csv_path: Path):
    """从步骤 1 的 .mat 提取 E_total，写成 bg_csv 格式（9 列）。
    
    .mat 是 MATLAB v7.3 格式（HDF5），必须用 h5py 读。
    复数以结构化 dtype (real, imag) 存储，需手动拼接为 complex。
    """
    import h5py
    with h5py.File(str(step1_mat), 'r') as f:
        raw = f['E_total_voxel'][:]
    
    # h5py 读 v7.3 复数：dtype 是 [('real','<f8'), ('imag','<f8')]
    # 维度是反的（MATLAB 列主序）
    if raw.dtype.names is not None and 'real' in raw.dtype.names:
        # 结构化复数 → numpy complex
        E_total = raw['real'] + 1j * raw['imag']
    else:
        E_total = raw
    
    # 维度反转：[N_freq x 3 x N_voxel] → [N_voxel x 3 x N_freq]
    E_total = E_total.transpose()
    if E_total.ndim == 2:
        E_total = E_total[:, :, np.newaxis]
    
    E = E_total[:, :, 0]   # [N_voxel x 3]
    print(f"  Step1 E_total shape (after transpose): {E_total.shape}")
    print(f"  ||E_total||={np.linalg.norm(E):.4e}")
    print(f"  E_total[0]={E[0]}")
    print(f"  E_total[100]={E[100]}")
    
    # bg_csv：x, y, z, Ex_re, Ey_re, Ez_re, Ex_im, Ey_im, Ez_im
    n = E.shape[0]
    data = np.column_stack([
        VOXEL_X, VOXEL_Y, VOXEL_Z,
        E[:, 0].real, E[:, 1].real, E[:, 2].real,
        E[:, 0].imag, E[:, 1].imag, E[:, 2].imag,
    ])
    np.savetxt(str(bg_csv_path), data, delimiter=",", fmt="%.6e")
    print(f"  Wrote bg_csv: {bg_csv_path} ({n} rows)")
    return bg_csv_path


def make_runner_script(label: str, params_extra: dict, output_mat: Path) -> str:
    """生成 MATLAB runner 脚本。"""
    content = f"""addpath('{str(SDK_MATLAB).replace(chr(92), "/")}');
addpath('D:\\LenovoSoftstore\\Install\\COMSOL62\\Multiphysics\\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

params = struct();
params.model_path = '{str(MPH).replace(chr(92), "/")}';
"""
    # 加额外参数
    for k, v in params_extra.items():
        if isinstance(v, str):
            content += f"params.{k} = '{v}';\n"
        elif isinstance(v, list):
            content += f"params.{k} = [{', '.join(str(x) for x in v)}];\n"
        else:
            content += f"params.{k} = {v};\n"

    content += f"""
params.output_path = '{str(output_mat).replace(chr(92), "/")}';

csv_data = readmatrix(params.eps_real_csv);
params.voxel_positions = csv_data(:, 1:3);
fprintf('[{label}] voxel_positions: %d x %d\\n', size(params.voxel_positions));

result = simple_forward_solve(params);

fprintf('\\n[{label}] === Result ===\\n');
fprintf('[{label}] status: %s\\n', result.status);
if strcmp(result.status, 'error')
    fprintf('[{label}] error: %s\\n', result.error_msg);
end
if isfield(result, 'scattered_field')
    Es = result.scattered_field.E_s;
    fprintf('[{label}] ||E_s|| = %.4e\\n', sqrt(sum(abs(Es(:)).^2)));
end
if isfield(result, 'total_field')
    Et = result.total_field.E_total;
    fprintf('[{label}] ||E_total_voxel|| = %.4e\\n', sqrt(sum(abs(Et(:)).^2)));
end

fid = fopen('{str(output_mat.with_suffix(".flag")).replace(chr(92), "/")}', 'w');
fprintf(fid, '%d\\n', strcmp(result.status, 'success'));
fclose(fid);

clearvars m result;
fprintf('[{label}] DONE\\n');
"""
    return content


def run_matlab(script_path: Path, cwd: Path):
    runner = PROJECT_ROOT / "engine/sdk/forward_pipeline/scripts/livelink_runner.py"
    cmd = ["python", "-X", "utf8", str(runner), str(script_path), str(cwd)]
    proc = subprocess.run(cmd, env={**os.environ, "PYTHONIOENCODING": "utf-8"})
    return proc.returncode


def main():
    eps1_csv = WORK / "eps_r_1.csv"
    gen_eps1_csv(eps1_csv)
    print(f"[setup] eps_r=1 CSV: {eps1_csv}")

    # ============= 步骤 1：均匀背景场 +z + eps_r=1 =============
    print(f"\n{'='*60}\n[Step 1] Uniform bg +z, eps_r=1\n{'='*60}")
    step1_dir = WORK / "step1"
    step1_dir.mkdir(parents=True, exist_ok=True)
    step1_mat = step1_dir / "step1_scatter.mat"

    params1 = {
        "eps_real_csv": str(eps1_csv),
        "freq_list": [1e9],
        "n_directions": 64,
        "measurement_R": 0.26,
        "bg_E": [0.0, 0.0, 1.0],   # 均匀 +z
    }
    script1 = step1_dir / "run_step1.m"
    script1.write_text(make_runner_script("step1", params1, step1_mat), encoding="utf-8")
    rc1 = run_matlab(script1, step1_dir)

    if rc1 != 0 or not step1_mat.is_file():
        print(f"[FATAL] Step 1 failed (rc={rc1}, mat exists={step1_mat.is_file()})")
        return 1

    # 从 step1 提取背景场 CSV
    bg_csv = WORK / "bg_from_step1.csv"
    print(f"\n{'='*60}\n[Extract] Generating bg_csv from step1 E_total\n{'='*60}")
    write_bg_csv_from_step1(step1_mat, bg_csv)

    # ============= 步骤 2：非均匀背景场（step1 的 E_total）+ eps_r=1 =============
    print(f"\n{'='*60}\n[Step 2] Non-uniform bg (from step1), eps_r=1\n{'='*60}")
    step2_dir = WORK / "step2"
    step2_dir.mkdir(parents=True, exist_ok=True)
    step2_mat = step2_dir / "step2_scatter.mat"

    params2 = {
        "eps_real_csv": str(eps1_csv),
        "freq_list": [1e9],
        "n_directions": 64,
        "measurement_R": 0.26,
        "bg_csv": str(bg_csv),   # 非均匀背景场
    }
    script2 = step2_dir / "run_step2.m"
    script2.write_text(make_runner_script("step2", params2, step2_mat), encoding="utf-8")
    rc2 = run_matlab(script2, step2_dir)

    # ============= 判定 =============
    print(f"\n{'='*60}\nFINAL JUDGMENT\n{'='*60}")
    print(f"Step 1 (uniform bg +z, eps_r=1): rc={rc1}")
    print(f"Step 2 (non-uniform bg from step1, eps_r=1): rc={rc2}")
    print()
    print("物理预期：")
    print("  Step 1: 均匀平面波在自由空间传播 → ||E_s|| 不一定 0（背景场公式可能有残差）")
    print("          但 ||E_total_voxel|| 应该 ≈ 9-11 V/m（自由空间平面波）")
    print("  Step 2: 背景场 = step1 的总场，无散射体 → ||E_s|| ≈ 0")
    print("          （因为总场 = 背景场 + 散射场，无散射 → 散射场 = 0）")
    print()
    print("如果 Step 2 的 ||E_s|| << Step 1 的 ||E_s||，说明非均匀背景场注入完全正确。")
    print()
    print("详细数字看上面 [step1] / [step2] 的日志。")


if __name__ == "__main__":
    sys.exit(main() or 0)
