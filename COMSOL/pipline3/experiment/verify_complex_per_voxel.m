function verify_complex_per_voxel(eps_re_test, eps_im_test, N_sample)
%VERIFY_COMPLEX_PER_VOXEL 复数逐体素 FD vs 伴随梯度方向验证
%
%   对每个采样体素，独立扰动该体素的 ε_re 和 ε_im（其余体素保持不变），
%   计算 central FD 梯度，与伴随法逐体素梯度对比方向一致性。
%
%   关键诊断目标：
%     1. dF/dε_re: 验证 2*Re(g) 方向是否与 FD 一致
%     2. dF/dε_im: 验证 ±2*Im(g) 两种符号约定哪个与 FD 一致
%        （当前代码用 -2*Im(g)，数学推导给出 +2*Im(g)）
%
%   用法：
%     >> verify_complex_per_voxel(17.14, -4.08, 30)   % 在 H039 终点验证
%     >> verify_complex_per_voxel(12.0, -3.0, 30)     % 在初始点验证
%     >> verify_complex_per_voxel()                    % 默认在真值附近验证

if nargin < 1 || isempty(eps_re_test), eps_re_test = 12.0; end
if nargin < 2 || isempty(eps_im_test), eps_im_test = -3.0; end
if nargin < 3 || isempty(N_sample), N_sample = 30; end

%% 0. 路径初始化
this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', ...
    'core_adjoint', 'experiment');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  复数逐体素 FD vs 伴随梯度方向验证\n');
fprintf('#  测试点: eps_r = %.4f %+.4fj\n', eps_re_test, eps_im_test);
fprintf('#  真值:   eps_r = 20.0 -5.0j\n');
fprintf('############################################################\n\n');

%% 1. COMSOL 初始化
fprintf('[VCPV] 连接 COMSOL Server (port 2036)...\n');
try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        try mphstop(2036); pause(2); mphstart(2036); catch, end
    end
end
try; tags = ModelUtil.tags(); for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

p = config();
fprintf('[VCPV] 加载模型: %s\n', p.comsol_model_path);
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
fprintf('[VCPV] N_inner = %d 体素\n', N_inner);

grid = build_measurement_grid(p);

%% 3. 预计算 J_obs（真值 eps_r = 20-5j）
fprintf('[VCPV] 预计算 J_obs (eps_r = 20-5j)...\n');
eps_true_re = p.eps_r_true_re;  % 20.0
eps_true_im = p.eps_r_true_im;  % -5.0
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
fprintf('[VCPV] F_obs_norm = %.6e\n', F_obs_norm);

%% 4. 在测试点设置正演 + 伴随
fprintf('[VCPV] 在测试点 eps_r = %.4f %+.4fj 设置正演...\n', eps_re_test, eps_im_test);
voxel.epsilon_r(inner) = eps_re_test + 1j * eps_im_test;
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs_norm;
fprintf('[VCPV] F_data = %.6e, sqrt(F) = %.6e\n', F_data, sqrt(F_data));

% 伴随源
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
if ~ok_adj
    fprintf('[VCPV] [FAIL] 伴随求解失败\n');
    return;
end

%% 5. 计算逐体素复数伴随梯度（保留完整复数信息）
k0_sq = p.k0^2;
dV_vec = voxel.dV;
g_complex_all = zeros(N_inner, 1);  % 复数逐体素梯度
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
    fprintf('[VCPV] 复数梯度: 4-pt Gauss 积分 (%d 体素)\n', N_inner);
else
    for vi = 1:N_inner
        g_complex_all(vi) = -k0_sq * dV_vec(inner_idx(vi)) ...
            * sum(E_total(vi, :) .* lambda(vi, :));
    end
    fprintf('[VCPV] 复数梯度: 质心近似 (%d 体素)\n', N_inner);
end
g_complex_all = g_complex_all / F_obs_norm;

% Wirtinger 分离（两种符号约定都计算）
g_adj_re_all = 2 * real(g_complex_all);       % dF/dε_re = 2*Re(g)
g_adj_im_pos = 2 * imag(g_complex_all);        % dF/dε_im 候选 A: +2*Im(g)
g_adj_im_neg = -2 * imag(g_complex_all);       % dF/dε_im 候选 B: -2*Im(g)（代码当前）

% 总梯度
g_total = sum(g_complex_all);
fprintf('\n[VCPV] 总伴随梯度 g_total = %+.6e %+.6ej\n', real(g_total), imag(g_total));
fprintf('[VCPV]   dF/deps_re (2*Re):   %+.6e\n', 2*real(g_total));
fprintf('[VCPV]   dF/deps_im (+2*Im):  %+.6e  ← 数学推导\n', 2*imag(g_total));
fprintf('[VCPV]   dF/deps_im (-2*Im):  %+.6e  ← 代码当前\n', -2*imag(g_total));

