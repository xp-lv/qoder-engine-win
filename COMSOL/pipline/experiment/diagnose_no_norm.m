function diagnose_no_norm()
%DIAGNOSE_NO_NORM 去归一化对照：验证归一化因子是否是 CV=0.66 的根因
%
%   数学推导：
%     F = sum_k |dJ(k)|^2 / (6 * |J_obs(k)|^2)
%     分母 |J_obs(k)|^2 依赖参数 -> 非线性 -> 梯度含额外项
%     当前代码只用了线性近似（忽略分母变分）
%
%   验证：去掉分母归一化，F_simple = sum_k |dJ(k)|^2 / 6
%   如果 CV < 0.1，确认归一化是根因

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  去归一化对照：归一化因子变分是 ratio 不一致的根因吗？\n');
fprintf('############################################################\n\n');

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

%% 预计算 J_obs
fprintf('[NN] 预计算 J_obs...\n');
voxel_truth = voxel;
d_true = sqrt(sum((inner_pos - [0.03;0.02;0.01]').^2, 2));
voxel_truth.epsilon_r(inner_mask) = 5.0 + (1.0-5.0)*0.5*(1-tanh(d_true/delta_sdf));
update_epsilon(model, voxel_truth, p);
pf0 = p; pf0.freq=1e9; pf0.omega=2*pi*pf0.freq; pf0.k0=pf0.omega/p.c; pf0.lambda=p.c/pf0.freq;
model.param.set('freq', num2str(pf0.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', pf0.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
sf = extract_scattered(model, grid);
J_obs = lightcone_project(grid, sf, pf0).J_obs_perp;

%% FD 地面真值 - 两种目标函数
fprintf('\n[NN] 计算单参数 FD (归一化 + 非归一化)...\n');
params_0 = [eps_r_test; hole_pos_test];
fd_steps = [0.001, 0.0001, 0.0001, 0.0001];
g_FD_norm = zeros(4, 1);     % 归一化目标函数的 FD
g_FD_noNorm = zeros(4, 1);   % 非归一化目标函数的 FD

for pi_idx = 1:4
    delta = fd_steps(pi_idx);
    pp = params_0; pp(pi_idx) = pp(pi_idx) + delta;
    [F_plus_norm, F_plus_noNorm] = compute_F_both(model, voxel, grid, p, pf0, ...
        pp, inner_pos, inner_mask, delta_sdf, J_obs);
    pm = params_0; pm(pi_idx) = pm(pi_idx) - delta;
    [F_minus_norm, F_minus_noNorm] = compute_F_both(model, voxel, grid, p, pf0, ...
        pm, inner_pos, inner_mask, delta_sdf, J_obs);
    g_FD_norm(pi_idx) = (F_plus_norm - F_minus_norm) / (2 * delta);
    g_FD_noNorm(pi_idx) = (F_plus_noNorm - F_minus_noNorm) / (2 * delta);
end
fprintf('[NN] g_FD_norm   = [%.6e, %.6e, %.6e, %.6e]\n', g_FD_norm);
fprintf('[NN] g_FD_noNorm = [%.6e, %.6e, %.6e, %.6e]\n', g_FD_noNorm);

%% 正演 + 伴随
fprintf('\n[NN] 正演 + 伴随...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

% 伴随源 - 两种方式
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
J_hyp = lc.J_obs_perp;
Delta_J = J_obs - J_hyp;
J_obs_sq = sum(abs(J_obs).^2, 2);
J_obs_safe = max(J_obs_sq, 1e-12);

% 方式 A: 归一化（当前）- Delta_J_perp = Delta_J / J_obs_safe
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J ./ J_obs_safe;
[Js_A, Ms_A, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj_A = Js_A + Ms_A;

% 方式 B: 非归一化 - Delta_J_perp = Delta_J (不除 J_obs_safe)
lc.Delta_J_perp = Delta_J;  % 无归一化
[Js_B, Ms_B, ~, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj_B = Js_B + Ms_B;

fprintf('[NN] |f_adj_A| mean=%.4e (normalized)\n', mean(vecnorm(f_adj_A, 2, 2)));
fprintf('[NN] |f_adj_B| mean=%.4e (no normalization)\n', mean(vecnorm(f_adj_B, 2, 2)));

% 伴随求解
[lambda_A, ok_A, lambda_A_gauss] = solve_adjoint(model, voxel, pf, f_adj_A, source_pos, []);
[lambda_B, ok_B, lambda_B_gauss] = solve_adjoint(model, voxel, pf, f_adj_B, source_pos, []);

%% 链式法则
N_inner = sum(inner_mask);
inner_idx = find(inner_mask);
k0_sq = pf.k0^2; dV_vec = voxel.dV;
dE_deps = 0.5*(1+tanh(d_test/delta_sdf));
diff_v = inner_pos - hole_pos_test';
d_v = sqrt(sum(diff_v.^2, 2));
sech2 = 1./cosh(d_v/delta_sdf).^2;
deps_dd = -(1-eps_r_test)*0.5*sech2/delta_sdf;
dE_dhole = zeros(N_inner, 3);
for j = 1:3
    dE_dhole(:, j) = deps_dd .* (-diff_v(:,j)./(d_v+1e-30));
end

gauss_w = voxel.gauss_w;
lambdas = {lambda_A, lambda_B};
lambda_gausses = {lambda_A_gauss, lambda_B_gauss};
g_FDs = {g_FD_norm, g_FD_noNorm};
labels = {'A: normalized (current)', 'B: no normalization'};

for mi = 1:2
    lam = lambdas{mi};
    lam_g = lambda_gausses{mi};
    gFD = g_FDs{mi};

    use_gauss = ~isempty(E_gauss) && ~isempty(lam_g) ...
        && size(E_gauss,1)==size(voxel.gauss_pos,1) ...
        && size(lam_g,1)==size(voxel.gauss_pos,1);

    g_voxel = zeros(N_inner, 1);
    if use_gauss
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            v_idx = inner_idx(vi);
            gs = 0;
            for gpi = 1:4
                % bilinear dot: Re(lambda .* E) (数学推导的正确公式)
                gs = gs + gauss_w(gpi) * real(sum(lam_g(gp(gpi),:) .* E_gauss(gp(gpi),:)));
            end
            g_voxel(vi) = k0_sq * dV_vec(v_idx) * gs;
        end
    else
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            g_voxel(vi) = k0_sq * dV_vec(v_idx) * real(sum(lam(vi,:) .* E_total(vi,:)));
        end
    end

    g_param = zeros(4, 1);
    g_param(1) = sum(g_voxel .* dE_deps);
    for j = 1:3
        g_param(1+j) = sum(g_voxel .* dE_dhole(:,j));
    end

    ratio = g_param ./ gFD;
    rv = ratio(isfinite(ratio) & abs(gFD) > 1e-20);
    cv = std(rv) / abs(mean(rv));
    fprintf('\n[NN] %s:\n', labels{mi});
    fprintf('  ratio = [%.4f, %.4f, %.4f, %.4f], CV=%.4f\n', ratio, cv);
end

%% 汇总
fprintf('\n############################################################\n');
fprintf('#  去归一化对照结果\n');
fprintf('############################################################\n');
fprintf('#  如果方式 B (no norm) 的 CV << 方式 A (normalized) 的 CV，\n');
fprintf('#  则确认归一化因子变分是 ratio 不一致的根因\n');
fprintf('############################################################\n');
end

function [F_norm, F_noNorm] = compute_F_both(model, voxel, grid, p, pf0, params, inner_pos, inner_mask, delta_sdf, J_obs)
    eps_r = params(1); hp = params(2:4);
    d_v = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = eps_r + (1.0-eps_r)*0.5*(1-tanh(d_v/delta_sdf));
    update_epsilon(model, voxel, p);
    pf = pf0; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/p.c; pf.lambda=p.c/pf.freq;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    Jo = max(sum(abs(J_obs).^2,2), 1e-12);
    % 归一化目标函数
    F_norm = mean(sum(abs(dJ).^2,2) ./ Jo / 6);
    % 非归一化目标函数
    F_noNorm = mean(sum(abs(dJ).^2,2)) / 6;
end
