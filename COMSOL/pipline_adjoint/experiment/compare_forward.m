function compare_forward()
%COMPARE_FORWARD 对比主管线和管线2的正演散射场是否一致
%
%   两个模型都设 R_inner=0.06m, eps_r=5.0
%   提取 288 个测量点的散射场 E_scat, H_scat
%   逐点比较幅度和相位

this_dir = fileparts(mfilename('fullpath'));
pipeline_dir = fileparts(this_dir);
cd(pipeline_dir);  % cd 到 pipline_adjoint 根目录

addpath('config','utils','core_forward','core_jobs','core_jhyp','experiment');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  正演散射场对比：主管线 vs 管线2\n');
fprintf('#  R_inner=0.06m, eps_r=5.0, 1GHz\n');
fprintf('############################################################\n\n');

%% 1. 连接 COMSOL
try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart: %s\n', ME.message); return;
    end
end

%% 2. 主管线正演
fprintf('===== 主管线 (livelink_model.mph) =====\n');
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

p1 = config();  % 管线2 config（R_inner=0.06）
model1 = mphload(p1.comsol_model_path);
try model1.geom('geom1').run; catch, end
try model1.mesh('mesh1').run; catch, end

phys1 = model1.physics('emw');
try phys1.feature('vec1'); catch
    phys1.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys1.feature('vec1').set('Je', {'0','0','0'});
    try phys1.feature('vec1').selection().all(); catch, end
end
try model1.param.set('adjoint_mode', '1'); catch, end

% 设 eps_r=5
voxel1 = fem_mesh_utils(model1, p1, p1.R_inner);
inner1 = voxel1.mask_interior;
voxel1.epsilon_r(inner1) = 5.0;
update_epsilon(model1, voxel1, p1);

% 确保正演模式
try phys1.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
model1.param.set('freq', num2str(p1.freq));
try model1.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p1.freq)); catch, end
try model1.sol('sol1').clearSolutionData(); catch, end
try model1.sol('sol1').clearSolution(); catch, end

% PARDISO
try
    s1 = model1.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
    end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end

model1.sol('sol1').runAll();
fprintf('  主管线正演完成\n');

grid1 = build_measurement_grid(p1);
sf1 = extract_scattered(model1, grid1);
lc1 = lightcone_project(grid1, sf1, p1);
J_obs1 = lc1.J_obs_perp;

fprintf('  |E_scat| mean=%.4e\n', mean(vecnorm(sf1.E_cart,2,2)));
fprintf('  |J_obs| mean=%.4e\n', mean(vecnorm(J_obs1,2,2)));

%% 3. 加载主管线 livelink_model.mph
fprintf('\n===== 主管线 (livelink_model.mph) =====\n');
p_main.base_path = 'd:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL';
model_main_path = fullfile(p_main.base_path, 'livelink_model.mph');

if ~exist(model_main_path, 'file')
    fprintf('[SKIP] livelink_model.mph 不存在\n');
else
    % 用主管线的 config 参数（R=0.06, 12x24, N_k=16）
    p_main = p1;  % 复用管线2的 config
    p_main.comsol_model_path = model_main_path;

    try
        tags = ModelUtil.tags();
        for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
    catch
    end

    model_main = mphload(model_main_path);
    try model_main.geom('geom1').run; catch, end
    try model_main.mesh('mesh1').run; catch, end

    phys_main = model_main.physics('emw');
    try phys_main.feature('vec1'); catch
        phys_main.feature().create('vec1', 'ExternalCurrentDensity', 3);
        phys_main.feature('vec1').set('Je', {'0','0','0'});
        try phys_main.feature('vec1').selection().all(); catch, end
    end
    try model_main.param.set('adjoint_mode', '1'); catch, end

    % 设 eps_r=5（用主管线的网格）
    voxel_main = fem_mesh_utils(model_main, p_main, p_main.R_inner);
    inner_main = voxel_main.mask_interior;
    N_main = sum(inner_main);
    fprintf('  主管线内部体素: %d\n', N_main);
    voxel_main.epsilon_r(inner_main) = 5.0;
    update_epsilon(model_main, voxel_main, p_main);

    try phys_main.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    model_main.param.set('freq', num2str(p_main.freq));
    try model_main.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p_main.freq)); catch, end
    try model_main.sol('sol1').clearSolutionData(); catch, end
    try model_main.sol('sol1').clearSolution(); catch, end

    try
        s1m = model_main.sol('sol1').feature('s1');
        try s1m.feature('dDirect'); catch
            s1m.create('dDirect','Direct'); s1m.feature('dDirect').set('linsolver','pardiso');
        end
        try s1m.feature('fc1').set('linsolver','dDirect'); catch, end
    catch
    end

    model_main.sol('sol1').runAll();
    fprintf('  主管线正演完成\n');

    grid_main = build_measurement_grid(p_main);
    sf_main = extract_scattered(model_main, grid_main);
    lc_main = lightcone_project(grid_main, sf_main, p_main);
    J_obs_main = lc_main.J_obs_perp;

    fprintf('  |E_scat| mean=%.4e\n', mean(vecnorm(sf_main.E_cart,2,2)));
    fprintf('  |J_obs| mean=%.4e\n', mean(vecnorm(J_obs_main,2,2)));

    %% 4. 逐点对比
    fprintf('\n############################################################\n');
    fprintf('#  散射场逐点对比\n');
    fprintf('############################################################\n');

    % 散射场 E 对比
    E1 = sf1.E_cart;
    E2 = sf_main.E_cart;
    [N_pts, ~] = size(E1);
    fprintf('  测量点数: %d（两个管线相同网格）\n', N_pts);

    % 逐点相对误差
    E_diff = E1 - E2;
    rel_err_E = vecnorm(E_diff, 2, 2) ./ max(vecnorm(E1, 2, 2), 1e-30);
    fprintf('  E_scat 相对误差:\n');
    fprintf('    mean = %.6e\n', mean(rel_err_E));
    fprintf('    max  = %.6e\n', max(rel_err_E));
    fprintf('    median = %.6e\n', median(rel_err_E));

    % J_obs 对比
    J1 = J_obs1;
    J2 = J_obs_main;
    J_diff = J1 - J2;
    rel_err_J = vecnorm(J_diff, 2, 2) ./ max(vecnorm(J1, 2, 2), 1e-30);
    fprintf('\n  J_obs 相对误差:\n');
    fprintf('    mean = %.6e\n', mean(rel_err_J));
    fprintf('    max  = %.6e\n', max(rel_err_J));
    fprintf('    median = %.6e\n', median(rel_err_J));

    % 判定
    fprintf('\n');
    if mean(rel_err_E) < 1e-6 && mean(rel_err_J) < 1e-6
        fprintf('  ★★★ 两个模型的正演散射场完全一致 ★★★\n');
    elseif mean(rel_err_E) < 0.01
        fprintf('  ★ 两个模型的正演散射场基本一致（<1%% 偏差）★\n');
    else
        fprintf('  ⚠ 两个模型的正演散射场存在显著差异（>1%%）\n');
        fprintf('    可能原因：网格密度不同、PML 配置不同、几何域编号不同\n');
    end
    fprintf('############################################################\n');

    % 恢复
    try phys_main.feature('vec1').set('Je', {'0','0','0'}); catch, end
    try phys_main.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    try model_main.param.set('adjoint_mode', '1'); catch, end
end

% 恢复管线2模型
try phys1.feature('vec1').set('Je', {'0','0','0'}); catch, end
try phys1.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model1.param.set('adjoint_mode', '1'); catch, end

end
