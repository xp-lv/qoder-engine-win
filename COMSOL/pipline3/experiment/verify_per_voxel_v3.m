function verify_per_voxel_v3(N_sample)
%VERIFY_PER_VOXEL_V3 管线3 逐体素 FD 验证（mphmatrix + MATLAB backslash 伴随求解）
%
%   对比管线2的 verify_per_voxel.m：
%     管线2: solve_adjoint → COMSOL runAll → read_field
%     管线3: solve_adjoint_matlab → mphmatrix + MATLAB backslash → mphinterp
%
%   目标：验证管线3的伴随梯度方向与 FD 一致性
%
%   用法：
%     >> verify_per_voxel_v3(30)

if nargin < 1, N_sample = 30; end

%% 0. 路径初始化（同时加载管线3和管线2的模块）
this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
pipline2_dir = fullfile(fileparts(pipline3_dir), 'pipline_adjoint');

cd(pipline3_dir);
addpath('config', 'core_adjoint', 'experiment');
% 复用管线2的物理模块
addpath(fullfile(pipline2_dir, 'config'));
addpath(fullfile(pipline2_dir, 'utils'));
addpath(fullfile(pipline2_dir, 'core_forward'));
addpath(fullfile(pipline2_dir, 'core_jhyp'));
addpath(fullfile(pipeline2_dir, 'core_jobs'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

% 使用管线3的 config
p = config();

fprintf('\n############################################################\n');
fprintf('#  管线3 逐体素 FD 验证（mphmatrix + MATLAB backslash）\n');
fprintf('#  模型: %s\n', p.comsol_model_path);
fprintf('############################################################\n\n');

%% 1. COMSOL 初始化
fprintf('[V3] 连接 COMSOL Server (port %d)...\n', p.comsol_port);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        try mphstop(p.comsol_port); pause(2); mphstart(p.comsol_port); catch, end
    end
end
try; tags = ModelUtil.tags(); for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

fprintf('[V3] 加载模型: %s\n', p.comsol_model_path);
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end

phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0', '0', '0'});
    try phys.feature('vec1').selection().all(); catch; end
end
try model.param.set('adjoint_mode', '1'); catch; end

%% 2. 提取网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('[V3] N_inner = %d 体素\n', N_inner);

grid = build_measurement_grid(p);

%% 3. 预计算 J_obs（真值 eps_r = 20-5j）
fprintf('[V3] 预计算 J_obs (eps_r = 20-5j)...\n');
eps_true_re = p.eps_r_true_re;
eps_true_im = p.eps_r_true_im;
voxel.epsilon_r(~inner) = 1.0;
voxel.epsilon_r(inner) = eps_true_re + 1j * eps_true_im;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs_norm = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs_norm < p.F_obs_min, F_obs_norm = 1.0; end
fprintf('[V3] F_obs_norm = %.6e\n', F_obs_norm);

%% 4. 在初值点设置正演
eps_re_test = p.eps_r_init_re;  % 12.0
eps_im_test = p.eps_r_init_im;  % -3.0
fprintf('[V3] 在初值点 eps_r = %.4f %+.4fj 设置正演...\n', eps_re_test, eps_im_test);
voxel.epsilon_r(inner) = eps_re_test + 1j * eps_im_test;
update_epsilon(model, voxel, p);

% 正演（COMSOL runAll，触发 LU 分解）
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs_norm;
fprintf('[V3] F_data = %.6e, sqrt(F) = %.6e\n', F_data, sqrt(F_data));

%% 5. 构建伴随源（复用管线2的 build_adjoint_source_fullmaxwell）
fprintf('\n[V3] ===== 构建伴随源 =====\n');
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);

%% 6. ★ 管线3核心：MATLAB backslash 伴随求解 ★
fprintf('\n[V3] ===== 管线3 MATLAB backslash 伴随求解 =====\n');
K_cache = [];  % 首次创建 LU 缓存
[lambda, ok_adj, lambda_gauss, K_cache] = solve_adjoint_matlab(model, voxel, p, Js, source_pos, Ms, K_cache);

if ~ok_adj
    fprintf('[V3] [FAIL] MATLAB backslash 伴随求解失败\n');
    return;
end

%% 7. 计算逐体素复数伴随梯度
k0_sq = p.k0^2;
dV_vec = voxel.dV;
g_complex_all = zeros(N_inner, 1);
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && size(E_gauss, 1) == size(voxel.gauss_pos, 1);

if use_gauss
    gw = voxel.gauss_w;
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gw(gpi) * sum(E_gauss(gp(gpi), :) .* lambda_gauss(gp(gpi), :));
        end
        g_complex_all(vi) = -k0_sq * dV_vec(inner_idx(vi)) * gs;
    end
    fprintf('[V3] 复数梯度: 4-pt Gauss 积分 (%d 体素)\n', N_inner);
else
    for vi = 1:N_inner
        g_complex_all(vi) = -k0_sq * dV_vec(inner_idx(vi)) ...
            * sum(E_total(vi, :) .* lambda(vi, :));
    end
    fprintf('[V3] 复数梯度: 质心近似 (%d 体素)\n', N_inner);
end
g_complex_all = g_complex_all / F_obs_norm;

g_total = sum(g_complex_all);
fprintf('\n[V3] 总伴随梯度 g_total = %+.6e %+.6ej\n', real(g_total), imag(g_total));
fprintf('[V3]   dF/deps_re (2*Re):   %+.6e\n', 2*real(g_total));
fprintf('[V3]   dF/deps_im (-2*Im):  %+.6e\n', -2*imag(g_total));

%% 8. 均匀扰动 FD 基准
fprintf('\n[V3] ===== 均匀扰动 FD 基准 =====\n');
fd_delta_uniform = 0.1;

% 确保 solve_quiet 恢复正演模式
voxel.epsilon_r(inner) = (eps_re_test + fd_delta_uniform) + 1j * eps_im_test;
update_epsilon(model, voxel, p);
solve_quiet_v3(model, p);
sf_p = extract_scattered(model, grid); lc_p = lightcone_project(grid, sf_p, p);
Fp_re = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

voxel.epsilon_r(inner) = (eps_re_test - fd_delta_uniform) + 1j * eps_im_test;
update_epsilon(model, voxel, p);
solve_quiet_v3(model, p);
sf_m = extract_scattered(model, grid); lc_m = lightcone_project(grid, sf_m, p);
Fm_re = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;
g_FD_re_uni = (Fp_re - Fm_re) / (2 * fd_delta_uniform);

voxel.epsilon_r(inner) = eps_re_test + 1j * (eps_im_test + fd_delta_uniform);
update_epsilon(model, voxel, p);
solve_quiet_v3(model, p);
sf_p = extract_scattered(model, grid); lc_p = lightcone_project(grid, sf_p, p);
Fp_im = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

voxel.epsilon_r(inner) = eps_re_test + 1j * (eps_im_test - fd_delta_uniform);
update_epsilon(model, voxel, p);
solve_quiet_v3(model, p);
sf_m = extract_scattered(model, grid); lc_m = lightcone_project(grid, sf_m, p);
Fm_im = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;
g_FD_im_uni = (Fp_im - Fm_im) / (2 * fd_delta_uniform);

% 恢复
voxel.epsilon_r(inner) = eps_re_test + 1j * eps_im_test;
update_epsilon(model, voxel, p);

fprintf('[V3] 均匀 FD dF/deps_re = %+.6e (adj 2*Re = %+.6e, sign=%s)\n', ...
    g_FD_re_uni, 2*real(g_total), ternary_s(g_FD_re_uni * 2*real(g_total) > 0, 'OK', 'XX'));
fprintf('[V3] 均匀 FD dF/deps_im = %+.6e (adj -2*Im = %+.6e, sign=%s)\n', ...
    g_FD_im_uni, -2*imag(g_total), ternary_s(g_FD_im_uni * (-2*imag(g_total)) > 0, 'OK', 'XX'));

%% 9. 逐体素 FD 验证
fprintf('\n[V3] ===== 逐体素 FD 验证 (N_sample = %d) =====\n', N_sample);

r_inner = vecnorm(voxel.pos(inner_idx, :), 2, 2);
[~, sort_order] = sort(r_inner);
step = floor(N_inner / N_sample);
sample_idx = sort_order(1:step:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fd_delta = 0.001;
g_FD_sample = zeros(N_s, 1);
g_adj_sample = zeros(N_s, 1);

fprintf('\n  IDx   r      | FD           Adj           ratio     sign\n');
fprintf('  -----+--------+--------------+--------------+----------+----\n');

for si = 1:N_s
    vi = sample_idx(si);
    v_global = inner_idx(vi);
    eps_orig = voxel.epsilon_r(v_global);

    % FD 扰动（实部，因为管线2主管线验证用的是实部）
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_v3(model, p);
    sf_p = extract_scattered(model, grid); lc_p = lightcone_project(grid, sf_p, p);
    F_plus = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_v3(model, p);
    sf_m = extract_scattered(model, grid); lc_m = lightcone_project(grid, sf_m, p);
    F_minus = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;

    voxel.epsilon_r(v_global) = eps_orig;
    update_epsilon(model, voxel, p);

    g_FD = (F_plus - F_minus) / (2 * fd_delta);
    g_FD_sample(si) = g_FD;
    g_adj_sample(si) = real(g_complex_all(vi));  % 复数梯度的实部

    if mod(si, 5) == 0 || si == 1 || si == N_s
        ratio = g_adj_sample(si) / g_FD_sample(si);
        fprintf('  %3d  %.3f  | %+10.3e  %+10.3e  %8.4f  %s\n', ...
            si, r_inner(vi), g_FD, g_adj_sample(si), ratio, ...
            ternary_s(g_FD * g_adj_sample(si) > 0, 'OK', 'XX'));
    end
end

%% 10. 统计
sign_match = sign(g_FD_sample .* g_adj_sample) > 0;
sign_rate = sum(sign_match) / N_s;
ratios = g_adj_sample ./ g_FD_sample;
valid = abs(g_FD_sample) > 1e-30;
ratios_v = ratios(valid);
cos_theta = dot(g_FD_sample, g_adj_sample) / (norm(g_FD_sample) * norm(g_adj_sample));

fprintf('\n############################################################\n');
fprintf('#  管线3 逐体素验证结果（mphmatrix + MATLAB backslash）\n');
fprintf('############################################################\n');
fprintf('#  sign 一致率: %d/%d = %.1f%%\n', sum(sign_match), N_s, 100*sign_rate);
if ~isempty(ratios_v)
    fprintf('#  ratio mean=%.6f CV=%.6f\n', mean(ratios_v), std(ratios_v)/abs(mean(ratios_v)));
end
fprintf('#  cos θ = %.6f\n', cos_theta);
if sign_rate > 0.9 && cos_theta > 0.8
    fprintf('#  ★★★ PASS ★★★\n');
else
    fprintf('#  ⚠ FAIL\n');
end
fprintf('############################################################\n');

% 保存结果
result = struct();
result.pipeline = 'pipline3';
result.N_sample = N_s;
result.g_FD = g_FD_sample;
result.g_adj = g_adj_sample;
result.sign_rate = sign_rate;
result.cos_theta = cos_theta;
result.g_FD_re_uniform = g_FD_re_uni;
result.g_FD_im_uniform = g_FD_im_uni;
result.g_adj_re_total = 2*real(g_total);
result.g_adj_im_total = -2*imag(g_total);

save(fullfile(p.dir_result, 'verify_v3_result.mat'), 'result');
fprintf('\n[V3] 结果已保存: %s\n', fullfile(p.dir_result, 'verify_v3_result.mat'));

end

%% ====== 辅助函数 ======
function solve_quiet_v3(model, p)
    % ★ 管线3 的 solve_quiet：包含防御性状态恢复（修复 verify_complex_per_voxel 的缺陷）
    try model.param.set('freq', num2str(p.freq));
        try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
    catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    % ★ 防御性恢复（与管线2 main_per_voxel.m 一致）
    try model.physics('emw').prop('BackgroundField').set('Eb', [0 0 1]); catch; end
    try model.param.set('adjoint_mode', '1'); catch; end
    try model.physics('emw').feature('vec1').set('Je', {'0', '0', '0'}); catch; end
    % 求解器配置
    try
        s1 = model.sol('sol1').feature('s1');
        try s1.feature('dDirect'); catch
            s1.create('dDirect', 'Direct');
            s1.feature('dDirect').set('linsolver', 'pardiso');
        end
        try s1.feature('fc1').set('linsolver', 'dDirect'); catch; end
    catch; end
    model.sol('sol1').runAll();
end

function s = ternary_s(cond, a, b)
    if cond, s = a; else, s = b; end
end
