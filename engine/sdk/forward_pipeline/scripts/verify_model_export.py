"""跑 model_export.m 验证它能成功构建模型，然后把模型存为 .mph。

不调用 SDK，纯验证。
"""
import os
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(PROJECT_ROOT))

WORK_DIR = PROJECT_ROOT / "engine" / "sdk" / "forward_pipeline" / ".e2e_runs" / "hollow_sphere" / "model_export_run"
WORK_DIR.mkdir(parents=True, exist_ok=True)

MATLAB_EXE = r"D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe"
MLI_PATH = r"D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli"
COMSOL_EXPORT_DIR = PROJECT_ROOT / "COMSOL"

MPH_OUTPUT = WORK_DIR / "model_exported.mph"

# MATLAB 脚本：在 LiveLink 上跑 model_export，然后存盘
matlab_script = f"""
addpath('{MLI_PATH.replace(chr(92), '/')}');
addpath('{str(COMSOL_EXPORT_DIR).replace(chr(92), '/')}');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

fprintf('[verify] === Running model_export.m ===\\n');
m = model_export();
fprintf('[verify] Model created, modelPath=%s\\n', m.modelPath);

% 验证关键节点存在
fprintf('[verify] Physics tags: %s\\n', strjoin(m.physics.tags));
fprintf('[verify] Study tags: %s\\n', strjoin(m.study.tags));
fprintf('[verify] Geometry tags: %s\\n', strjoin(m.geom.tags));
fprintf('[verify] Mesh tags: %s\\n', strjoin(m.mesh.tags));

% 检查 emw 物理场的背景场设置
try
    solveFor = m.physics('emw').prop('BackgroundField').get('SolveFor');
    fprintf('[verify] emw BackgroundField.SolveFor: %s\\n', solveFor);
catch ME
    fprintf('[verify][WARN] BackgroundField get failed: %s\\n', ME.message);
end

% 检查 sctr1 特征
try
    sctr_sel = m.physics('emw').feature('sctr1').selection;
    fprintf('[verify] sctr1 selection: %s\\n', strjoin(sctr_sel));
catch ME
    fprintf('[verify][WARN] sctr1 not found or selection get failed: %s\\n', ME.message);
end

% 尝试跑一次求解
fprintf('[verify] === Running solve ===\\n');
try
    m.study('std1').run;
    fprintf('[verify] Study run completed\\n');
catch ME
    fprintf('[verify][ERROR] Study run failed: %s\\n', ME.message);
end

% 验证场值（用 mphinterp coord）
fprintf('[verify] === Field validation ===\\n');
test_pts = [0 0 0; 0.1 0 0; 0 0 0.1; 0.2 0 0]';
try
    Ez = mphinterp(m, 'emw.Ez', 'dataset', 'dset1', 'coord', test_pts);
    fprintf('[verify] Ez at (0,0,0):   %.4e\\n', abs(Ez(1)));
    fprintf('[verify] Ez at (0.1,0,0): %.4e\\n', abs(Ez(2)));
    fprintf('[verify] Ez at (0,0,0.1): %.4e\\n', abs(Ez(3)));
    fprintf('[verify] Ez at (0.2,0,0): %.4e\\n', abs(Ez(4)));

    relEz = mphinterp(m, 'emw.relEz', 'dataset', 'dset1', 'coord', test_pts);
    fprintf('[verify] relEz at (0,0,0):   %.4e\\n', abs(relEz(1)));
    fprintf('[verify] relEz at (0.1,0,0): %.4e\\n', abs(relEz(2)));
catch ME
    fprintf('[verify][ERROR] mphinterp failed: %s\\n', ME.message);
end

% 存为 .mph
fprintf('[verify] === Saving model to .mph ===\\n');
try
    m.save('{str(MPH_OUTPUT).replace(chr(92), '/')}', 'compressed');
    fprintf('[verify] Saved: %s\\n', '{MPH_OUTPUT}');
catch ME
    fprintf('[verify][ERROR] save failed: %s\\n', ME.message);
end

ModelUtil.disconnect;
fprintf('[verify] === DONE ===\\n');
"""

# 写 MATLAB 脚本到临时文件（脚本内全 ASCII，用 latin-1 保底避免 Python 源码中可能的非 ASCII 字符被二次编码）
matlab_file = WORK_DIR / "verify_model_export.m"
matlab_file.write_text(matlab_script, encoding="utf-8", errors="replace")

print(f"MATLAB script: {matlab_file}")
print(f"Output MPH:    {MPH_OUTPUT}")
print(f"\nRunning MATLAB (may take 2-5 minutes)...\n")

# 先确保 COMSOL Server 在跑
import socket
import time

def is_port_up(port):
    try:
        with socket.socket() as s:
            s.settimeout(1)
            s.connect(("127.0.0.1", port))
            return True
    except Exception:
        return False

if not is_port_up(2036):
    print("Starting COMSOL Server...")
    subprocess.run(
        f'start /B "" "D:\\LenovoSoftstore\\Install\\COMSOL62\\Multiphysics\\bin\\win64\\comsolmphserver.exe" -port 2036',
        shell=True,
    )
    for i in range(60):
        time.sleep(3)
        if is_port_up(2036):
            print(f"Server up after {(i+1)*3}s")
            break
    else:
        print("FATAL: Server did not start")
        sys.exit(1)
else:
    print("COMSOL Server already up")

# 跑 MATLAB -batch
cmd = [MATLAB_EXE, "-batch", f"run('{str(matlab_file).replace(chr(92), '/')}')"]
print(f"cmd: {cmd[0]} -batch run('<script>')")

proc = subprocess.Popen(
    cmd, cwd=str(WORK_DIR),
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    text=True, encoding="utf-8", errors="replace", bufsize=1,
)
for line in proc.stdout:
    print(f"  {line.rstrip()}")
proc.wait()

print(f"\nMATLAB exit code: {proc.returncode}")
print(f"MPH exists: {MPH_OUTPUT.is_file()}")
if MPH_OUTPUT.is_file():
    print(f"MPH size: {MPH_OUTPUT.stat().st_size:,} bytes")
