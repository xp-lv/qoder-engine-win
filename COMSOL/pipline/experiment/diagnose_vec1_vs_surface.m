function diagnose_vec1_vs_surface()
%DIAGNOSE_VEC1_VS_SURFACE 对照实验：vec1 体积源 vs SurfaceCurrent 表面源
%
%   用同一个伴随源 Js_exact，分别通过两种方式注入：
%     方式 A: SurfaceCurrent（弱贡献，iωμ₀·Js0·test(E)）
%     方式 B: ExternalCurrentDensity（vec1，体积源，在球面附近薄壳注入）
%
%   对比两者的 lambda 场和 FD ratio 一致性

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  对照实验：vec1 vs SurfaceCurrent\n');
fprintf('#  同一伴随源，两种注入方式\n');
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
fprintf('[VS] 预计算 J_obs...\n');
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

%% FD 地面真值（单参数）
fprintf('\n[VS] 计算单参数 FD...\n');
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
fprintf('[VS] g_FD = [%.6e, %.6e, %.6e, %.6e]\n', g_FD);

%% 正演 + 伴随源构建
fprintf('\n[VS] 正演...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
J_obs_safe = max(sum(abs(J_obs).^2, 2), 1e-12);
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J ./ J_obs_safe;
[Js, Ms, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, pf);

fprintf('[VS] |Js| mean=%.4e, |Ms| mean=%.4e\n', mean(vecnorm(Js,2,2)), mean(vecnorm(Ms,2,2)));

%% 链式法则权重
N_inner = sum(inner_mask);
inner_idx = find(inner_mask);
dE_deps = 0.5*(1+tanh(d_test/delta_sdf));
diff_v = inner_pos - hole_pos_test';
d_v = sqrt(sum(diff_v.^2, 2));
sech2 = 1./cosh(d_v/delta_sdf).^2;
deps_dd = -(1-eps_r_test)*0.5*sech2/delta_sdf;
dE_dhole = zeros(N_inner, 3);
for j = 1:3
    dE_dhole(:, j) = deps_dd .* (-diff_v(:,j)./(d_v+1e-30));
end

%% ====== 方式 A: SurfaceCurrent（当前方式，cos=0.983）======
fprintf('\n[VS] ====== 方式 A: SurfaceCurrent ======\n');
% solve_adjoint 的 SurfaceCurrent 路径
% 把 Js+Ms 合并，用 SurfaceCurrent 注入
% 注意：当前 build_adjoint 输出的 Js 已含 n_hat x 修正
% 这里用 solve_adjoint 直接调用
try
    % solve_adjoint 内部做了 n_hat x 修正
    [lambda_A, ok_A, lambda_A_gauss] = solve_adjoint(model, voxel, pf, Js, source_pos, Ms);
catch ME
    fprintf('[VS] 方式 A 失败: %s\n', ME.message);
    ok_A = false;
end

if ok_A
    % Gauss 梯度
    k0_sq = pf.k0^2; dV_vec = voxel.dV;
    g_voxel_A = zeros(N_inner, 1);
    if size(lambda_A_gauss,1) == size(E_gauss,1)
        gw = voxel.gauss_w;
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gw(gpi) * dot(E_gauss(gp(gpi),:), lambda_A_gauss(gp(gpi),:));
            end
            g_voxel_A(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(gs);
        end
    else
        for vi = 1:N_inner
            g_voxel_A(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(dot(E_total(vi,:), lambda_A(vi,:)));
        end
    end
    g_adj_A = zeros(4,1);
    g_adj_A(1) = sum(g_voxel_A .* dE_deps);
    for j = 1:3, g_adj_A(1+j) = sum(g_voxel_A .* dE_dhole(:,j)); end

    ratio_A = g_adj_A ./ g_FD;
    cv_A = std(ratio_A(isfinite(ratio_A))) / abs(mean(ratio_A(isfinite(ratio_A))));
    fprintf('[VS] 方式 A ratio: [%.4f, %.4f, %.4f, %.4f], CV=%.4f\n', ratio_A, cv_A);
end

%% ====== 方式 B: vec1（ExternalCurrentDensity，用 Js+Ms 合并为体积源）======
fprintf('\n[VS] ====== 方式 B: vec1 ExternalCurrentDensity ======\n');
% 把 Js 和 Ms 合并为单个体积源，注入到测量球面上的网格节点
% vec1 是体积源 Je（A/m^2），而 Js/Ms 是表面源（A/m 或 V/m）
% vec1 的弱形式：-i*omega*mu0*Je*test(E) （与 SurfaceCurrent 相同！）
% 所以 Je = Js/surface_thickness 或直接用 Js 当体积值

% 合并源：Js（电流）+ Ms 转化的等效电流
% 从弱形式：SurfaceCurrent 贡献 = iωμ₀*(-Js0)*test(E)
%           vec1 贡献 = -iωμ₀*Je*test(E)
% 所以 Je = Js0（Js0 是 SurfaceCurrent 的值）
% 但 Js0 = -i*conj(Js)/(omega*mu0)（代码约定）
% 而 vec1 的 Je = -i*conj(f_adj)/(omega*mu0)（同样的约定）
% 所以直接把 Js 的值作为 f_adj 传给旧路径即可

% 合并 Js 和 Ms 为单个表面源
f_adj_merged = Js + Ms;  % 简单合并（因为两者弱形式相同）

% 用旧路径（vec1）注入
try
    [lambda_B, ok_B, lambda_B_gauss] = solve_adjoint(model, voxel, pf, f_adj_merged, source_pos, []);
catch ME
    fprintf('[VS] 方式 B 失败: %s\n', ME.message);
    ok_B = false;
end

if ok_B
    g_voxel_B = zeros(N_inner, 1);
    if size(lambda_B_gauss,1) == size(E_gauss,1)
        gw = voxel.gauss_w;
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gw(gpi) * dot(E_gauss(gp(gpi),:), lambda_B_gauss(gp(gpi),:));
            end
            g_voxel_B(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(gs);
        end
    else
        for vi = 1:N_inner
            g_voxel_B(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(dot(E_total(vi,:), lambda_B(vi,:)));
        end
    end
    g_adj_B = zeros(4,1);
    g_adj_B(1) = sum(g_voxel_B .* dE_deps);
    for j = 1:3, g_adj_B(1+j) = sum(g_voxel_B .* dE_dhole(:,j)); end

    ratio_B = g_adj_B ./ g_FD;
    cv_B = std(ratio_B(isfinite(ratio_B))) / abs(mean(ratio_B(isfinite(ratio_B))));
    fprintf('[VS] 方式 B ratio: [%.4f, %.4f, %.4f, %.4f], CV=%.4f\n', ratio_B, cv_B);
end

%% ====== 方式 C: vec1，只注入 Js（无 Ms，无 n_hat x 修正）======
fprintf('\n[VS] ====== 方式 C: vec1 Js-only (no n_hat x) ======\n');
% 重建无 n_hat x 修正的 Js
% build_adjoint 输出的 Js 已含 coeff_base 和 w(s)
% 直接用它（不走 solve_adjoint 的双源路径）
% solve_adjoint 旧路径：Je = -i*conj(f_adj)/(omega*mu0)
% 所以 f_adj 应该直接是伴随源值

% 但 build_adjoint 的 coeff_base = +0.5i*omega*eps0
% solve_adjoint 旧路径的 Je 表达式 = (-int_adj_im + i*int_adj_re)/(omega*mu0)
% = -i*conj(f_adj)/(omega*mu0)

% 让我直接用原始的 Js_raw（含 coeff_base 和 w(s)，但不含 n_hat x）
% build_adjoint 已经返回 Js = coeff_base * ws .* Js_raw
% 而且当前 build_adjoint 已包含 n_hat x（在 solve_adjoint 中）
% 我需要绕过 solve_adjoint 的 n_hat x 修正

% 直接用原始 Js（build_adjoint 输出）
try
    [lambda_C, ok_C, lambda_C_gauss] = solve_adjoint(model, voxel, pf, Js, source_pos, []);
catch ME
    fprintf('[VS] 方式 C 失败: %s\n', ME.message);
    ok_C = false;
end

if ok_C
    g_voxel_C = zeros(N_inner, 1);
    if size(lambda_C_gauss,1) == size(E_gauss,1)
        gw = voxel.gauss_w;
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gw(gpi) * dot(E_gauss(gp(gpi),:), lambda_C_gauss(gp(gpi),:));
            end
            g_voxel_C(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(gs);
        end
    else
        for vi = 1:N_inner
            g_voxel_C(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(dot(E_total(vi,:), lambda_C(vi,:)));
        end
    end
    g_adj_C = zeros(4,1);
    g_adj_C(1) = sum(g_voxel_C .* dE_deps);
    for j = 1:3, g_adj_C(1+j) = sum(g_voxel_C .* dE_dhole(:,j)); end

    ratio_C = g_adj_C ./ g_FD;
    cv_C = std(ratio_C(isfinite(ratio_C))) / abs(mean(ratio_C(isfinite(ratio_C))));
    fprintf('[VS] 方式 C ratio: [%.4f, %.4f, %.4f, %.4f], CV=%.4f\n', ratio_C, cv_C);
end

%% ====== 方式 D: vec1，只注入 Ms（用 vec1 而非 SurfaceMagneticCurrent）======
fprintf('\n[VS] ====== 方式 D: vec1 Ms-only (改用体积源) ======\n');
try
    [lambda_D, ok_D, lambda_D_gauss] = solve_adjoint(model, voxel, pf, Ms, source_pos, []);
catch ME
    fprintf('[VS] 方式 D 失败: %s\n', ME.message);
    ok_D = false;
end

if ok_D
    g_voxel_D = zeros(N_inner, 1);
    if size(lambda_D_gauss,1) == size(E_gauss,1)
        gw = voxel.gauss_w;
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gw(gpi) * dot(E_gauss(gp(gpi),:), lambda_D_gauss(gp(gpi),:));
            end
            g_voxel_D(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(gs);
        end
    else
        for vi = 1:N_inner
            g_voxel_D(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(dot(E_total(vi,:), lambda_D(vi,:)));
        end
    end
    g_adj_D = zeros(4,1);
    g_adj_D(1) = sum(g_voxel_D .* dE_deps);
    for j = 1:3, g_adj_D(1+j) = sum(g_voxel_D .* dE_dhole(:,j)); end

    ratio_D = g_adj_D ./ g_FD;
    cv_D = std(ratio_D(isfinite(ratio_D))) / abs(mean(ratio_D(isfinite(ratio_D))));
    fprintf('[VS] 方式 D ratio: [%.4f, %.4f, %.4f, %.4f], CV=%.4f\n', ratio_D, cv_D);
end

%% 汇总
fprintf('\n\n############################################################\n');
fprintf('#  对照汇总\n');
fprintf('############################################################\n');
fprintf('#  方式                              eps_r   hole_x   hole_y   hole_z    CV\n');
fprintf('#  ----                             ------   ------   ------   ------   ----\n');
modes = {'A: SurfaceCurrent(sc+ms)', 'B: vec1 (Js+Ms merged)', 'C: vec1 Js-only', 'D: vec1 Ms-only'};
cvs = [cv_A, cv_B, cv_C, cv_D];
all_ratios = [ratio_A; ratio_B; ratio_C; ratio_D];
for mi = 1:4
    fprintf('#  %-32s  %7.4f  %7.4f  %7.4f  %7.4f  %.4f\n', ...
        modes{mi}, all_ratios(mi,1), all_ratios(mi,2), all_ratios(mi,3), all_ratios(mi,4), cvs(mi));
end
fprintf('#\n#  CV < 0.1 表示 ratio 一致（精确伴随的必要条件）\n');
fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir,'dir'), mkdir(results_dir); end
save(fullfile(results_dir,'vec1_vs_surface_result.mat'), 'all_ratios', 'cvs', 'modes', 'g_FD');
end

%% ====== 辅助函数 ======
function F = compute_F(model, voxel, grid, p, pf0, params, inner_pos, inner_mask, delta_sdf, J_obs)
    eps_r = params(1); hp = params(2:4);
    d_v = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = eps_r + (1.0-eps_r)*0.5*(1-tanh(d_v/delta_sdf));
    update_epsilon(model, voxel, p);
    pf = pf0; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    Jo = max(sum(abs(J_obs).^2,2), 1e-12);
    F = mean(sum(abs(dJ).^2,2) ./ Jo / 6);
end
