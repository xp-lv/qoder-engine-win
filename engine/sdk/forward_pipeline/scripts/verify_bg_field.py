"""验证背景场参数化：同一散射体，3 个不同入射方向。

A. +z 方向（默认）  E_bg = [0, 0, 1]
B. +x 方向          E_bg = [1, 0, 0]
C. +y 方向          E_bg = [0, 1, 0]

空心球散射体对 +z / +x / +y 三个方向的响应**理论上应该相同**（球对称）。
但测量球面上的 E_s 分布会不同——
因为 Fibonacci 采样点对每个入射方向的相对几何不同。
所以 ||E_s||_Frobenius 三个值接近，但 E_s 数组本身不同。

这个验证：
1. 证明 bg_E 参数真的生效（E_s 数组不同 = 背景场确实变了）
2. 证明物理合理（球对称 → ||E_s|| 接近）
"""
import sys
import io
import os
import subprocess
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

PROJECT_ROOT = Path(__file__).resolve().parents[4]
WORK = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/bg_compare"
WORK.mkdir(parents=True, exist_ok=True)

SDK_MATLAB = PROJECT_ROOT / "engine/sdk/forward_pipeline/matlab"
MPH = PROJECT_ROOT / "COMSOL/livelink_model.mph"
EPS_CSV = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/hollow_sphere_eps.csv"


def make_runner_script(label: str, bg_E: list, output_mat: Path) -> str:
    """生成 MATLAB runner 脚本。"""
    content = r"""addpath('SDK_MATLAB_PLACEHOLDER');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

params = struct();
params.model_path = 'MPH_PLACEHOLDER';
params.eps_real_csv = 'EPS_CSV_PLACEHOLDER';
params.freq_list = [1e9];
params.n_directions = 64;
params.measurement_R = 0.26;
params.output_path = 'OUT_MAT_PLACEHOLDER';
params.bg_E = [BG_PLACEHOLDER];   % 背景场 [Ex, Ey, Ez] V/m

csv_data = readmatrix('EPS_CSV_PLACEHOLDER');
params.voxel_positions = csv_data(1:min(100, size(csv_data,1)), 1:3);
fprintf('[LABEL_PLACEHOLDER] voxel_positions: %d x %d\n', size(params.voxel_positions));

result = simple_forward_solve(params);

fprintf('\n[LABEL_PLACEHOLDER] === Result ===\n');
fprintf('[LABEL_PLACEHOLDER] status: %s\n', result.status);
if strcmp(result.status, 'error')
    fprintf('[LABEL_PLACEHOLDER] error: %s\n', result.error_msg);
end
if isfield(result, 'scattered_field')
    Es = result.scattered_field.E_s;
    Es_norm = sqrt(sum(abs(Es(:)).^2));
    fprintf('[LABEL_PLACEHOLDER] ||E_s|| = %.4e\n', Es_norm);

    % 保存 E_s 数组的前 10 个值用于跨 run 对比
    Es_vec = Es(:);
    fprintf('[LABEL_PLACEHOLDER] E_s first 10 (real): ');
    for i = 1:min(10, numel(Es_vec))
        fprintf('%.4f ', real(Es_vec(i)));
    end
    fprintf('\n');
end

fid = fopen('FLAG_PLACEHOLDER', 'w');
fprintf(fid, '%d\n', strcmp(result.status, 'success'));
fclose(fid);

clearvars m result;
fprintf('[LABEL_PLACEHOLDER] DONE\n');
"""
    content = content.replace("SDK_MATLAB_PLACEHOLDER", str(SDK_MATLAB).replace("\\", "/"))
    content = content.replace("MPH_PLACEHOLDER", str(MPH).replace("\\", "/"))
    content = content.replace("EPS_CSV_PLACEHOLDER", str(EPS_CSV).replace("\\", "/"))
    content = content.replace("OUT_MAT_PLACEHOLDER", str(output_mat).replace("\\", "/"))
    content = content.replace("FLAG_PLACEHOLDER", str(output_mat.with_suffix(".flag")).replace("\\", "/"))
    content = content.replace("BG_PLACEHOLDER", f"[{bg_E[0]}, {bg_E[1]}, {bg_E[2]}]")
    content = content.replace("LABEL_PLACEHOLDER", label)
    return content


def run_one(label: str, bg_E: list, work_dir: Path):
    work_dir.mkdir(parents=True, exist_ok=True)
    out_mat = work_dir / f"{label}_scatter.mat"
    script_path = work_dir / f"run_{label}.m"
    script_path.write_text(make_runner_script(label, bg_E, out_mat), encoding="utf-8")

    runner = PROJECT_ROOT / "engine/sdk/forward_pipeline/scripts/livelink_runner.py"
    cmd = ["python", "-X", "utf8", str(runner), str(script_path), str(work_dir)]
    print(f"\n{'='*60}\n[{label}] bg_E = {bg_E}\n{'='*60}\n")
    proc = subprocess.run(cmd, env={**os.environ, "PYTHONIOENCODING": "utf-8"})
    return proc.returncode


def main():
    configs = [
        ("A_z", [0.0, 0.0, 1.0]),   # +z（默认）
        ("B_x", [1.0, 0.0, 0.0]),   # +x
        ("C_y", [0.0, 1.0, 0.0]),   # +y
    ]

    results = []
    for label, bg in configs:
        rc = run_one(label, bg, WORK / label)
        results.append((label, bg, rc))

    print(f"\n{'='*60}\nSUMMARY\n{'='*60}")
    for label, bg, rc in results:
        print(f"{label}: bg_E={bg}, rc={rc}")
    print("\n看上面每个 run 的 ||E_s|| 和 E_s first 10：")
    print("  - 三个 ||E_s|| 应该接近（球对称）")
    print("  - 三个 E_s first 10 应该明显不同（证明背景场确实改了）")


if __name__ == "__main__":
    main()
