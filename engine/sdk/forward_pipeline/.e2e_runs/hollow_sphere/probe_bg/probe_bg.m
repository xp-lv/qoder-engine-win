addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');

fprintf('\n[bg] === BackgroundField prop ===\n');
bf = m.physics('emw').prop('BackgroundField');
fprintf('[bg] class: %s\n', class(bf));

% 列出所有可用属性
prop_names = {'SolveFor', 'WaveType', 'Ebg', 'Ebgx', 'Ebgy', 'Ebgz', ...
              'Hbg', 'kdir', 'kvector', 'E0', 'amp', 'phase', ...
              'gaussianWidth', 'beamWidth', 'polarization', ...
              'direction', 'wavevector', 'kx', 'ky', 'kz'};
for i = 1:length(prop_names)
    pn = prop_names{i};
    try
        has = bf.hasProperty(pn);
        if has
            try
                val = bf.get(pn);
                fprintf('[bg] %s = %s\n', pn, char(val));
            catch
                fprintf('[bg] %s: (has but cannot get)\n', pn);
            end
        end
    catch
        % silent
    end
end

% 列出 prop 的所有方法
fprintf('\n[bg] === bf methods (set/get) ===\n');
all_methods = methods(bf);
for i = 1:length(all_methods)
    mn = all_methods{i};
    if startsWith(mn, 'set') || startsWith(mn, 'get') || startsWith(mn, 'has')
        fprintf('  %s\n', mn);
    end
end

% 列出 prop 的所有属性（用 propnames）
fprintf('\n[bg] === propnames ===\n');
try
    pn_all = bf.propnames;
    for i = 1:length(pn_all)
        fprintf('  %s\n', pn_all{i});
    end
catch ME
    fprintf('[bg] propnames fail: %s\n', ME.message);
end

% 看 variables (var1, var2...) 里的背景场相关定义
fprintf('\n[bg] === variables ===\n');
try
    var_tags = m.variable.tags;
    fprintf('[bg] variable tags: '); disp(var_tags);
    for vi = 1:length(var_tags)
        vt = var_tags{vi};
        try
            var_names = m.variable(vt).names;
            fprintf('[bg] variable(%s) names:\n', vt);
            for ni = 1:length(var_names)
                try
                    val = m.variable(vt).get(var_names{ni});
                                    if length(val) > 80, val = [val(1:80) '...']; end
                    fprintf('[bg]   %s = %s\n', var_names{ni}, val);
                catch
                    fprintf('[bg]   %s = (no value)\n', var_names{ni});
                end
            end
        catch ME
            fprintf('[bg] variable(%s) fail: %s\n', vt, ME.message);
        end
    end
catch ME
    fprintf('[bg] variable tags fail: %s\n', ME.message);
end

% 看 parameters
fprintf('\n[bg] === model.param ===\n');
try
    param_names = m.param.names;
    fprintf('[bg] param names: '); disp(param_names);
    for pi = 1:length(param_names)
        pn = param_names{pi};
        try
            val = m.param.get(pn);
            if length(val) > 80, val = [val(1:80) '...']; end
            fprintf('[bg]   param %s = %s\n', pn, val);
        catch
        end
    end
catch ME
    fprintf('[bg] param fail: %s\n', ME.message);
end

clearvars m;
fprintf('\n[bg] DONE\n');
