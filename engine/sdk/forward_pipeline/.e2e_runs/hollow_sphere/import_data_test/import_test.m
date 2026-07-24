
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');

fprintf('\n[imp] === Test importData ===\n');
try
    m.func.remove('int2_new');
catch
end

m.func.create('int2_new', 'Interpolation');
new_int = m.func('int2_new');

% 看 importData 的方法签名
fprintf('[imp] importData methods:\n');
md = methods(new_int, 'importData');
for i = 1:length(md)
    fprintf('  %s\n', md{i});
end

% 尝试 importData(filepath)
fprintf('\n[imp] --- call importData ---\n');
try
    new_int.importData('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/import_data_test/test_data.txt');
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
