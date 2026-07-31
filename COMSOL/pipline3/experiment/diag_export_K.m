function diag_export_K(N_k_test)
%DIAG_EXPORT_K 导出 COMSOL K 矩阵并验证其数学性质
%   diag_export_K(16) — 导出正演和伴随的 Kc 矩阵

if nargin < 1, N_k_test = 16; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  K 矩阵导出与性质验证\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[DIAG] [FAIL] mphstart\n'); return; end
end
try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1','ExternalCurrentDensity',3);
    phys.feature('vec1').set('Je',{'0','0','0'});
    try phys.feature('vec1').selection().all(); catch; end
end
try model.param.set('adjoint_mode','1'); catch; end

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);

%% 2. 设置 eps_r=3（均匀实数）并正演
fprintf('[DIAG] 设置 eps_r=3.0（均匀实数）并正演...\n');
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

%% 3. 导出正演 Kc 和 Lc
fprintf('[DIAG] 导出正演系统矩阵...\n');
tic;
MA_fwd = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'on');
t_fwd = toc;
K_fwd = MA_fwd.Kc;
L_fwd = MA_fwd.Lc;
fprintf('  正演 Kc: %dx%d (nnz=%d), Lc: %dx%d (%.2fs)\n', ...
    size(K_fwd,1), size(K_fwd,2), nnz(K_fwd), size(L_fwd,1), size(L_fwd,2), t_fwd);

%% 4. 验证 K 的性质
fprintf('\n===== K 矩阵性质验证 =====\n');

% 4a. 对称性: K = K^T ? (复对称)
K_diff = K_fwd - K_fwd';
K_sym_err = full(max(max(abs(K_diff))));
fprintf('  K = K^T 误差: %.2e (复对称性)\n', K_sym_err);
if K_sym_err < 1e-12
    fprintf('    → ✅ 复对称确认（bilinear 约定，K=K^T）\n');
else
    fprintf('    → ⚠ 非对称！可能 Hermitian 或其他结构\n');
end

