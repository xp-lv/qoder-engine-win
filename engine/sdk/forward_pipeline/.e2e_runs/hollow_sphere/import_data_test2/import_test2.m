addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');

fprintf('[imp] === Setup ===\n');
try
    m.func.remove('int2_new');
catch
end

m.func.create('int2_new', 'Interpolation');
new_int = m.func('int2_new');

fprintf('\n[imp] === Try importData(filepath) ===\n');
try
    new_int.importData('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/import_data_test2/test_data.txt');
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
