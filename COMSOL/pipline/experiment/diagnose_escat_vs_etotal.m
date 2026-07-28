function diagnose_escat_vs_etotal()
%DIAGNOSE_ESCAT_VS_ETOTAL 对照：梯度用 E_scat vs E_total
%
%   核心假设：当前管线梯度用 E_total，但伴随源从 E_scat 构建
%   修正：梯度应该用 E_scat（散射场）
%
%   本脚本对同一次伴随求解，分别用 E_total 和 E_scat 计算梯度，
%   对比两者的 ratio 一致性（CV）

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  E_scat vs E_total 梯度对照\n');
fprintf('#  验证：梯度用散射场是否解决 ratio 不一致\n');
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
fprintf('[ES] 预计算 J_obs...\n');
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

%% FD 地面真值
fprintf('\n[ES] 计算单参数 FD...\n');
params_0 = [eps_r_test; hole_pos_test];
fd_steps = [0.001, 0.0001, 0.0001, 0.0001];
g_FD = zeros(4, 1);
for pi_idx = 1:4
    delta = fd_steps(pi_idx);
    pp = params_0; pp(pi_idx) = pp(pi_idx) + delta;
    F_plus = compute_F(model, voxel, grid, p, pf0, pp, inner_pos, inner_mask, delta_sdf, J_obs);
    pm = params_0; pm(pi_idx) = pm(pi_idx) - delta;
    F_minus = compute_F(model, voxel, grid, p, pf0, pm, inner_pos, inner_mask, delta_sdf, J_obs);
    g_FD(pi_idx) = (F_plus - F_minus) / (2 * delta);
end
fprintf('[ES] g_FD = [%.6e, %.6e, %.6e, %.6e]\n', g_FD);

