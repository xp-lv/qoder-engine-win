function diagnose_p0_fix()
%DIAGNOSE_P0_FIX P0 修正验证：统一 vec1 + bilinear dot + 去归一化
%
%   三个修正同时应用：
%   1. 统一为 vec1（ExternalCurrentDensity），不用 SurfaceCurrent/MagneticCurrent
%   2. 梯度公式用 bilinear dot: Re(lambda .* E)（无共轭）
%   3. 目标函数去归一化: F = mean(|dJ|^2) / 6（不除 |J_obs|^2）
%
%   预期：CV 应从 0.82（原始）大幅降低

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  P0 修正验证：vec1 + bilinear + 去归一化\n');
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
fprintf('[P0] 预计算 J_obs...\n');
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

%% FD 地面真值（非归一化目标函数）
fprintf('\n[P0] 计算单参数 FD (非归一化)...\n');
params_0 = [eps_r_test; hole_pos_test];
fd_steps = [0.001, 0.0001, 0.0001, 0.0001];
g_FD = zeros(4, 1);
for pi_idx = 1:4
    delta = fd_steps(pi_idx);
    pp = params_0; pp(pi_idx) = pp(pi_idx) + delta;
    F_plus = compute_F_noNorm(model, voxel, grid, p, pf0, pp, inner_pos, inner_mask, delta_sdf, J_obs);
    pm = params_0; pm(pi_idx) = pm(pi_idx) - delta;
    F_minus = compute_F_noNorm(model, voxel, grid, p, pf0, pm, inner_pos, inner_mask, delta_sdf, J_obs);
    g_FD(pi_idx) = (F_plus - F_minus) / (2 * delta);
end
fprintf('[P0] g_FD(noNorm) = [%.6e, %.6e, %.6e, %.6e]\n', g_FD);

%% 正演 + 伴随
fprintf('\n[P0] 正演 + 伴随...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

% 伴随源（去归一化：Delta_J_perp = Delta_J，不除 J_obs_safe）
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;  % 去归一化

[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj = Js + Ms;  % 合并为单一源
fprintf('[P0] |f_adj| mean=%.4e\n', mean(vecnorm(f_adj, 2, 2)));

% 用 vec1 路径注入（统一为 ExternalCurrentDensity）
[lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
if ~ok, fprintf('[P0] [FAIL]\n'); return; end
fprintf('[P0] lambda: |mean|=%.4e\n', mean(vecnorm(lambda, 2, 2)));

%% 链式法则 + bilinear dot
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

% bilinear dot: g = k0^2 * dV * Re(sum_d lambda_d * E_d)
g_voxel = zeros(N_inner, 1);
gauss_w = voxel.gauss_w;
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && size(E_gauss,1)==size(voxel.gauss_pos,1) ...
    && size(lambda_gauss,1)==size(voxel.gauss_pos,1);

if use_gauss
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        v_idx = inner_idx(vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gauss_w(gpi) * real(sum(lambda_gauss(gp(gpi),:) .* E_gauss(gp(gpi),:)));
        end
        g_voxel(vi) = k0_sq * dV_vec(v_idx) * gs;
    end
else
    for vi = 1:N_inner
        v_idx = inner_idx(vi);
        g_voxel(vi) = k0_sq * dV_vec(v_idx) * real(sum(lambda(vi,:) .* E_total(vi,:)));
    end
end

g_adj = zeros(4, 1);
g_adj(1) = sum(g_voxel .* dE_deps);
for j = 1:3
    g_adj(1+j) = sum(g_voxel .* dE_dhole(:,j));
end

%% 对比
ratio = g_adj ./ g_FD;
rv = ratio(isfinite(ratio) & abs(g_FD) > 1e-20);
cv = std(rv) / abs(mean(rv));

fprintf('\n############################################################\n');
fprintf('#  P0 修正结果\n');
fprintf('############################################################\n');
fprintf('#  参数        g_FD           g_adjoint      ratio    sign\n');
names = {'eps_r', 'hole_x', 'hole_y', 'hole_z'};
for i = 1:4
    fprintf('#  %-9s  %+.6e  %+.6e  %+.4f  %+d\n', ...
        names{i}, g_FD(i), g_adj(i), ratio(i), sign(g_FD(i)*g_adj(i)));
end
fprintf('#\n');
fprintf('#  CV = %.4f\n', cv);
fprintf('#  ratio mean = %.6f\n', mean(rv));
fprintf('#\n');
fprintf('#  历史 CV 对比:\n');
fprintf('#    原始 (Hermitian + 归一化): CV = 0.82\n');
fprintf('#    +bilinear:                CV = 0.66\n');
fprintf('#    +去归一化:                CV = 0.27\n');
fprintf('#    P0 (vec1+bilinear+去归一): CV = %.4f\n', cv);
if cv < 0.1
    fprintf('#  *** CV < 0.1！P0 修正成功！ratio 一致！***\n');
elseif cv < 0.2
    fprintf('#  CV < 0.2，接近精确，残余可能来自 3D 投影一致性\n');
else
    fprintf('#  CV >= 0.2，仍有残余问题\n');
end
fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir,'dir'), mkdir(results_dir); end
save(fullfile(results_dir,'p0_fix_result.mat'), 'g_FD', 'g_adj', 'ratio', 'cv');
end

function F = compute_F_noNorm(model, voxel, grid, p, pf0, params, inner_pos, inner_mask, delta_sdf, J_obs)
    eps_r = params(1); hp = params(2:4);
    d_v = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = eps_r + (1.0-eps_r)*0.5*(1-tanh(d_v/delta_sdf));
    update_epsilon(model, voxel, p);
    pf = pf0; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/p.c; pf.lambda=p.c/pf.freq;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    F = mean(sum(abs(dJ).^2, 2)) / 6;  % 非归一化
end
