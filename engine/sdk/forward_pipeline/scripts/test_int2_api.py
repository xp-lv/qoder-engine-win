"""快速测试 LiveLink 创建 Interpolation function 的正确 API。

COMSOL 要求 table 是 cell array of strings，不是数值矩阵。
测试几种写法找出正确的。"""
import subprocess
import sys
import io
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

PROJECT_ROOT = Path(__file__).resolve().parents[4]
WORK = PROJECT_ROOT / "engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/api_int2"
WORK.mkdir(parents=True, exist_ok=True)

TEMPLATE = r'''
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('<<MPH>>');

% 删掉旧的
try
    m.func.remove('int2');
catch
end
try
    m.func.remove('int2_test');
catch
end

fprintf('\n[test] === Try 1: numeric matrix ===\n');
try
    m.func.create('int2_test', 'Interpolation');
    small_data = [0 0 0 1.0; 0.1 0 0 2.0; 0.2 0 0 3.0];
    m.func('int2_test').set('table', small_data);
    fprintf('[test] numeric matrix: OK\n');
catch ME
    fprintf('[test] numeric matrix FAIL: %s\n', ME.message);
    try
        m.func.remove('int2_test');
    catch
    end
end

fprintf('\n[test] === Try 2: cell array of strings ===\n');
try
    m.func.create('int2_test', 'Interpolation');
    cell_data = {'0' '0' '0' '1.0'; '0.1' '0' '0' '2.0'; '0.2' '0' '0' '3.0'};
    m.func('int2_test').set('table', cell_data);
    fprintf('[test] cell of strings: OK\n');
catch ME
    fprintf('[test] cell of strings FAIL: %s\n', ME.message);
    try
        m.func.remove('int2_test');
    catch
    end
end

fprintf('\n[test] === Try 3: cell array of numbers ===\n');
try
    m.func.create('int2_test', 'Interpolation');
    cell_data = num2cell([0 0 0 1.0; 0.1 0 0 2.0; 0.2 0 0 3.0]);
    m.func('int2_test').set('table', cell_data);
    fprintf('[test] cell of numbers: OK\n');
catch ME
    fprintf('[test] cell of numbers FAIL: %s\n', ME.message);
    try
        m.func.remove('int2_test');
    catch
    end
end

fprintf('\n[test] === Try 4: setIndex row by row ===\n');
try
    m.func.create('int2_test', 'Interpolation');
    % 先设置 argstr
    m.func('int2_test').set('argstr', 'x y z');
    m.func('int2_test').set('funcname', 'int2_test');
    % setIndex 单个值
    m.func('int2_test').setIndex('table', '0', [1 1]);
    m.func('int2_test').setIndex('table', '0', [1 2]);
    m.func('int2_test').setIndex('table', '0', [1 3]);
    m.func('int2_test').setIndex('table', '1.0', [1 4]);
    m.func('int2_test').setIndex('table', '0.1', [2 1]);
    m.func('int2_test').setIndex('table', '0', [2 2]);
    m.func('int2_test').setIndex('table', '0', [2 3]);
    m.func('int2_test').setIndex('table', '2.0', [2 4]);
    fprintf('[test] setIndex: OK\n');
catch ME
    fprintf('[test] setIndex FAIL: %s\n', ME.message);
    try
        m.func.remove('int2_test');
    catch
    end
end

fprintf('\n[test] === Try 5: cell of formatted strings ===\n');
try
    m.func.create('int2_test', 'Interpolation');
    m.func('int2_test').set('argstr', 'x y z');
    m.func('int2_test').set('funcname', 'int2_test');
    % 把数值表格式化为字符串矩阵
    small_data = [0 0 0 1.0; 0.1 0 0 2.0];
    str_rows = cell(size(small_data, 1), 1);
    for ri = 1:size(small_data, 1)
        str_rows{ri} = strtrim(sprintf('%.6f %.6f %.6f %.6f', small_data(ri, :)));
    end
    fprintf('[test] str_rows:\n');
    disp(str_rows);
    m.func('int2_test').set('table', str_rows);
    fprintf('[test] string cell: OK\n');
catch ME
    fprintf('[test] string cell FAIL: %s\n', ME.message);
    try
        m.func.remove('int2_test');
    catch
    end
end

fprintf('\n[test] === Try 6: 从文件加载 ===\n');
try
    m.func.create('int2_test', 'Interpolation');
    m.func('int2_test').set('argstr', 'x y z');
    m.func('int2_test').set('funcname', 'int2_test');
    m.func('int2_test').set('source', 'file');
    m.func('int2_test').set('filename', '<<TEST_CSV>>');
    fprintf('[test] file source: OK\n');
catch ME
    fprintf('[test] file source FAIL: %s\n', ME.message);
    try
        m.func.remove('int2_test');
    catch
    end
end

fprintf('\n[test] === 最终 func.tags ===\n');
disp(m.func.tags);

clearvars m;
fprintf('\n[test] DONE\n');
'''

# 生成小测试 CSV
test_csv = WORK / "test_small.csv"
with open(test_csv, "w") as f:
    f.write("0,0,0,1.0\n0.1,0,0,2.0\n0.2,0,0,3.0\n")

script = TEMPLATE.replace("<<MPH>>", str(PROJECT_ROOT / "COMSOL/livelink_model.mph").replace("\\", "/"))
script = script.replace("<<TEST_CSV>>", str(test_csv).replace("\\", "/"))

matlab_file = WORK / "test_int2_api.m"
matlab_file.write_text(script, encoding="utf-8", errors="replace")

print("Testing int2 API variants...")
runner = PROJECT_ROOT / "engine/sdk/forward_pipeline/scripts/livelink_runner.py"
cmd = ["python", "-X", "utf8", str(runner), str(matlab_file), str(WORK)]
import os
proc = subprocess.run(cmd, env={**os.environ, "PYTHONIOENCODING": "utf-8"})
print(f"\nexit: {proc.returncode}")