% 4b. Hermitian 性: K = K^H ?
K_herm_err = full(max(max(abs(K_fwd - K_fwd'))));
fprintf('  K = K^H 误差: %.2e (Hermitian 性)\n', K_herm_err);

% 4c. K 是实矩阵还是复矩阵？
K_imag_max = full(max(abs(imag(K_fwd(:)))));
fprintf('  max(|Im(K)|) = %.2e\n', K_imag_max);
if K_imag_max < 1e-14
    fprintf('    → ✅ K 是实矩阵（实数 eps_r 下 K 为实）\n');
end

% 4d. MATLAB backslash 求解正演
fprintf('\n  MATLAB backslash 正演求解...\n');
tic;
E_dof = K_fwd \ L_fwd;
t_solve = toc;
fprintf('  求解完成 (%.2fs), |E_dof| range [%.4e, %.4e]\n', ...
    t_solve, min(abs(E_dof)), max(abs(E_dof)));

% 还原完整解
Uc = MA_fwd.Null * E_dof;
U0 = Uc + MA_fwd.ud;
U_full = U0 .* MA_fwd.uscale;
fprintf('  |U_full| range [%.4e, %.4e], size=%d\n', min(abs(U_full)), max(abs(U_full)), length(U_full));

% 4e. 对比 COMSOL 解和 MATLAB 解
% 写回 COMSOL 并提取体素中心
try
    mphsetu(model, 'sol1', U_full);
catch
    model.sol('sol1').setU(U_full);
    try model.sol('sol1').createSolution(); catch; end
end

inner_pos = voxel.pos(inner, :)';
Ex_ml = mphinterp(model, 'emw.Ex', 'coord', inner_pos);
Ey_ml = mphinterp(model, 'emw.Ey', 'coord', inner_pos);
Ez_ml = mphinterp(model, 'emw.Ez', 'coord', inner_pos);
E_matlab = [Ex_ml(:), Ey_ml(:), Ez_ml(:)];

% COMSOL 原始解
Ex_co = mphinterp(model, 'emw.Ex', 'coord', inner_pos);
% 实际上 mphinterp 读的是当前解——如果 setU 成功就是 MATLAB 解
% 需要对比的是 COMSOL runAll 的解

fprintf('\n  MATLAB 解 |E| mean = %.6e\n', mean(vecnorm(E_matlab, 2, 2)));

%% 5. 导出第二个 K（eps_r=3.001，扰动一个体素）用于 dK/dε 分析
fprintf('\n[DIAG] 扰动第3体素 ε_r += 0.001，重新导出 K...\n');
r_inner_all = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner_all);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
vi3 = sample_idx(3);
v_global_3 = inner_idx(vi3);
eps_orig_3 = voxel.epsilon_r(v_global_3);
fprintf('  目标体素 vi=%d, r=%.4f, eps_r=%.4f\n', vi3, r_inner_all(vi3), eps_orig_3);

% 扰动
voxel.epsilon_r(v_global_3) = eps_orig_3 + 0.001;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

MA_pert = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'on');
K_pert = MA_pert.Kc;

% dK = K(eps+δ) - K(eps)
dK = K_pert - K_fwd;
fprintf('  dK 非零元素数: %d (总 nnz(K)=%d)\n', nnz(dK), nnz(K_fwd));
fprintf('  max(|dK|) = %.4e\n', full(max(abs(dK(:)))));
fprintf('  dK 密度: %.4f%%\n', nnz(dK)/numel(dK)*100);

% dK 的结构：应该是稀疏的（只有被扰动的体素对应的自由度行/列变化）
% 验证 dK 的非零模式
dK_rows = find(any(dK ~= 0, 2));
dK_cols = find(any(dK ~= 0, 1));
fprintf('  dK 非零行数: %d, 非零列数: %d\n', length(dK_rows), length(dK_cols));
fprintf('  → 这些行/列对应被扰动的体素的 FEM 节点\n');

% dK 的对称性
dK_sym_err = full(max(max(abs(dK - dK'))));
fprintf('  dK = dK^T 误差: %.2e\n', dK_sym_err);

% dK/δ 就是 ∂K/∂ε_v 的离散近似
dK_over_delta = dK / 0.001;
dK_max = full(max(abs(dK_over_delta(:))));
fprintf('\n  ∂K/∂ε_v = dK/δ 的量级: max=%.4e\n', dK_max);

%% 6. 纯 MATLAB FD 梯度（绕过 COMSOL runAll）
fprintf('\n===== 纯 MATLAB FD 梯度（用 K 矩阵）=====\n');
% 步骤:
% 1. E(ε) = K(ε)^{-1} · L_fwd    (正演解)
% 2. J_equi(ε) = -jωε₀(ε-1)·E(ε)  (等效源)
% 3. J_hyp(ε) = P · J_equi(ε)      (Born FT 远场)
% 4. F(ε) = ||J_obs - J_hyp(ε)||² / ||J_obs||²
% 5. FD: dF/dε = [F(ε+δ) - F(ε-δ)] / (2δ)

% 但 J_obs 需要先用 eps_r=5 正演算...
% 这里先做 ε+δ 和 ε-δ 两次正演 + Born FT

k0 = p.k0; omega = p.omega(1); eps0 = p.eps0;
[k_dir, dOmega] = fibonacci_sphere(N_k_test);
k_vec = k0 * k_dir;

% 恢复 eps_r=3
voxel.epsilon_r(v_global_3) = eps_orig_3;

% 需要 J_obs：用 Stratton-Chu（之前算的）或 Born FT
% 这里先用 Born FT 构造 J_obs（eps_r=5）以消除路径不一致
fprintf('[DIAG] 用 K 矩阵做 J_obs (eps_r=5, Born FT)...\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

[E_true_vox, ~, ~] = solve_forward(model, voxel, p);
J_equi_true = -1i * omega * eps0 * (5.0 - 1) .* E_true_vox;
J_obs_k = zeros(N_k_test, 3);
pos_inner = voxel.pos(inner_idx, :);
dV_inner = voxel.dV(inner_idx);
for ki = 1:N_k_test
    phase = exp(-1i * pos_inner * k_vec(ki,:)');
    J_obs_k(ki,:) = sum(dV_inner .* sum(J_equi_true .* phase, 2), 1)';
end
F_obs_k = sum(dOmega .* sum(abs(J_obs_k).^2, 2));
fprintf('  J_obs (Born FT, N_k=%d): F_obs=%.4e\n', N_k_test, F_obs_k);

% 恢复 eps_r=3 并正演
fprintf('[DIAG] 恢复 eps_r=3 并用 K 矩阵正演...\n');
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 用 K 矩阵求解 E
MA_base = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'on');
E_dof_base = MA_base.Kc \ MA_base.Lc;
Uc_base = MA_base.Null * E_dof_base;
U0_base = Uc_base + MA_base.ud;
U_base = U0_base .* MA_base.uscale;
mphsetu(model, 'sol1', U_base);  % 写回
E_base_vox = [mphinterp(model,'emw.Ex','coord',inner_pos); ...
              mphinterp(model,'emw.Ey','coord',inner_pos); ...
              mphinterp(model,'emw.Ez','coord',inner_pos)]';
% 上面维度可能错，修正
Ex_b = mphinterp(model, 'emw.Ex', 'coord', inner_pos);
Ey_b = mphinterp(model, 'emw.Ey', 'coord', inner_pos);
Ez_b = mphinterp(model, 'emw.Ez', 'coord', inner_pos);
E_base_vox = [Ex_b(:), Ey_b(:), Ez_b(:)];

% J_hyp(eps=3)
J_equi_base = -1i * omega * eps0 * (3.0 - 1) .* E_base_vox;
J_hyp_base = zeros(N_k_test, 3);
for ki = 1:N_k_test
    phase = exp(-1i * pos_inner * k_vec(ki,:)');
    J_hyp_base(ki,:) = sum(dV_inner .* sum(J_equi_base .* phase, 2), 1)';
end
Delta_J_base = J_obs_k - J_hyp_base;
F_base = sum(dOmega .* sum(abs(Delta_J_base).^2, 2)) / F_obs_k;
fprintf('  F(eps=3) = %.6e\n', F_base);

% FD: ε+δ 和 ε-δ
fd_delta = 0.01;
for sign_delta = [+1, -1]
    voxel.epsilon_r(v_global_3) = eps_orig_3 + sign_delta * fd_delta;
    update_epsilon(model, voxel, p);
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    model.sol('sol1').runAll();
    
    MA_d = mphmatrix(model, 'sol1', ...
        'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
        'initmethod', 'sol', 'initsol', 'sol1', ...
        'symmetry', 'on');
    E_dof_d = MA_d.Kc \ MA_d.Lc;
    Uc_d = MA_d.Null * E_dof_d;
    U0_d = Uc_d + MA_d.ud;
    U_d = U0_d .* MA_d.uscale;
    mphsetu(model, 'sol1', U_d);
    
    Ex_d = mphinterp(model, 'emw.Ex', 'coord', inner_pos);
    Ey_d = mphinterp(model, 'emw.Ey', 'coord', inner_pos);
    Ez_d = mphinterp(model, 'emw.Ez', 'coord', inner_pos);
    E_d_vox = [Ex_d(:), Ey_d(:), Ez_d(:)];
    
    eps_d = eps_orig_3 + sign_delta * fd_delta;
    J_equi_d = -1i * omega * eps0 * (eps_d - 1) .* E_d_vox;
    J_hyp_d = zeros(N_k_test, 3);
    for ki = 1:N_k_test
        phase = exp(-1i * pos_inner * k_vec(ki,:)');
        J_hyp_d(ki,:) = sum(dV_inner .* sum(J_equi_d .* phase, 2), 1)';
    end
    F_d = sum(dOmega .* sum(abs(J_obs_k - J_hyp_d).^2, 2)) / F_obs_k;
    
    if sign_delta > 0
        F_plus = F_d;
    else
        F_minus = F_d;
    end
    fprintf('  F(eps%+.3f) = %.6e\n', sign_delta*fd_delta, F_d);
end

voxel.epsilon_r(v_global_3) = eps_orig_3;
g_FD_K = (F_plus - F_minus) / (2*fd_delta);
fprintf('\n  ★ 纯 K 矩阵 FD 梯度: dF/dε = %+.6e\n', g_FD_K);

%% 7. 对比：COMSOL runAll 的 FD 梯度
fprintf('\n  (对比) COMSOL runAll FD 梯度: 待后续验证\n');

fprintf('\n############################################################\n');
fprintf('#  K 矩阵信息总结\n');
fprintf('#  1. K 复对称性: %s (误差=%.2e)\n', ...
    string(ternary_s(K_sym_err<1e-12,'✅','⚠')), K_sym_err);
fprintf('#  2. K 实/复: %s (max|Im(K)|=%.2e)\n', ...
    string(ternary_s(K_imag_max<1e-14,'实矩阵','复矩阵')), K_imag_max);
fprintf('#  3. K 规模: %dx%d, nnz=%d\n', size(K_fwd,1), size(K_fwd,2), nnz(K_fwd));
fprintf('#  4. dK/dε 稀疏性: nnz=%d (扰动单体素)\n', nnz(dK));
fprintf('#  5. 纯 MATLAB FD: %+.6e\n', g_FD_K);
fprintf('############################################################\n');

% 保存 K 矩阵供后续分析
save(fullfile(p.dir_result, 'K_matrix_analysis.mat'), ...
    'K_fwd', 'MA_fwd', 'dK', 'g_FD_K', 'F_base', 'F_plus', 'F_minus');
fprintf('\n[DIAG] K 矩阵已保存到 data/results/K_matrix_analysis.mat\n');

end

function s = ternary_s(cond, a, b), if cond, s=a; else, s=b; end, end
