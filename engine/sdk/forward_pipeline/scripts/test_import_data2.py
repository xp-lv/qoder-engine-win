"""测试 importData 方法。简化版本，所有 fprintf 用单引号字符串。"""
import subprocess
import sys
import io
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

PROJECT_ROOT = Path(__file__).resolve().parents[4]
WORK = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/import_data_test2"
WORK.mkdir(parents=True, exist_ok=True)

# 写 MATLAB 脚本作为独立文件（不通过模板替换）
matlab_content = r"""addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('MPH_PLACEHOLDER');

fprintf('[imp] === Setup ===\n');
try
    m.func.remove('int2_new');
catch
end

m.func.create('int2_new', 'Interpolation');
new_int = m.func('int2_new');

fprintf('\n[imp] === Try importData(filepath) ===\n');
try
    new_int.importData('TXT_PLACEHOLDER');
    fprintf('[imp] importData: OK\n');
catch ME
    fprintf('[imp] importData FAIL: %s\n', ME.message);
end

fprintf('\n[imp] === hasProperty sweep ===\n');
prop_names = {'table', 'argstr', 'argvals', 'funcname', 'source', 'data', ...
              'filename', 'file', 'interp', 'extrap', 'figure', 'index', ...
              'srcspace', 'tablename', 'tvec', 'funcname', 'args', ...
              'outsidedomaintype', 'frame'};
for i = 1:length(prop_names)
    pn = prop_names{i};
    try
        has = new_int.hasProperty(pn);
        if has
            fprintf('[imp] hasProperty(%s): TRUE\n', pn);
        end
    catch
        % silent
    end
end

fprintf('\n[imp] === getEntryKeys ===\n');
try
    keys = new_int.getEntryKeys;
    fprintf('[imp] keys class: %s\n', class(keys));
    fprintf('[imp] keys: '); disp(keys);
catch ME
    fprintf('[imp] getEntryKeys FAIL: %s\n', ME.message);
end

fprintf('\n[imp] === get all property values via getAllowedPropertyValues ===\n');
try
    allowed = new_int.getAllowedPropertyValues('table');
    fprintf('[imp] table allowed values: '); disp(allowed);
catch ME
    fprintf('[imp] table allowed values FAIL: %s\n', ME.message);
end

clearvars m;
fprintf('\n[imp] DONE\n');
"""

# 替换占位符（不用模板，直接字符串替换）
matlab_content = matlab_content.replace(
    "MPH_PLACEHOLDER",
    str(PROJECT_ROOT / "COMSOL/livelink_model.mph").replace("\\", "/")
)
test_txt = WORK / "test_data.txt"
with open(test_txt, "w") as f:
    f.write("0 0 0 1.0\n")
    f.write("0.1 0 0 2.0\n")
    f.write("0.2 0 0 3.0\n")
matlab_content = matlab_content.replace(
    "TXT_PLACEHOLDER",
    str(test_txt).replace("\\", "/")
)

matlab_file = WORK / "import_test2.m"
matlab_file.write_text(matlab_content, encoding="utf-8", errors="replace")

print("Running...")
runner = PROJECT_ROOT / "engine/sdk/forward_pipeline/scripts/livelink_runner.py"
import os
proc = subprocess.run(
    ["python", "-X", "utf8", str(runner), str(matlab_file), str(WORK)],
    env={**os.environ, "PYTHONIOENCODING": "utf-8"}
)
print(f"\nexit: {proc.returncode}")
