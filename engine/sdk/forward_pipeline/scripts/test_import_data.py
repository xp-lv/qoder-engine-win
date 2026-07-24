"""尝试 importData 方法 + 看看 entry-based API 怎么用。"""
import subprocess
import sys
import io
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

PROJECT_ROOT = Path(__file__).resolve().parents[4]
WORK = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/import_data_test"
WORK.mkdir(parents=True, exist_ok=True)

TEMPLATE = r'''
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('<<MPH>>');

fprintf('\n[imp] === Test importData ===\n');
try
    m.func.remove('int2_new');
catch
end

m.func.create('int2_new', 'Interpolation');
new_int = m.func('int2_new');

% 看 importData 的方法签名
fprintf('[imp] importData methods:
');
try
    md = methods('com.comsol.clientapi.impl.FunctionFeatureClient');
    import_methods = {};
    for i = 1:length(md)
        if contains(md{i}, 'import') || contains(md{i}, 'Import')
            import_methods{end+1} = md{i};
        end
    end
    fprintf('[imp] import-related methods (%d):
', length(import_methods));
    for i = 1:length(import_methods)
        fprintf('  %s
', import_methods{i});
    end
catch ME
    fprintf('[imp] methods call fail: %s\n', ME.message);
end

% 尝试 importData(filepath)
fprintf('\n[imp] --- call importData ---\n');
try
    new_int.importData('<<TEST_TXT>>');
    fprintf('[imp] importData OK\n');
catch ME
    fprintf('[imp] importData FAIL: %s\n', ME.message);
end

% 看 getAllowedPropertyValues 和 entry-based API
fprintf('\n[imp] === getEntryKeys ===\n');
try
    keys = new_int.getEntryKeys;
    fprintf('[imp] entry keys:\n');
    disp(keys);
catch ME
    fprintf('[imp] getEntryKeys FAIL: %s\n', ME.message);
end

fprintf('\n[imp] === hasProperty test ===\n');
prop_names = {'table', 'argstr', 'argvals', 'funcname', 'source', 'data', ...
              'filename', 'file', 'interp', 'extrap', 'figure', 'index'};
for i = 1:length(prop_names)
    pn = prop_names{i};
    try
        has = new_int.hasProperty(pn);
        fprintf('[imp] hasProperty(%s): %d\n', pn, has);
    catch
        fprintf('[imp] hasProperty(%s): error\n', pn);
    end
end

% 看 properties() 方法（第 72 行 method）
fprintf('\n[imp] === properties() method ===\n');
try
    props = new_int.properties;
    fprintf('[imp] properties class: %s\n', class(props));
catch ME
    fprintf('[imp] properties() fail: %s\n', ME.message);
end

% 看 getString 试试
fprintf('\n[imp] === try getString for known props ===\n');
for i = 1:length(prop_names)
    pn = prop_names{i};
    try
        v = new_int.getString(pn);
        fprintf('[imp] getString(%s): %s\n', pn, char(v));
    catch ME
        % silent
    end
end

clearvars m;
fprintf('\n[imp] DONE\n');
'''

# 准备测试数据 .txt（空格分隔）
test_txt = WORK / "test_data.txt"
with open(test_txt, "w") as f:
    f.write("0 0 0 1.0\n")
    f.write("0.1 0 0 2.0\n")
    f.write("0.2 0 0 3.0\n")

script = TEMPLATE.replace("<<MPH>>", str(PROJECT_ROOT / "COMSOL/livelink_model.mph").replace("\\", "/"))
script = script.replace("<<TEST_TXT>>", str(test_txt).replace("\\", "/"))

matlab_file = WORK / "import_test.m"
matlab_file.write_text(script, encoding="utf-8", errors="replace")

print("Testing importData API...")
runner = PROJECT_ROOT / "engine/sdk/forward_pipeline/scripts/livelink_runner.py"
import os
proc = subprocess.run(
    ["python", "-X", "utf8", str(runner), str(matlab_file), str(WORK)],
    env={**os.environ, "PYTHONIOENCODING": "utf-8"}
)
print(f"\nexit: {proc.returncode}")
