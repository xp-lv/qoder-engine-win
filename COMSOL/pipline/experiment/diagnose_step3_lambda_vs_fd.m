function diagnose_step3_lambda_vs_fd()
%DIAGNOSE_STEP3 步骤3：lambda 场与体素 FD 逐体素对比
%
%   用步骤2的体素级 FD（已验证：12/12 符号一致且收敛）
%   对比伴随法的 k0^2*dV*Re(lambda.*E) 的逐体素 sign
%
%   测试 4 种梯度公式（同一次 lambda 求解）：
%     A: k0^2*dV*Re(lambda.*E)        (bilinear, +)
%     B: -k0^2*dV*Re(lambda.*E)       (bilinear, -)
%     C: k0^2*dV*Re(conj(E)*lambda)   (Hermitian, +)
%     D: -k0^2*dV*Re(conj(E)*lambda)  (Hermitian, -)

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  步骤3: lambda 场 vs 体素 FD 逐体素对比\n');
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
N_inner = sum(inner_mask);

%% 预计算 J_obs
fprintf('[S3] 预计算 J_obs...\n');
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

%% 步骤2 的体素 FD 值（硬编码，已验证 12/12 通过）
% 这些值来自步骤2 实验，δ=0.001 的结果
g_FD_data = [
    1,   -3.7168e-12;   % body, d=0.102
    161, -6.2773e-12;   % body, d=0.099
    200, -5.0570e-12;   % mid, d=0.042
    279, -6.3642e-11;   % mid, d=0.038
    285, -3.9691e-11;   % bnd, d=0.008
    326, -1.4808e-11;   % mid, d=0.047
    338, -1.8900e-11;   % body, d=0.075
    415, -2.4140e-11;   % bnd, d=0.014
    426, -1.5098e-11;   % mid, d=0.041
    502, -3.7414e-11;   % mid, d=0.048
    513, -7.8376e-12;   % body, d=0.080
    673, +1.7544e-13;   % body, d=0.128
];
N_sel = size(g_FD_data, 1);
sel_voxels = g_FD_data(:, 1);  % inner 索引
g_FD_vals = g_FD_data(:, 2);   % ∂F/∂ε_v

%% 正演 + 伴随求解
fprintf('\n[S3] 正演 + 伴随求解...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

% 伴随源（去归一化）
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj = Js + Ms;

[lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
if ~ok, fprintf('[S3] [FAIL]\n'); return; end
fprintf('[S3] lambda: |mean|=%.4e\n', mean(vecnorm(lambda, 2, 2)));

%% 4 种公式对比
k0_sq = pf.k0^2; dV_vec = voxel.dV;

% 提取选定体素的 E 和 lambda
E_sel = E_total(sel_voxels, :);       % [N_sel x 3]
lambda_sel = lambda(sel_voxels, :);    % [N_sel x 3]
dV_sel = dV_vec(inner_idx(sel_voxels)); % [N_sel x 1]

% 公式 A: k0^2*dV*Re(sum(lambda.*E))  bilinear +
g_A = k0_sq .* dV_sel .* real(sum(lambda_sel .* E_sel, 2));

% 公式 B: -k0^2*dV*Re(sum(lambda.*E))  bilinear -
g_B = -g_A;

% 公式 C: k0^2*dV*Re(dot(E,lambda))  Hermitian +
g_C = k0_sq .* dV_sel .* real(sum(conj(E_sel) .* lambda_sel, 2));

% 公式 D: -k0^2*dV*Re(dot(E,lambda))  Hermitian -
g_D = -g_C;

% sign 对比
signs_FD = sign(g_FD_vals);
signs_A = sign(g_A);
signs_B = sign(g_B);
signs_C = sign(g_C);
signs_D = sign(g_D);

%% 输出
fprintf('\n############################################################\n');
fprintf('#  步骤3 结果: 逐体素 sign 对比\n');
fprintf('############################################################\n');
fprintf('#  体素  g_FD          A:blin+    B:blin-    C:herm+    D:herm-    FD  A  B  C  D\n');
fprintf('#  ----  ----------    --------   --------   --------   --------    -- -- -- -- --\n');

for vi = 1:N_sel
    sFD = signs_FD(vi);
    sA = signs_A(vi); sB = signs_B(vi);
    sC = signs_C(vi); sD = signs_D(vi);

    % 标记 sign 是否与 FD 一致
    mA = ''; mB = ''; mC = ''; mD = '';
    if sA == sFD, mA = 'Y'; else, mA = 'N'; end
    if sB == sFD, mB = 'Y'; else, mB = 'N'; end
    if sC == sFD, mC = 'Y'; else, mC = 'N'; end
    if sD == sFD, mD = 'Y'; else, mD = 'N'; end

    fprintf('#  %3d   %+.4e   %+.3e  %+.3e  %+.3e  %+.3e  %+d %+d %+d %+d %+d %s%s%s%s\n', ...
        sel_voxels(vi), g_FD_vals(vi), g_A(vi), g_B(vi), g_C(vi), g_D(vi), ...
        sFD, sA, sB, sC, sD, mA, mB, mC, mD);
end

% 统计
n_A = sum(signs_A == signs_FD);
n_B = sum(signs_B == signs_FD);
n_C = sum(signs_C == signs_FD);
n_D = sum(signs_D == signs_FD);

fprintf('#\n#  sign 与 FD 一致数:\n');
fprintf('#    A: bilinear +: %d/%d\n', n_A, N_sel);
fprintf('#    B: bilinear -: %d/%d\n', n_B, N_sel);
fprintf('#    C: Hermitian+: %d/%d\n', n_C, N_sel);
fprintf('#    D: Hermitian-: %d/%d\n', n_D, N_sel);

% 最佳模式
best_n = max([n_A, n_B, n_C, n_D]);
best_modes = {};
if n_A == best_n, best_modes{end+1} = 'A: bilinear+'; end
if n_B == best_n, best_modes{end+1} = 'B: bilinear-'; end
if n_C == best_n, best_modes{end+1} = 'C: Hermitian+'; end
if n_D == best_n, best_modes{end+1} = 'D: Hermitian-'; end

fprintf('#\n#  最佳: %s (%d/%d)\n', strjoin(best_modes, ', '), best_n, N_sel);
if best_n == N_sel
    fprintf('#  *** 步骤3 通过：所有体素 sign 一致！***\n');
else
    fprintf('#  部分不一致\n');
end
fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir,'dir'), mkdir(results_dir); end
save(fullfile(results_dir,'step3_lambda_vs_fd.mat'), ...
    'sel_voxels', 'g_FD_vals', 'g_A', 'g_B', 'g_C', 'g_D', ...
    'signs_FD', 'signs_A', 'signs_B', 'signs_C', 'signs_D');
end