%% 6. 均匀扰动 FD 基准（所有体素同时扰动）
fprintf('\n[VCPV] ===== 均匀扰动 FD 基准 =====\n');
fd_delta_uniform = 0.1;

% FD for eps_re (uniform)
voxel.epsilon_r(inner) = (eps_re_test + fd_delta_uniform) + 1j * eps_im_test;
update_epsilon(model, voxel, p);
solve_quiet_c(model, p);
sf_p = extract_scattered(model, grid); lc_p = lightcone_project(grid, sf_p, p);
Fp_re_uni = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

voxel.epsilon_r(inner) = (eps_re_test - fd_delta_uniform) + 1j * eps_im_test;
update_epsilon(model, voxel, p);
solve_quiet_c(model, p);
sf_m = extract_scattered(model, grid); lc_m = lightcone_project(grid, sf_m, p);
Fm_re_uni = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;
g_FD_re_uni = (Fp_re_uni - Fm_re_uni) / (2 * fd_delta_uniform);

% FD for eps_im (uniform)
voxel.epsilon_r(inner) = eps_re_test + 1j * (eps_im_test + fd_delta_uniform);
update_epsilon(model, voxel, p);
solve_quiet_c(model, p);
sf_p = extract_scattered(model, grid); lc_p = lightcone_project(grid, sf_p, p);
Fp_im_uni = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

voxel.epsilon_r(inner) = eps_re_test + 1j * (eps_im_test - fd_delta_uniform);
update_epsilon(model, voxel, p);
solve_quiet_c(model, p);
sf_m = extract_scattered(model, grid); lc_m = lightcone_project(grid, sf_m, p);
Fm_im_uni = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;
g_FD_im_uni = (Fp_im_uni - Fm_im_uni) / (2 * fd_delta_uniform);

% 恢复测试点
voxel.epsilon_r(inner) = eps_re_test + 1j * eps_im_test;
update_epsilon(model, voxel, p);

fprintf('[VCPV] 均匀 FD dF/deps_re = %+.6e (adj 2*Re = %+.6e, sign=%s)\n', ...
    g_FD_re_uni, 2*real(g_total), ternary_s(g_FD_re_uni * 2*real(g_total) > 0, 'OK', 'XX'));
fprintf('[VCPV] 均匀 FD dF/deps_im = %+.6e\n', g_FD_im_uni);
fprintf('[VCPV]   vs +2*Im(g) = %+.6e, sign=%s  ← 数学推导\n', ...
    2*imag(g_total), ternary_s(g_FD_im_uni * 2*imag(g_total) > 0, 'OK', 'XX'));
fprintf('[VCPV]   vs -2*Im(g) = %+.6e, sign=%s  ← 代码当前\n', ...
    -2*imag(g_total), ternary_s(g_FD_im_uni * (-2*imag(g_total)) > 0, 'OK', 'XX'));

%% 7. 逐体素 FD 验证（采样体素）
fprintf('\n[VCPV] ===== 逐体素 FD 验证 (N_sample = %d) =====\n', N_sample);

