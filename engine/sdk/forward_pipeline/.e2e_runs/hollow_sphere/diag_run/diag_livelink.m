
addpath('D:/LenovoSoftstore/Install/COMSOL62/Multiphysics/mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

fprintf('[diag] === Loading .mph ===\n');
try
    m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');
    fprintf('[diag] Model loaded\n');
catch ME
    fprintf('[diag][FATAL] mphload failed: %s\n', ME.message);
    error('done');
end

% 探查模型结构
physics_tags = m.physics.tags;
study_tags = m.study.tags;
geom_tags = m.geom.tags;
mesh_tags = m.mesh.tags;
sol_tags = m.sol.tags;
fprintf('[diag] Physics tags:\n'); disp(physics_tags);
fprintf('[diag] Study tags:\n'); disp(study_tags);
fprintf('[diag] Geom tags:\n'); disp(geom_tags);
fprintf('[diag] Mesh tags:\n'); disp(mesh_tags);
fprintf('[diag] Sol tags:\n'); disp(sol_tags);

% emw feature 列表
try
    emw_feats = m.physics('emw').features;
    fprintf('[diag] emw features:\n'); disp(emw_feats.tags);
catch ME
    fprintf('[diag][WARN] emw features query failed: %s\n', ME.message);
end

% BackgroundField
try
    sf = m.physics('emw').prop('BackgroundField').get('SolveFor');
    wt = m.physics('emw').prop('BackgroundField').get('WaveType');
    fprintf('[diag] BackgroundField.SolveFor: %s\n', sf);
    fprintf('[diag] BackgroundField.WaveType: %s\n', wt);
catch ME
    fprintf('[diag][WARN] BackgroundField get failed: %s\n', ME.message);
end

% Study freq
try
    plist = m.study('std1').feature('freq').get('plist');
    fprintf('[diag] std1/freq plist: %s\n', plist);
catch ME
    fprintf('[diag][WARN] std1/freq plist get failed: %s\n', ME.message);
end

% 求解
fprintf('[diag] === Running study ===\n');
try
    m.study('std1').run;
    fprintf('[diag] Study run OK\n');
catch ME
    fprintf('[diag][ERROR] study.run failed: %s\n', ME.message);
    try
        m.sol('sol1').runAll;
        fprintf('[diag] sol.runAll OK\n');
    catch ME2
        fprintf('[diag][ERROR] sol.runAll also failed: %s\n', ME2.message);
    end
end

% 提取场值
fprintf('[diag] === Field validation ===\n');
test_pts = [0 0 0; 0.1 0 0; 0 0 0.1; 0.2 0 0]';
var_names = {'emw.Ez', 'emw.relEz', 'ewfd.Ez', 'ewfd.relEz'};
for vi = 1:length(var_names)
    var = var_names{vi};
    try
        val = mphinterp(m, var, 'dataset', 'dset1', 'coord', test_pts);
        abs_val = abs(val);
        fprintf('[diag] %s: %.4e %.4e %.4e %.4e\n', var, abs_val(1), abs_val(2), abs_val(3), abs_val(4));
    catch ME
        fprintf('[diag][skip] %s: %s\n', var, ME.message);
    end
end

try
    dsets = m.result.dataset.tags;
    fprintf('[diag] datasets:\n'); disp(dsets);
catch
end

ModelUtil.disconnect;
fprintf('[diag] === DONE ===\n');
