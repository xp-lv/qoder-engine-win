function verify_pipline_adjoint()
%VERIFY_PIPLINE_ADJOINT 在 pipline_adjoint 管线上验证修正后的伴随法
%
%   验证内容：
%   1. 体素级 FD vs 伴随梯度（12 个体素，逐体素 sign 对比）
%   2. 参数级 g·dp 方向验证
%
%   预期：修正后的 -Re(conj(λ)*E) 应达到 12/12 sign 一致

this_dir = fileparts(mfilename('fullpath'));
cd(this_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  pipline_adjoint 修正验证\n');
fprintf('#  solve_adjoint: 直接 f_adj/(i*omega*mu0)（无 conj）\n');
fprintf('#  compute_gradient: -Re(conj(λ)*E) Hermitian 负号\n');
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
inner_idx = find(inner_mask);

%% 预计算 J_obs
fprintf('[VA] 预计算 J_obs...\n');
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

%% 步骤2 体素 FD 值（已验证数据）
g_FD_data = [
    1,   -3.7168e-12;  161, -6.2773e-12;
    200, -5.0570e-12;  279, -6.3642e-11;
    285, -3.9691e-11;  326, -1.4808e-11;
    338, -1.8900e-11;  415, -2.4140e-11;
    426, -1.5098e-11;  502, -3.7414e-11;
    513, -7.8376e-12;  673, +1.7544e-13;
];
N_sel = size(g_FD_data, 1);
sel_voxels = g_FD_data(:, 1);
g_FD_vals = g_FD_data(:, 2);

%% 正演 + 伴随（用 pipline_adjoint 的修正代码）
fprintf('\n[VA] 正演...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj = Js + Ms;

% 用修正后的 solve_adjoint（旧路径 vec1，直接 f_adj/(i*omega*mu0)）
fprintf('\n[VA] 伴随求解（修正后 solve_adjoint）...\n');
[lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
if ~ok, fprintf('[VA] [FAIL]\n'); return; end
fprintf('[VA] lambda: |mean|=%.4e\n', mean(vecnorm(lambda, 2, 2)));

%% 逐体素梯度对比
k0_sq = pf.k0^2; dV_vec = voxel.dV;
E_sel = E_total(sel_voxels, :);
lambda_sel = lambda(sel_voxels, :);
dV_sel = dV_vec(inner_idx(sel_voxels));

% 正确公式：g = -k0^2*dV*Re(conj(lambda)*E)
g_adj = -k0_sq .* dV_sel .* real(sum(conj(lambda_sel) .* E_sel, 2));

% 对比
signs_FD = sign(g_FD_vals);
signs_adj = sign(g_adj);
n_match = sum(signs_adj == signs_FD);

fprintf('\n############################################################\n');
fprintf('#  pipline_adjoint 修正结果\n');
fprintf('############################################################\n');
fprintf('#  体素  g_FD          g_adj          ratio    FD  adj  match\n');
for vi = 1:N_sel
    r = g_adj(vi) / g_FD_vals(vi);
    m = 'Y'; if signs_adj(vi) ~= signs_FD(vi), m = 'N'; end
    fprintf('#  %3d   %+.4e   %+.4e   %+.4f   %+d  %+d  %s\n', ...
        sel_voxels(vi), g_FD_vals(vi), g_adj(vi), r, signs_FD(vi), signs_adj(vi), m);
end
fprintf('#\n#  sign 匹配: %d/%d\n', n_match, N_sel);

% ratio CV
ratios = g_adj ./ g_FD_vals;
cv = std(ratios) / abs(mean(ratios));
fprintf('#  ratio mean=%.6f, CV=%.4f\n', mean(ratios), cv);

if n_match == N_sel
    fprintf('#  *** 全部 12 个体素 sign 一致！pipline_adjoint 修正成功！***\n');
else
    fprintf('#  部分不一致（%d/%d）\n', n_match, N_sel);
end

% g·dp 方向验证
p_init = [3.0; 0; 0; 0];
p_true = [5.0; 0.03; 0.02; 0.01];
dp = p_true - p_init;

% 参数级梯度（链式法则）
N_inner = sum(inner_mask);
g_voxel_all = zeros(N_inner, 1);
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
            gs = gs + gauss_w(gpi) * real(conj(lambda_gauss(gp(gpi),:)) * E_gauss(gp(gpi),:)');
        end
        g_voxel_all(vi) = -k0_sq * dV_vec(v_idx) * gs;
    end
else
    for vi = 1:N_inner
        v_idx = inner_idx(vi);
        g_voxel_all(vi) = -k0_sq * dV_vec(v_idx) * real(conj(lambda(vi,:)) * E_total(vi,:)');
    end
end

dE_deps = 0.5*(1+tanh(d_test/delta_sdf));
diff_v = inner_pos - hole_pos_test';
d_v = sqrt(sum(diff_v.^2, 2));
sech2 = 1./cosh(d_v/delta_sdf).^2;
deps_dd = -(1-eps_r_test)*0.5*sech2/delta_sdf;
dE_dhole = zeros(N_inner, 3);
for j = 1:3
    dE_dhole(:, j) = deps_dd .* (-diff_v(:,j)./(d_v+1e-30));
end

g_param = zeros(4, 1);
g_param(1) = sum(g_voxel_all .* dE_deps);
for j = 1:3
    g_param(1+j) = sum(g_voxel_all .* dE_dhole(:,j));
end

gdp = dot(g_param, dp);
fprintf('#\n#  g_adj·dp = %+.6e\n', gdp);
if gdp < 0
    fprintf('#  g·dp < 0 -> 梯度下降方向朝真值（正确）\n');
else
    fprintf('#  g·dp > 0 -> 梯度下降方向背离真值（错误）\n');
end
fprintf('############################################################\n');
end
