function diagnose_step3b_im_dot()
%DIAGNOSE_STEP3B 测试 -Im(lambda.*E) 是否匹配全部 12 个体素 FD
%
%   推导：lambda 含 -pi/2 全局相位 (来自 conj(coeff_base))
%   Re(lambda.*E) 实际是 Im(lambda_true.*E)
%   修正: Re(i*lambda.*E) = -Im(lambda.*E) 恢复正确分量

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  步骤3b: -Im(lambda.*E) 全局相位补偿验证\n');
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
fprintf('[S3b] 预计算 J_obs...\n');
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

%% 步骤2 体素 FD 值
g_FD_data = [
    1,   -3.7168e-12;
    161, -6.2773e-12;
    200, -5.0570e-12;
    279, -6.3642e-11;
    285, -3.9691e-11;
    326, -1.4808e-11;
    338, -1.8900e-11;
    415, -2.4140e-11;
    426, -1.5098e-11;
    502, -3.7414e-11;
    513, -7.8376e-12;
    673, +1.7544e-13;
];
N_sel = size(g_FD_data, 1);
sel_voxels = g_FD_data(:, 1);
g_FD_vals = g_FD_data(:, 2);

%% 正演 + 伴随
fprintf('\n[S3b] 正演 + 伴随...\n');
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

[lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
if ~ok, fprintf('[S3b] [FAIL]\n'); return; end

k0_sq = pf.k0^2; dV_vec = voxel.dV;
E_sel = E_total(sel_voxels, :);
lambda_sel = lambda(sel_voxels, :);
dV_sel = dV_vec(inner_idx(sel_voxels));

%% 6 种公式
% A: Re(bilinear) +
g_A = k0_sq .* dV_sel .* real(sum(lambda_sel .* E_sel, 2));
% B: Re(bilinear) -
g_B = -g_A;
% C: Re(Hermitian) +
g_C = k0_sq .* dV_sel .* real(sum(conj(E_sel) .* lambda_sel, 2));
% D: Re(Hermitian) -
g_D = -g_C;
% E: -Im(bilinear)  <-- 补偿 -pi/2 相位
g_E = -k0_sq .* dV_sel .* imag(sum(lambda_sel .* E_sel, 2));
% F: -Im(Hermitian)
g_F = -k0_sq .* dV_sel .* imag(sum(conj(E_sel) .* lambda_sel, 2));

signs_FD = sign(g_FD_vals);
modes = {'A:Re(bil)+', 'B:Re(bil)-', 'C:Re(her)+', 'D:Re(her)-', ...
         'E:-Im(bil)', 'F:-Im(her)'};
all_g = [g_A, g_B, g_C, g_D, g_E, g_F];

fprintf('\n############################################################\n');
fprintf('#  步骤3b 结果\n');
fprintf('############################################################\n');
fprintf('#  体素  g_FD          A:ReB+    B:ReB-    C:ReH+    D:ReH-    E:-ImB    F:-ImH\n');

for vi = 1:N_sel
    fprintf('#  %3d   %+.2e  ', sel_voxels(vi), g_FD_vals(vi));
    for mi = 1:6
        s = sign(all_g(vi, mi));
        match = 'Y';
        if s ~= signs_FD(vi), match = 'N'; end
        fprintf(' %+.1e(%s) ', all_g(vi, mi), match);
    end
    fprintf('\n');
end

fprintf('#\n#  sign 匹配数:\n');
for mi = 1:6
    n = sum(sign(all_g(:, mi)) == signs_FD);
    fprintf('#    %s: %d/%d\n', modes{mi}, n, N_sel);
end

best_n = 0; best_mode = '';
for mi = 1:6
    n = sum(sign(all_g(:, mi)) == signs_FD);
    if n > best_n, best_n = n; best_mode = modes{mi}; end
end
fprintf('#\n#  最佳: %s (%d/%d)\n', best_mode, best_n, N_sel);
if best_n == N_sel
    fprintf('#  *** 全部 12 个体素 sign 一致！全局相位补偿成功！***\n');
end
fprintf('############################################################\n');
end
