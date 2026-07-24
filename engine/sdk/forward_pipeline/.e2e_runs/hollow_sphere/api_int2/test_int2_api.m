
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');

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
    m.func('int2_test').set('filename', 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/api_int2/test_small.csv');
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
