function diagnose_background_field()
%DIAGNOSE_BACKGROUND_FIELD 检查 adjoint_mode=0 时背景场残余 + lambda 场分布
%
%   验证 3 件事：
%   1. adjoint_mode=0 时 Eb（背景场）是否真的为零
%   2. lambda 场在体素点的空间分布（是否有异常）
%   3. lambda 场在 Gauss 点 vs 质心的差异

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  背景场残余 + lambda 场分布诊断\n');
fprintf('############################################################\n\n');

%% 初始化
p = config();
grid = build_measurement_grid(p);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart: %s\n', ME.message); return;
    end
end
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end
voxel = fem_mesh_utils(model, p, p.a_scatter);

eps_r_test = 4.0; hole_pos_test = [0.015; 0.010; 0.005];
delta_sdf = 0.008;
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);

%% 正演
fprintf('[BF] 正演...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = p; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

%% 构建 Ms-only 伴随源
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);

% 简单的 Delta_J（全 1 的测试向量）
Delta_J_test = ones(64, 3);
J_obs_test = ones(64, 3);
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs_test;
lc.Delta_J_perp = Delta_J_test;

[Js_full, Ms_full, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, pf);
Js_zero = zeros(size(Js_full));

%% ====== 检查 1: adjoint_mode=0 时背景场 Eb ======
fprintf('\n[BG] ====== 检查 1: adjoint_mode=0 时背景场 ======\n');

% 设置伴随源并设 adjoint_mode=0（但不求解）
phys = model.physics('emw');
inner = voxel.mask_interior;

% 写入 Ms 插值函数
ms_funcs = {'int_ms_x_re','int_ms_x_im','int_ms_y_re','int_ms_y_im','int_ms_z_re','int_ms_z_im'};
for d = 1:3
    for part = 1:2
        fn = ms_funcs{(d-1)*2+part};
        try model.component('comp1').func(fn);
        catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        if part == 1, vals = -real(Ms_full(:,d)); else, vals = imag(Ms_full(:,d)); end
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [source_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp);
        delete(tmp);
    end
end

% 写入 Js=0 的插值函数
sc_funcs = {'int_sc_x_re','int_sc_x_im','int_sc_y_re','int_sc_y_im','int_sc_z_re','int_sc_z_im'};
for d = 1:3
    for part = 1:2
        fn = sc_funcs{(d-1)*2+part};
        try model.component('comp1').func(fn);
        catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        vals = zeros(size(source_pos,1), 1);
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [source_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp);
        delete(tmp);
    end
end

% 创建/配置 SurfaceCurrent (Js=0)
try phys.feature().remove('sc_adj'); catch, end
phys.feature().create('sc_adj', 'SurfaceCurrent', 2);
omega_mu0 = pf.omega(1) * pf.mu0;
denom = sprintf('%.15e', omega_mu0);
Je_x = sprintf('(-int_sc_x_im(x,y,z) + i*int_sc_x_re(x,y,z)) / %s', denom);
Je_y = sprintf('(-int_sc_y_im(x,y,z) + i*int_sc_y_re(x,y,z)) / %s', denom);
Je_z = sprintf('(-int_sc_z_im(x,y,z) + i*int_sc_z_re(x,y,z)) / %s', denom);
phys.feature('sc_adj').set('Js0', {Je_x, Je_y, Je_z});
try phys.feature('sc_adj').selection().all(); catch, end

% 创建 SurfaceMagneticCurrent
try phys.feature().remove('ms_adj'); catch, end
phys.feature().create('ms_adj', 'SurfaceMagneticCurrentDensity', 2);
Mx = sprintf('(-int_ms_x_im(x,y,z) + i*int_ms_x_re(x,y,z))');
My = sprintf('(-int_ms_y_im(x,y,z) + i*int_ms_y_re(x,y,z))');
Mz = sprintf('(-int_ms_z_im(x,y,z) + i*int_ms_z_re(x,y,z))');
phys.feature('ms_adj').set('Jms0', {Mx, My, Mz});
try phys.feature('ms_adj').selection().all(); catch, end

% 归零 vec1
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end

% 设 adjoint_mode=0
model.param.set('adjoint_mode', '0');

% 检查背景场表达式
fprintf('[BG] 检查 BackgroundField 设置...\n');
try
    bf_solve_for = model.physics('emw').prop('BackgroundField').get('SolveFor');
    fprintf('  SolveFor = %s\n', bf_solve_for);
catch
    fprintf('  无法读取 SolveFor\n');
end

try
    % 读取背景场表达式
    Ebg = model.physics('emw').prop('BackgroundField').get('Ebg');
    fprintf('  Ebg = %s\n', strjoin(Ebg, ', '));
catch ME
    fprintf('  无法读取 Ebg: %s\n', ME.message);
end

% 检查 adjoint_mode 当前值
am = model.param.get('adjoint_mode');
fprintf('  adjoint_mode = %s\n', am);

fprintf('\n[BG] 正演求解（adjoint_mode=0, 含 Ms 伴随源）...\n');
model.sol('sol1').runAll();