% 按径向距离采样（覆盖从中心到边缘）
r_inner = vecnorm(voxel.pos(inner_idx, :), 2, 2);
[~, sort_order] = sort(r_inner);
step = floor(N_inner / N_sample);
sample_idx = sort_order(1:step:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fd_delta = 0.01;  % 单体素扰动步长

g_FD_re_sample = zeros(N_s, 1);
g_FD_im_sample = zeros(N_s, 1);
g_adj_re_sample = zeros(N_s, 1);
g_adj_im_pos_sample = zeros(N_s, 1);  % +2*Im
g_adj_im_neg_sample = zeros(N_s, 1);  % -2*Im
r_sample = zeros(N_s, 1);

fprintf('\n  IDx   r      | FD_re        Adj_re        sign | FD_im        +2Im(g)       -2Im(g)       +sign -sign\n');
fprintf('  -----+--------+--------------+--------------+------+--------------+--------------+--------------+-----+-----\n');

for si = 1:N_s
    vi = sample_idx(si);
    v_global = inner_idx(vi);
    eps_orig = voxel.epsilon_r(v_global);  % 当前体素的复数 ε_r
    r_sample(si) = r_inner(vi);

    % --- FD for eps_re (per-voxel) ---
    voxel.epsilon_r(v_global) = (eps_re_test + fd_delta) + 1j * eps_im_test;
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_p = extract_scattered(model, grid); lc_p = lightcone_project(grid, sf_p, p);
    Fp_re = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

    voxel.epsilon_r(v_global) = (eps_re_test - fd_delta) + 1j * eps_im_test;
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_m = extract_scattered(model, grid); lc_m = lightcone_project(grid, sf_m, p);
    Fm_re = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;
    g_FD_re_sample(si) = (Fp_re - Fm_re) / (2 * fd_delta);

    % --- FD for eps_im (per-voxel) ---
    voxel.epsilon_r(v_global) = eps_re_test + 1j * (eps_im_test + fd_delta);
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_p = extract_scattered(model, grid); lc_p = lightcone_project(grid, sf_p, p);
    Fp_im = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

    voxel.epsilon_r(v_global) = eps_re_test + 1j * (eps_im_test - fd_delta);
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_m = extract_scattered(model, grid); lc_m = lightcone_project(grid, sf_m, p);
    Fm_im = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;
    g_FD_im_sample(si) = (Fp_im - Fm_im) / (2 * fd_delta);

    % 恢复
    voxel.epsilon_r(v_global) = eps_orig;
    update_epsilon(model, voxel, p);

    % 对应的伴随梯度
    g_adj_re_sample(si) = g_adj_re_all(vi);
    g_adj_im_pos_sample(si) = g_adj_im_pos(vi);
    g_adj_im_neg_sample(si) = g_adj_im_neg(vi);

    % 方向检查
    sign_re = ternary_s(g_FD_re_sample(si) * g_adj_re_sample(si) > 0, 'OK', 'XX');
    sign_im_pos = ternary_s(g_FD_im_sample(si) * g_adj_im_pos_sample(si) > 0, 'OK', 'XX');
    sign_im_neg = ternary_s(g_FD_im_sample(si) * g_adj_im_neg_sample(si) > 0, 'OK', 'XX');

    if mod(si, 3) == 0 || si == 1 || si == N_s
        fprintf('  %3d  %.3f  | %+10.3e  %+10.3e   %s  | %+10.3e  %+10.3e  %+10.3e   %s   %s\n', ...
            si, r_sample(si), ...
            g_FD_re_sample(si), g_adj_re_sample(si), sign_re, ...
            g_FD_im_sample(si), g_adj_im_pos_sample(si), g_adj_im_neg_sample(si), ...
            sign_im_pos, sign_im_neg);
    end
end

%% 8. 统计汇总
fprintf('\n############################################################\n');
fprintf('#  逐体素验证结果汇总\n');
fprintf('#  测试点: eps_r = %.4f %+.4fj, N_sample = %d\n', eps_re_test, eps_im_test, N_s);
fprintf('############################################################\n\n');

% ε_re 通道
sign_match_re = sign(g_FD_re_sample .* g_adj_re_sample) > 0;
sign_rate_re = sum(sign_match_re) / N_s;
ratios_re = g_adj_re_sample ./ g_FD_re_sample;
valid_re = abs(g_FD_re_sample) > 1e-30;
ratios_re_v = ratios_re(valid_re);
cos_theta_re = dot(g_FD_re_sample, g_adj_re_sample) / (norm(g_FD_re_sample) * norm(g_adj_re_sample));

fprintf('  [ε_re 通道] dF/dε_re = 2*Re(g)\n');
fprintf('    sign 一致率: %d/%d = %.1f%%\n', sum(sign_match_re), N_s, 100*sign_rate_re);
if ~isempty(ratios_re_v)
    fprintf('    ratio mean=%.6f CV=%.6f\n', mean(ratios_re_v), std(ratios_re_v)/abs(mean(ratios_re_v)));
end
fprintf('    cos θ = %.6f\n', cos_theta_re);
fprintf('    判定: %s\n\n', ternary_s(sign_rate_re > 0.8 && cos_theta_re > 0.8, '★★★ PASS', '⚠ FAIL'));

% ε_im 通道 (+2*Im)
sign_match_im_pos = sign(g_FD_im_sample .* g_adj_im_pos_sample) > 0;
sign_rate_im_pos = sum(sign_match_im_pos) / N_s;
ratios_im_pos = g_adj_im_pos_sample ./ g_FD_im_sample;
valid_im = abs(g_FD_im_sample) > 1e-30;
ratios_im_pos_v = ratios_im_pos(valid_im);
cos_theta_im_pos = dot(g_FD_im_sample, g_adj_im_pos_sample) / (norm(g_FD_im_sample) * norm(g_adj_im_pos_sample));

fprintf('  [ε_im 通道] dF/dε_im = +2*Im(g)  ← 数学推导\n');
fprintf('    sign 一致率: %d/%d = %.1f%%\n', sum(sign_match_im_pos), N_s, 100*sign_rate_im_pos);
if ~isempty(ratios_im_pos_v)
    fprintf('    ratio mean=%.6f CV=%.6f\n', mean(ratios_im_pos_v), std(ratios_im_pos_v)/abs(mean(ratios_im_pos_v)));
end
fprintf('    cos θ = %.6f\n', cos_theta_im_pos);
fprintf('    判定: %s\n\n', ternary_s(sign_rate_im_pos > 0.8 && cos_theta_im_pos > 0.8, '★★★ PASS', '⚠ FAIL'));

% ε_im 通道 (-2*Im)
sign_match_im_neg = sign(g_FD_im_sample .* g_adj_im_neg_sample) > 0;
sign_rate_im_neg = sum(sign_match_im_neg) / N_s;
ratios_im_neg = g_adj_im_neg_sample ./ g_FD_im_sample;
ratios_im_neg_v = ratios_im_neg(valid_im);
cos_theta_im_neg = dot(g_FD_im_sample, g_adj_im_neg_sample) / (norm(g_FD_im_sample) * norm(g_adj_im_neg_sample));

fprintf('  [ε_im 通道] dF/dε_im = -2*Im(g)  ← 代码当前\n');
fprintf('    sign 一致率: %d/%d = %.1f%%\n', sum(sign_match_im_neg), N_s, 100*sign_rate_im_neg);
if ~isempty(ratios_im_neg_v)
    fprintf('    ratio mean=%.6f CV=%.6f\n', mean(ratios_im_neg_v), std(ratios_im_neg_v)/abs(mean(ratios_im_neg_v)));
end
fprintf('    cos θ = %.6f\n', cos_theta_im_neg);
fprintf('    判定: %s\n\n', ternary_s(sign_rate_im_neg > 0.8 && cos_theta_im_neg > 0.8, '★★★ PASS', '⚠ FAIL'));

% 最终裁决
fprintf('############################################################\n');
fprintf('#  裁决: 哪个 Wirtinger 虚部符号约定与 FD 一致？\n');
if sign_rate_im_pos > sign_rate_im_neg
    fprintf('#  ★★★ +2*Im(g) 更一致 (%.1f%% vs %.1f%%) → 代码 -2*Im(g) 符号错误！\n', ...
        100*sign_rate_im_pos, 100*sign_rate_im_neg);
    fprintf('#  修复: g_data_im 应改为 +2*imag(g_total)\n');
elseif sign_rate_im_neg > sign_rate_im_pos
    fprintf('#  ★★★ -2*Im(g) 更一致 (%.1f%% vs %.1f%%) → 代码当前符号正确\n', ...
        100*sign_rate_im_neg, 100*sign_rate_im_pos);
else
    fprintf('#  两者一致率相同 (%.1f%%)，无法判定\n', 100*sign_rate_im_pos);
end
fprintf('############################################################\n');

% 保存结果
result = struct();
result.eps_re_test = eps_re_test;
result.eps_im_test = eps_im_test;
result.N_sample = N_s;
result.g_FD_re = g_FD_re_sample;
result.g_FD_im = g_FD_im_sample;
result.g_adj_re = g_adj_re_sample;
result.g_adj_im_pos = g_adj_im_pos_sample;
result.g_adj_im_neg = g_adj_im_neg_sample;
result.r_sample = r_sample;
result.sign_rate_re = sign_rate_re;
result.sign_rate_im_pos = sign_rate_im_pos;
result.sign_rate_im_neg = sign_rate_im_neg;
result.cos_theta_re = cos_theta_re;
result.cos_theta_im_pos = cos_theta_im_pos;
result.cos_theta_im_neg = cos_theta_im_neg;
result.g_FD_re_uniform = g_FD_re_uni;
result.g_FD_im_uniform = g_FD_im_uni;

save(fullfile(p.dir_result, 'verify_per_voxel_result.mat'), 'result');
fprintf('\n[VCPV] 结果已保存: data/results/verify_per_voxel_result.mat\n');

end

%% ====== 辅助函数 ======
function solve_quiet_c(model, p)
    try
        model.param.set('freq', num2str(p.freq));
        try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
    catch
    end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    try
        s1 = model.sol('sol1').feature('s1');
        try s1.feature('dDirect'); catch
            s1.create('dDirect', 'Direct');
            s1.feature('dDirect').set('linsolver', 'pardiso');
        end
        try s1.feature('fc1').set('linsolver', 'dDirect'); catch; end
    catch
    end
    model.sol('sol1').runAll();
end

function s = ternary_s(cond, a, b)
    if cond, s = a; else, s = b; end
end
