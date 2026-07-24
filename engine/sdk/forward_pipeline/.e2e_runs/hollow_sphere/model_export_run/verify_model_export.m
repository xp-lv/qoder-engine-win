
addpath('D:/LenovoSoftstore/Install/COMSOL62/Multiphysics/mli');
addpath('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

fprintf('[verify] === Running model_export.m ===\n');
m = model_export();
fprintf('[verify] Model created, modelPath=%s\n', m.modelPath);

% 验证关键节点存在
fprintf('[verify] Physics tags: %s\n', strjoin(m.physics.tags));
fprintf('[verify] Study tags: %s\n', strjoin(m.study.tags));
fprintf('[verify] Geometry tags: %s\n', strjoin(m.geom.tags));
fprintf('[verify] Mesh tags: %s\n', strjoin(m.mesh.tags));

% 检查 emw 物理场的背景场设置
try
    solveFor = m.physics('emw').prop('BackgroundField').get('SolveFor');
    fprintf('[verify] emw BackgroundField.SolveFor: %s\n', solveFor);
catch ME
    fprintf('[verify][WARN] BackgroundField get failed: %s\n', ME.message);
end

% 检查 sctr1 特征
try
    sctr_sel = m.physics('emw').feature('sctr1').selection;
    fprintf('[verify] sctr1 selection: %s\n', strjoin(sctr_sel));
catch ME
    fprintf('[verify][WARN] sctr1 not found or selection get failed: %s\n', ME.message);
end

% 尝试跑一次求解
fprintf('[verify] === Running solve ===\n');
try
    m.study('std1').run;
    fprintf('[verify] Study run completed\n');
catch ME
    fprintf('[verify][ERROR] Study run failed: %s\n', ME.message);
end

% 验证场值（用 mphinterp coord）
fprintf('[verify] === Field validation ===\n');
test_pts = [0 0 0; 0.1 0 0; 0 0 0.1; 0.2 0 0]';
try
    Ez = mphinterp(m, 'emw.Ez', 'dataset', 'dset1', 'coord', test_pts);
    fprintf('[verify] Ez at (0,0,0):   %.4e\n', abs(Ez(1)));
    fprintf('[verify] Ez at (0.1,0,0): %.4e\n', abs(Ez(2)));
    fprintf('[verify] Ez at (0,0,0.1): %.4e\n', abs(Ez(3)));
    fprintf('[verify] Ez at (0.2,0,0): %.4e\n', abs(Ez(4)));

    relEz = mphinterp(m, 'emw.relEz', 'dataset', 'dset1', 'coord', test_pts);
    fprintf('[verify] relEz at (0,0,0):   %.4e\n', abs(relEz(1)));
    fprintf('[verify] relEz at (0.1,0,0): %.4e\n', abs(relEz(2)));
catch ME
    fprintf('[verify][ERROR] mphinterp failed: %s\n', ME.message);
end

% 存为 .mph
fprintf('[verify] === Saving model to .mph ===\n');
try
    m.save('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/model_export_run/model_exported.mph', 'compressed');
    fprintf('[verify] Saved: %s\n', 'D:\ZJU\PROJECT\2026-07-02-qoder-engine\engine\sdk\forward_pipeline\.e2e_runs\hollow_sphere\model_export_run\model_exported.mph');
catch ME
    fprintf('[verify][ERROR] save failed: %s\n', ME.message);
end

ModelUtil.disconnect;
fprintf('[verify] === DONE ===\n');