% 检查 1a: 背景场 Eb 在体素点的值
fprintf('\n[BG] 提取背景场 Eb 在体素点...\n');
inner_pos = voxel.pos(inner, :);
try
    Eb_vals = mphinterp(model, {'emw.Ebx', 'emw.Eby', 'emw.Ebz'}, 'coord', inner_pos');
    Eb_max = max(vecnorm(Eb_vals, 2, 2));
    fprintf('  |Eb| max = %.6e\n', Eb_max);
    fprintf('  |Eb| mean = %.6e\n', mean(vecnorm(Eb_vals, 2, 2)));
    if Eb_max > 1e-10
        fprintf('  *** 背景场非零！残余 = %.6e ***\n', Eb_max);
    else
        fprintf('  背景场为零（正常）\n');
    end
catch ME
    fprintf('  无法提取 Eb: %s\n', ME.message);
    fprintf('  尝试其他变量名...\n');
    try
        Eb_vals = mphinterp(model, {'ewfd.Ebx', 'ewfd.Eby', 'ewfd.Ebz'}, 'coord', inner_pos');
        fprintf('  ewfd.Eb: |max|=%.6e\n', max(vecnorm(Eb_vals, 2, 2)));
    catch
        fprintf('  ewfd.Eb 也失败\n');
    end
end

% 检查 1b: 总场 E 和散射场 Es 在体素点
fprintf('\n[BG] 提取总场 E 和散射场 Es...\n');
try
    E_total_adj = mphinterp(model, {'emw.Ex', 'emw.Ey', 'emw.Ez'}, 'coord', inner_pos');
    fprintf('  |E_total| mean = %.6e (adjoint solve)\n', mean(vecnorm(E_total_adj, 2, 2)));
    fprintf('  |E_total| max = %.6e\n', max(vecnorm(E_total_adj, 2, 2)));
catch ME
    fprintf('  无法提取 E: %s\n', ME.message);
end

% 检查 2: lambda 场的空间分布
fprintf('\n[BG] ====== 检查 2: lambda 场空间分布 ======\n');

lambda_raw = E_total_adj;  % 伴随求解后的 E 就是 lambda_raw

% 按 eps_r 权重分类：体内 vs 边界
d_vox = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
body_mask = d_vox > 0.05;   % 远离空洞（体内）
boundary_mask = d_vox < 0.02 & d_vox > 0.005;  % 空洞边界附近

fprintf('  体内体素数: %d\n', sum(body_mask));
fprintf('  边界体素数: %d\n', sum(boundary_mask));

if sum(body_mask) > 0
    fprintf('  lambda 体内: |mean|=%.6e, |max|=%.6e\n', ...
        mean(vecnorm(lambda_raw(body_mask,:), 2, 2)), ...
        max(vecnorm(lambda_raw(body_mask,:), 2, 2)));
end
if sum(boundary_mask) > 0
    fprintf('  lambda 边界: |mean|=%.6e, |max|=%.6e\n', ...
        mean(vecnorm(lambda_raw(boundary_mask,:), 2, 2)), ...
        max(vecnorm(lambda_raw(boundary_mask,:), 2, 2)));
end

% 检查 lambda 的实部/虚部比例
fprintf('\n  lambda 实部 vs 虚部:\n');
fprintf('    |Re| mean = %.6e\n', mean(abs(real(lambda_raw(:)))));
fprintf('    |Im| mean = %.6e\n', mean(abs(imag(lambda_raw(:)))));
fprintf('    Re/Im ratio = %.4f\n', mean(abs(real(lambda_raw(:)))) / (mean(abs(imag(lambda_raw(:)))) + 1e-30));

% 检查 lambda 和 E_forward 的点积分布
fprintf('\n[BG] ====== 检查 3: lambda·E 点积分布 ======\n');
dot_vals = zeros(size(inner_pos, 1), 1);
for vi = 1:size(inner_pos, 1)
    dot_vals(vi) = conj(E_total(vi,:)) * lambda_raw(vi,:)';
end
fprintf('  Re(conj(E)*lambda) 统计:\n');
fprintf('    mean = %+.6e\n', mean(real(dot_vals)));
fprintf('    std = %.6e\n', std(real(dot_vals)));
fprintf('    min = %+.6e\n', min(real(dot_vals)));
fprintf('    max = %+.6e\n', max(real(dot_vals)));
fprintf('    min/max ratio = %.4f\n', min(real(dot_vals)) / (max(abs(real(dot_vals))) + 1e-30));

% 体内 vs 边界
fprintf('    体内 mean = %+.6e (N=%d)\n', mean(real(dot_vals(body_mask))), sum(body_mask));
fprintf('    边界 mean = %+.6e (N=%d)\n', mean(real(dot_vals(boundary_mask))), sum(boundary_mask));
body_ratio = mean(real(dot_vals(body_mask))) / (mean(real(dot_vals(boundary_mask))) + 1e-30);
fprintf('    体内/边界 ratio = %.4f\n', body_ratio);

% 检查 3b: dV 分布
fprintf('\n  dV 统计:\n');
dV_inner = voxel.dV(inner);
fprintf('    dV mean = %.6e\n', mean(dV_inner));
fprintf('    dV std/mean = %.4f\n', std(dV_inner)/mean(dV_inner));
fprintf('    dV range = [%.6e, %.6e]\n', min(dV_inner), max(dV_inner));

% 加权贡献: g_voxel = -k0^2 * dV * Re(conj(E)*lambda)
g_voxel_unscaled = dV_inner(:) .* real(dot_vals);
fprintf('\n  g_voxel (未缩放) 统计:\n');
fprintf('    sum(体内) = %+.6e\n', sum(g_voxel_unscaled(body_mask)));
fprintf('    sum(边界) = %+.6e\n', sum(g_voxel_unscaled(boundary_mask)));
fprintf('    体内/边界贡献比 = %.4f\n', ...
    abs(sum(g_voxel_unscaled(body_mask))) / (abs(sum(g_voxel_unscaled(boundary_mask))) + 1e-30));

%% 恢复
model.param.set('adjoint_mode', '1');
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end

fprintf('\n############################################################\n');
fprintf('#  诊断完成\n');
fprintf('############################################################\n');

end
