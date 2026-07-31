function compare_point()
%COMPARE_POINT 对比两个模型在单点的总场 E
%
%   eps_r=1（纯空气），背景场 Eb=[0,0,1]
%   观察点 (0.07, 0, 0)
%   如果几何和背景场完全一致，此点总场应等于背景场 E=[0,0,1]（无散射体）

this_dir = fileparts(mfilename('fullpath'));
pipeline_dir = fileparts(this_dir);
cd(pipeline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','experiment');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  单点总场对比 (eps_r=1, 无散射体)\n');
fprintf('#  eps_r=2.0, 观察点: x=0.07, y=0, z=0\n');
fprintf('############################################################\n\n');

obs_pt = [0.07; 0; 0];  % [3x1] for mphinterp

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart\n'); return;
    end
end

%% 1. 管线2 (2layer.mph)
fprintf('===== 管线2 (2layer.mph) =====\n');
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

p = config();
model2 = mphload(p.comsol_model_path);
try model2.geom('geom1').run; catch, end
try model2.mesh('mesh1').run; catch, end

phys2 = model2.physics('emw');
try phys2.feature('vec1'); catch
    phys2.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys2.feature('vec1').set('Je', {'0','0','0'});
    try phys2.feature('vec1').selection().all(); catch, end
end

% eps_r=2（均匀介质球）
voxel2 = fem_mesh_utils(model2, p, p.R_inner);
inner2 = voxel2.mask_interior;
voxel2.epsilon_r(inner2) = 2.0;
update_epsilon(model2, voxel2, p);
fprintf('  eps_r=2.0 注入完成 (N_inner=%d)\n', sum(inner2));

% 背景场 Eb=[0,0,1]
try phys2.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model2.param.set('adjoint_mode', '1'); catch, end
model2.param.set('freq', num2str(p.freq));
try model2.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end

% PARDISO
try
    s1 = model2.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
    end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end

try model2.sol('sol1').clearSolutionData(); catch, end
try model2.sol('sol1').clearSolution(); catch, end
model2.sol('sol1').runAll();

% 提取观察点总场
Ex2 = mphinterp(model2, 'emw.Ex', 'coord', obs_pt);
Ey2 = mphinterp(model2, 'emw.Ey', 'coord', obs_pt);
Ez2 = mphinterp(model2, 'emw.Ez', 'coord', obs_pt);
E2 = [Ex2, Ey2, Ez2];
fprintf('  E = [%.6e, %.6e, %.6e]\n', real(E2(1)), real(E2(2)), real(E2(3)));
fprintf('  |E| = %.6e\n', abs(E2(1)) + abs(E2(2)) + abs(E2(3)));

%% 2. 主管线 (livelink_model.mph)
fprintf('\n===== 主管线 (livelink_model.mph) =====\n');
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

model1 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
try model1.geom('geom1').run; catch, end
try model1.mesh('mesh1').run; catch, end

phys1 = model1.physics('emw');
try phys1.feature('vec1'); catch
    phys1.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys1.feature('vec1').set('Je', {'0','0','0'});
    try phys1.feature('vec1').selection().all(); catch, end
end

% eps_r=2（均匀介质球）
voxel1 = fem_mesh_utils(model1, p, p.R_inner);
inner1 = voxel1.mask_interior;
voxel1.epsilon_r(inner1) = 2.0;
update_epsilon(model1, voxel1, p);
fprintf('  eps_r=2.0 注入完成 (N_inner=%d)\n', sum(inner1));

% 背景场 Eb=[0,0,1]
try phys1.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model1.param.set('adjoint_mode', '1'); catch, end
model1.param.set('freq', num2str(p.freq));
try model1.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end

% PARDISO
try
    s1 = model1.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
    end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end

try model1.sol('sol1').clearSolutionData(); catch, end
try model1.sol('sol1').clearSolution(); catch, end
model1.sol('sol1').runAll();

% 提取观察点总场
Ex1 = mphinterp(model1, 'emw.Ex', 'coord', obs_pt);
Ey1 = mphinterp(model1, 'emw.Ey', 'coord', obs_pt);
Ez1 = mphinterp(model1, 'emw.Ez', 'coord', obs_pt);
E1 = [Ex1, Ey1, Ez1];
fprintf('  E = [%.6e, %.6e, %.6e]\n', real(E1(1)), real(E1(2)), real(E1(3)));
fprintf('  |E| = %.6e\n', abs(E1(1)) + abs(E1(2)) + abs(E1(3)));

%% 3. 对比
fprintf('\n############################################################\n');
fprintf('#  点 (0.07, 0, 0) 总场对比\n');
fprintf('############################################################\n');
fprintf('  管线2 E  = [%.8e, %.8e, %.8e]\n', E2(1), E2(2), E2(3));
fprintf('  主管线 E = [%.8e, %.8e, %.8e]\n', E1(1), E1(2), E1(3));
fprintf('  差值     = [%.8e, %.8e, %.8e]\n', E2(1)-E1(1), E2(2)-E1(2), E2(3)-E1(3));
fprintf('\n');
fprintf('  理论值（平面波 E=[0,0,1]）：\n');
fprintf('  管线2 偏差 = %.4e\n', abs(E2(3) - 1));
fprintf('  主管线偏差 = %.4e\n', abs(E1(3) - 1));

E_diff = E2 - E1;
rel = norm(E_diff) / max(norm(E2), 1e-30);
fprintf('\n  相对差异 = %.6e\n', rel);
if rel < 1e-6
    fprintf('  ★ 两个模型在此点的总场完全一致 ★\n');
elseif rel < 0.01
    fprintf('  ★ 基本一致（<1%%）★\n');
else
    fprintf('  ⚠ 存在显著差异\n');
end
fprintf('############################################################\n');

% 清理
try ModelUtil.remove('Model'); catch, end

end