%% 正演 + 伴随
fprintf('\n[ES] 正演 + 伴随求解...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;

% 正演（solve_forward 返回 E_total via read_field emw.Ex）
[E_total, ~, E_gauss_total] = solve_forward(model, voxel, pf);

% ★ 关键：额外提取散射场 E_scat 和 E_scat_gauss ★
fprintf('[ES] 提取散射场 E_scat...\n');
inner = voxel.mask_interior;
pos_inner = voxel.pos(inner, :);

% 体素中心散射场
rEx = mphinterp(model, 'emw.relEx', 'coord', pos_inner');
rEy = mphinterp(model, 'emw.relEy', 'coord', pos_inner');
rEz = mphinterp(model, 'emw.relEz', 'coord', pos_inner');
E_scat = [rEx(:), rEy(:), rEz(:)];

% Gauss 点散射场
if ~isempty(voxel.gauss_pos)
    rExg = mphinterp(model, 'emw.relEx', 'coord', voxel.gauss_pos');
    rEyg = mphinterp(model, 'emw.relEy', 'coord', voxel.gauss_pos');
    rEzg = mphinterp(model, 'emw.relEz', 'coord', voxel.gauss_pos');
    E_gauss_scat = [rExg(:), rEyg(:), rEzg(:)];
else
    E_gauss_scat = [];
end

fprintf('[ES] |E_total| mean = %.6e\n', mean(vecnorm(E_total, 2, 2)));
fprintf('[ES] |E_scat|  mean = %.6e\n', mean(vecnorm(E_scat, 2, 2)));
fprintf('[ES] |E_bg|    mean = %.6e\n', mean(vecnorm(E_total - E_scat, 2, 2)));

% 伴随求解
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
J_obs_safe = max(sum(abs(J_obs).^2, 2), 1e-12);
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J ./ J_obs_safe;
[Js, Ms, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, pf);

% 用 vec1 路径（旧路径），合并 Js+Ms
f_adj = Js + Ms;
[lambda, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
if ~adj_ok, fprintf('[ES] [FAIL]\n'); return; end

% lambda_raw（旧路径不取共轭）
fprintf('[ES] lambda: |mean|=%.4e (conj=0, 旧路径)\n', mean(vecnorm(lambda, 2, 2)));

%% 链式法则权重
N_inner = sum(inner);
inner_idx = find(inner);
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

%% ====== 模式 A: 梯度用 E_total（当前方式）======
fprintf('\n[ES] ====== 模式 A: g = -k0^2 * dV * Re(conj(lam) * E_total) ======\n');
gauss_w = voxel.gauss_w;
use_gauss = ~isempty(E_gauss_total) && ~isempty(lambda_gauss) ...
    && size(E_gauss_total,1)==size(voxel.gauss_pos,1) ...
    && size(lambda_gauss,1)==size(voxel.gauss_pos,1);

g_voxel_A = zeros(N_inner, 1);
if use_gauss
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gauss_w(gpi) * dot(E_gauss_total(gp(gpi),:), lambda_gauss(gp(gpi),:));
        end
        g_voxel_A(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(gs);
    end
else
    for vi = 1:N_inner
        g_voxel_A(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(dot(E_total(vi,:), lambda(vi,:)));
    end
end
g_adj_A = zeros(4,1);
g_adj_A(1) = sum(g_voxel_A .* dE_deps);
for j = 1:3, g_adj_A(1+j) = sum(g_voxel_A .* dE_dhole(:,j)); end
ratio_A = g_adj_A ./ g_FD;
cv_A = std(ratio_A(isfinite(ratio_A)))/abs(mean(ratio_A(isfinite(ratio_A))));
fprintf('[ES] A ratio: [%.4f, %.4f, %.4f, %.4f], CV=%.4f\n', ratio_A, cv_A);

%% ====== 模式 B: 梯度用 E_scat（修正后方式）======
fprintf('\n[ES] ====== 模式 B: g = -k0^2 * dV * Re(conj(lam) * E_scat) ======\n');
use_gauss_B = ~isempty(E_gauss_scat) && ~isempty(lambda_gauss) ...
    && size(E_gauss_scat,1)==size(voxel.gauss_pos,1) ...
    && size(lambda_gauss,1)==size(voxel.gauss_pos,1);

g_voxel_B = zeros(N_inner, 1);
if use_gauss_B
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gauss_w(gpi) * dot(E_gauss_scat(gp(gpi),:), lambda_gauss(gp(gpi),:));
        end
        g_voxel_B(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(gs);
    end
else
    for vi = 1:N_inner
        g_voxel_B(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(dot(E_scat(vi,:), lambda(vi,:)));
    end
end
g_adj_B = zeros(4,1);
g_adj_B(1) = sum(g_voxel_B .* dE_deps);
for j = 1:3, g_adj_B(1+j) = sum(g_voxel_B .* dE_dhole(:,j)); end
ratio_B = g_adj_B ./ g_FD;
cv_B = std(ratio_B(isfinite(ratio_B)))/abs(mean(ratio_B(isfinite(ratio_B))));
fprintf('[ES] B ratio: [%.4f, %.4f, %.4f, %.4f], CV=%.4f\n', ratio_B, cv_B);

%% ====== 模式 C: 梯度用 E_bg（背景场，诊断用）======
fprintf('\n[ES] ====== 模式 C: g = -k0^2 * dV * Re(conj(lam) * E_bg) [诊断] ======\n');
E_bg = E_total - E_scat;
E_bg_gauss = E_gauss_total - E_gauss_scat;

use_gauss_C = use_gauss_B;
g_voxel_C = zeros(N_inner, 1);
if use_gauss_C
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gauss_w(gpi) * dot(E_bg_gauss(gp(gpi),:), lambda_gauss(gp(gpi),:));
        end
        g_voxel_C(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(gs);
    end
else
    for vi = 1:N_inner
        g_voxel_C(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(dot(E_bg(vi,:), lambda(vi,:)));
    end
end
g_adj_C = zeros(4,1);
g_adj_C(1) = sum(g_voxel_C .* dE_deps);
for j = 1:3, g_adj_C(1+j) = sum(g_voxel_C .* dE_dhole(:,j)); end
ratio_C = g_adj_C ./ g_FD;
cv_C = std(ratio_C(isfinite(ratio_C)))/abs(mean(ratio_C(isfinite(ratio_C))));
fprintf('[ES] C ratio: [%.4f, %.4f, %.4f, %.4f], CV=%.4f\n', ratio_C, cv_C);

%% 汇总
fprintf('\n\n############################################################\n');
fprintf('#  E_scat vs E_total 对照结果\n');
fprintf('############################################################\n');
fprintf('#  %-20s  %8s  %8s  %8s  %8s  %8s\n', 'Mode', 'eps_r', 'hole_x', 'hole_y', 'hole_z', 'CV');
fprintf('#  %-20s  %8s  %8s  %8s  %8s  %8s\n', '----', '------', '------', '------', '------', '------');
mnames = {'A: E_total (current)', 'B: E_scat (fixed)', 'C: E_bg (diagnostic)'};
all_r = [ratio_A; ratio_B; ratio_C];
all_cv = [cv_A, cv_B, cv_C];
for mi = 1:3
    fprintf('#  %-20s  %8.4f  %8.4f  %8.4f  %8.4f  %8.4f\n', ...
        mnames{mi}, all_r(mi,1), all_r(mi,2), all_r(mi,3), all_r(mi,4), all_cv(mi));
end
fprintf('#\n#  CV < 0.1 = ratio 一致 = 精确伴随\n');
fprintf('#  预期：模式 B (E_scat) 的 CV 应远低于模式 A (E_total)\n');
if cv_B < 0.1
    fprintf('#  *** 模式 B CV < 0.1！E_scat 修正成功！***\n');
elseif cv_B < cv_A
    fprintf('#  模式 B CV < 模式 A CV，E_scat 修正有改善但未完全解决\n');
else
    fprintf('#  模式 B CV >= 模式 A CV，E_scat 修正无效\n');
end
fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir,'dir'), mkdir(results_dir); end
save(fullfile(results_dir,'escat_vs_etotal_result.mat'), 'all_r', 'all_cv', 'mnames', 'g_FD');
end

function F = compute_F(model, voxel, grid, p, pf0, params, inner_pos, inner_mask, delta_sdf, J_obs)
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
    F = mean(sum(abs(dJ).^2,2) ./ Jo / 6);
end
