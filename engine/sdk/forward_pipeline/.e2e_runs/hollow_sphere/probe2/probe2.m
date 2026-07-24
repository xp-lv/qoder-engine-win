
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');

fprintf('\n[probe2] === wee1 properties ===\n');
try
    wee1 = m.physics('emw').feature('wee1');
    fprintf('[probe2] wee1.type: %s\n', char(wee1.type));
    pn = wee1.propnames;
    fprintf('[probe2] wee1 propnames (%d):\n', length(pn));
    for i = 1:length(pn)
        try
            val = wee1.get(pn{i});
            val_str = char(val);
            if length(val_str) > 80, val_str = [val_str(1:80) '...']; end
            fprintf('[probe2]   %s = %s\n', pn{i}, val_str);
        catch
            fprintf('[probe2]   %s = (no value)\n', pn{i});
        end
    end
catch ME
    fprintf('[probe2] wee1 query failed: %s\n', ME.message);
end

fprintf('\n[probe2] === int2 properties ===\n');
try
    int2 = m.func('int2');
    pn = int2.propnames;
    fprintf('[probe2] int2 propnames (%d):\n', length(pn));
    for i = 1:length(pn)
        try
            val = int2.get(pn{i});
            val_str = char(val);
            if length(val_str) > 100, val_str = [val_str(1:100) '...']; end
            fprintf('[probe2]   %s = %s\n', pn{i}, val_str);
        catch
            fprintf('[probe2]   %s = (no value)\n', pn{i});
        end
    end
catch ME
    fprintf('[probe2] int2 query failed: %s\n', ME.message);
end

% 尝试不同方式访问 table
fprintf('\n[probe2] === int2 table access attempts ===\n');
try
    t = m.func('int2').getTable('table');
    fprintf('[probe2] getTable OK, size: %s\n', mat2str(size(t)));
    fprintf('[probe2] first 3 rows:\n');
    disp(t(1:min(3, size(t,1)), :));
catch ME1
    fprintf('[probe2] getTable failed: %s\n', ME1.message);
end
try
    src = m.func('int2').get('source');
    fprintf('[probe2] int2.source: %s\n', char(src));
catch
end
try
    fname = m.func('int2').get('filename');
    fprintf('[probe2] int2.filename: %s\n', char(fname));
catch
end
try
    funcs = m.func.tags;
    fprintf('[probe2] func.tags class: %s\n', class(funcs));
catch
end

% 试 m.func.remove('int2') vs m.func('int2').remove
fprintf('\n[probe2] === remove API test ===\n');
fprintf('[probe2] Trying m.func(''int2'').remove...\n');
try
    m.func('int2').remove;
    fprintf('[probe2] m.func(''int2'').remove: OK\n');
catch ME
    fprintf('[probe2] m.func(''int2'').remove failed: %s\n', ME.message);
end

% 不要真删，只是为了测试 API 是否存在
% 如果删了，后面没法测试
try
    % 重新加载看看
    m2 = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');
    fprintf('[probe2] Reloaded model for further tests\n');
    m = m2;
catch ME
    fprintf('[probe2] reload failed: %s\n', ME.message);
end

clearvars m m2;
fprintf('\n[probe2] === DONE ===\n');
