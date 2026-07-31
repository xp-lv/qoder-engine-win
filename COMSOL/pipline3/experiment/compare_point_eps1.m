function compare_point_eps1()
%COMPARE_POINT_EPS1 两个模型 eps_r=1（全空气）在 (0.07,0,0) 的总场

this_dir = fileparts(mfilename('fullpath'));
pipeline_dir = fileparts(this_dir);
cd(pipeline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','experiment');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  eps_r=1（全空气）总场对比\n');
fprintf('#  点 (0.07, 0, 0)\n');
fprintf('############################################################\n\n');

obs_pt = [0.07; 0; 0];

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL]\n'); return;
    end
end

%% 管线2
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
try model2.param.set('adjoint_mode', '1'); catch, end

% 用体素注入 eps_r=1（内部和外部都是1）
voxel2 = fem_mesh_utils(model2, p, p.R_inner);
voxel2.epsilon_r(:) = 1.0;  % 全部设为1
update_epsilon(model2, voxel2, p);

% 背景场 + 求解
try phys2.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
model2.param.set('freq', num2str(p.freq));
try model2.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model2.sol('sol1').clearSolutionData(); catch, end
try model2.sol('sol1').clearSolution(); catch, end
try
    s1 = model2.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
    end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end
model2.sol('sol1').runAll();

% 查询
E2 = [mphinterp(model2,'emw.Ex','coord',obs_pt), ...
      mphinterp(model2,'emw.Ey','coord',obs_pt), ...
      mphinterp(model2,'emw.Ez','coord',obs_pt)];
Ebg2 = [mphinterp(model2,'emw.Ebx','coord',obs_pt), ...
        mphinterp(model2,'emw.Eby','coord',obs_pt), ...
        mphinterp(model2,'emw.Ebz','coord',obs_pt)];
fprintf('  E_total = [%.6e, %.6e, %.6e]\n', E2(1), E2(2), E2(3));
fprintf('  E_bg    = [%.6e, %.6e, %.6e]\n', Ebg2(1), Ebg2(2), Ebg2(3));
fprintf('  E_scat  = [%.6e, %.6e, %.6e]\n', E2(1)-Ebg2(1), E2(2)-Ebg2(2), E2(3)-Ebg2(3));

%% 主管线
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
try model1.param.set('adjoint_mode', '1'); catch, end

% 用体素注入 eps_r=1
voxel1 = fem_mesh_utils(model1, p, p.R_inner);
voxel1.epsilon_r(:) = 1.0;
update_epsilon(model1, voxel1, p);

try phys1.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
model1.param.set('freq', num2str(p.freq));
try model1.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model1.sol('sol1').clearSolutionData(); catch, end
try model1.sol('sol1').clearSolution(); catch, end
try
    s1 = model1.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
    end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end
model1.sol('sol1').runAll();

E1 = [mphinterp(model1,'emw.Ex','coord',obs_pt), ...
      mphinterp(model1,'emw.Ey','coord',obs_pt), ...
      mphinterp(model1,'emw.Ez','coord',obs_pt)];
Ebg1 = [mphinterp(model1,'emw.Ebx','coord',obs_pt), ...
        mphinterp(model1,'emw.Eby','coord',obs_pt), ...
        mphinterp(model1,'emw.Ebz','coord',obs_pt)];
fprintf('  E_total = [%.6e, %.6e, %.6e]\n', E1(1), E1(2), E1(3));
fprintf('  E_bg    = [%.6e, %.6e, %.6e]\n', Ebg1(1), Ebg1(2), Ebg1(3));
fprintf('  E_scat  = [%.6e, %.6e, %.6e]\n', E1(1)-Ebg1(1), E1(2)-Ebg1(2), E1(3)-Ebg1(3));

%% 对比
fprintf('\n############################################################\n');
fprintf('#  对比（eps_r=1，全空气）\n');
fprintf('############################################################\n');
fprintf('            管线2              主管线            差值\n');
fprintf('  Ex  %+.6e  %+.6e  %+.6e\n', E2(1), E1(1), E2(1)-E1(1));
fprintf('  Ey  %+.6e  %+.6e  %+.6e\n', E2(2), E1(2), E2(2)-E1(2));
fprintf('  Ez  %+.6e  %+.6e  %+.6e\n', E2(3), E1(3), E2(3)-E1(3));
fprintf('\n');
fprintf('  背景场 Ebz: 管线2=%.4f, 主管线=%.4f\n', real(Ebg2(3)), real(Ebg1(3)));
fprintf('  散射场 Ez:  管线2=%.6e, 主管线=%.6e\n', E2(3)-Ebg2(3), E1(3)-Ebg1(3));
fprintf('\n');
rel = norm(E2-E1) / max(norm(E2), 1e-30);
fprintf('  总场相对差异 = %.6e\n', rel);
if rel < 1e-4
    fprintf('  ★ 总场基本一致（PML反射差异 <0.01%%）★\n');
else
    fprintf('  ⚠ 总场存在差异（PML反射）\n');
end
fprintf('############################################################\n');

try ModelUtil.remove('Model'); catch, end

end
