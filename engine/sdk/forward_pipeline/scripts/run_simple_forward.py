"""直接调 simple_forward_solve.m 跑 livelink_model.mph + 空心球 CSV。"""
import json
import subprocess
import sys
import io
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

PROJECT_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(PROJECT_ROOT))

WORK = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/simple_run"
WORK.mkdir(parents=True, exist_ok=True)

MATLAB_EXE = r"D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe"
SDK_MATLAB = PROJECT_ROOT / "engine/sdk/forward_pipeline/matlab"
EPS_CSV = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/hollow_sphere_eps.csv"
MPH = PROJECT_ROOT / "COMSOL/livelink_model.mph"
SCATTER_MAT = WORK / "scatter_field.mat"

# 读 CSV 拿 voxel positions（前 3 列）
import csv
voxel_positions = []
with open(EPS_CSV) as f:
    for row in csv.reader(f):
        if len(row) >= 3:
            voxel_positions.append([float(row[0]), float(row[1]), float(row[2])])
print(f"voxel positions: {len(voxel_positions)} (sample: {voxel_positions[0]}, {voxel_positions[-1]})")

# 把 voxel_positions 存成一个 .mat 给 MATLAB 读
# 用 scipy.io
from scipy.io import savemat
savemat(str(WORK / "voxel_positions.mat"),
        {"voxel_positions": voxel_positions}, do_compression=False)
print(f"voxel_positions.mat saved")

# 写 MATLAB 脚本（用模板，避免 f-string）
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
params.output_path = '<<SCATTER_MAT>>';

% 加载体素位置
v = load('<<VOXEL_MAT>>');
params.voxel_positions = v.voxel_positions;
fprintf('[main] voxel_positions: %d x %d\n', size(params.voxel_positions));

result = simple_forward_solve(params);

fprintf('\n[main] === Result ===\n');
fprintf('[main] status: %s\n', result.status);
if strcmp(result.status, 'error')
    fprintf('[main] error: %s\n', result.error_msg);
end
if isfield(result, 'scattered_field')
    Es = result.scattered_field.E_s;
    fprintf('[main] E_s shape: %s\n', mat2str(size(Es)));
    fprintf('[main] ||E_s|| = %.4e\n', sqrt(sum(abs(Es(:)).^2)));
end
if isfield(result, 'total_field')
    Et = result.total_field.E_total;
    fprintf('[main] E_total shape: %s\n', mat2str(size(Et)));
    fprintf('[main] ||E_total_voxel|| = %.4e\n', sqrt(sum(abs(Et(:)).^2)));
end

% 写 exit flag
fid = fopen('<<WORK>>/exit.flag', 'w');
fprintf(fid, '%d\n', (strcmp(result.status, 'success')));
fclose(fid);

% 不调 ModelUtil.disconnect（会杀 Server）；只清除 model 引用
clearvars m result;
fprintf('[main] === DONE ===\n');
'''

script = (TEMPLATE
    .replace("<<SDK_MATLAB>>", str(SDK_MATLAB).replace("\\", "/"))
    .replace("<<MPH>>", str(MPH).replace("\\", "/"))
    .replace("<<EPS_CSV>>", str(EPS_CSV).replace("\\", "/"))
    .replace("<<SCATTER_MAT>>", str(SCATTER_MAT).replace("\\", "/"))
    .replace("<<VOXEL_MAT>>", str(WORK / "voxel_positions.mat").replace("\\", "/"))
    .replace("<<WORK>>", str(WORK).replace("\\", "/"))
)

matlab_file = WORK / "run_simple.m"
matlab_file.write_text(script, encoding="utf-8", errors="replace")

print(f"\nMATLAB script: {matlab_file}")
print(f"MPH: {MPH}")
print(f"\nRunning (3-5 min expected)...\n")

cmd = [MATLAB_EXE, "-batch", f"run('{str(matlab_file).replace(chr(92), '/')}')"]
proc = subprocess.Popen(
    cmd, cwd=str(WORK),
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    text=True, encoding="utf-8", errors="replace", bufsize=1,
)
for line in proc.stdout:
    print(f"  {line.rstrip()}")
proc.wait()

print(f"\nMATLAB exit: {proc.returncode}")
print(f"scatter_mat exists: {SCATTER_MAT.is_file()}")
if SCATTER_MAT.is_file():
    print(f"scatter_mat size: {SCATTER_MAT.stat().st_size:,} bytes")

exit_flag = WORK / "exit.flag"
if exit_flag.is_file():
    code = exit_flag.read_text().strip()
    print(f"exit.flag: {code}")
    if code == "1":
        print("\n*** SUCCESS ***")
    else:
        print("\n*** FAILED ***")
