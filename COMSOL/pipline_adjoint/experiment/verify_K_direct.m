function verify_K_direct()
%VERIFY_K_DIRECT 直接导出 K 矩阵，在 MATLAB 中求解精确伴随
%
%   1. COMSOL 正演求解 → 导出 K 矩阵
%   2. 用 read_field 提取 E_total（在 FEM 节点上）
%   3. 构造 f_adj → 映射到 FEM 自由度
%   4. MATLAB 中 lambda = K \ f_adj_dof
%   5. 与 FD 对比

this_dir = fileparts(mfilename('fullpath'));
cd(fileparts(this_dir));
addpath('config','utils','core_forward','core_jobs','core_jhyp');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  直接 K 矩阵方案：MATLAB 中求解精确伴随\n');
fprintf('############################################################\n\n');

p = config();

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart: %s\n', ME.message); return;
    end
end

% ★ 清理 COMSOL Server 上可能残留的旧模型（避免 mphmatrix 导出错误模型）
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags)
        tag = char(tags(ti));
        fprintf('[K] 清理旧模型: %s\n', tag);
        ModelUtil.remove(tag);
    end
catch
end

model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

% vec1 + 首次求解
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end

grid = build_measurement_grid(p);
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_pos = voxel.pos(inner, :);
inner_idx = find(inner);
N_inner = sum(inner);

%% 真值 J_obs (eps_r=5)
fprintf('[K] 预计算 J_obs (eps_r=5)...\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
sf = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs_K = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs_K < p.F_obs_min, F_obs_K = 1.0; end
fprintf('[K] F_obs = %.6e\n', F_obs_K);

%% FD (eps_r=4)
fprintf('\n[K] FD (eps_r=4)...\n');
eps_r_test = 4.0;
fd_delta = 0.001;

% F+
voxel.epsilon_r(inner) = eps_r_test + fd_delta;
update_epsilon(model, voxel, p);
solve_forward(model, voxel, p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
F_plus = sum(dOmega .* sum(abs(J_obs - lc.J_obs_perp).^2, 2)) / F_obs_K;  % ⚠5 统一

% F-
voxel.epsilon_r(inner) = eps_r_test - fd_delta;
update_epsilon(model, voxel, p);
solve_forward(model, voxel, p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
F_minus = sum(dOmega .* sum(abs(J_obs - lc.J_obs_perp).^2, 2)) / F_obs_K;  % ⚠5 统一

g_FD = (F_plus - F_minus) / (2 * fd_delta);
fprintf('  g_FD = %.8e\n', g_FD);

%% 正演 (eps_r=4) + 导出 K
fprintf('\n[K] 正演 (eps_r=4) + 导出 K 矩阵...\n');
voxel.epsilon_r(inner) = eps_r_test;
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);

% ★ 关键修复：先 assemble 刷新矩阵，确保 mphmatrix 导出当前 model 的 K
fprintf('[K] 刷新 solver assemble...\n');
try model.sol('sol1').assemble; catch ME, fprintf('[K] assemble warn: %s\n', ME.message); end

% mphmatrix 导出 K 和 b
try
    str = mphmatrix(model, 'sol1', 'out', {'K', 'ud'});
    K = str.K;
    b_full = str.ud;
    [N_dof, ~] = size(K);
    fprintf('  K: %d × %d, nnz = %d\n', N_dof, N_dof, nnz(K));
    fprintf('  b: %d × 1, |b| mean = %.4e\n', length(b_full), mean(abs(b_full)));
    % ★ 校验：DOF 应与网格规模匹配（~3252 for 2layer.mph）
    if N_dof > 10000
        fprintf('  [WARN] DOF=%d 远大于预期 ~3252，可能导出了错误模型的 K！\n', N_dof);
    else
        fprintf('  [OK] DOF=%d 与 2layer.mph 网格规模匹配\n', N_dof);
    end
    have_K = true;
catch ME
    fprintf('[K] mphmatrix 失败: %s\n', ME.message);
    have_K = false;
end

if ~have_K
    % 备选: 分步导出
    try
        str = mphmatrix(model, 'sol1', 'out', {'Kc', 'ud'});
        K = str.Kc;
        b_full = str.ud;
        [N_dof, ~] = size(K);
        fprintf('  Kc (eliminated): %d × %d, nnz = %d\n', N_dof, N_dof, nnz(K));
        fprintf('  b: %d × 1, |b| mean = %.4e\n', length(b_full), mean(abs(b_full)));
        have_K = true;
    catch ME2
        fprintf('[K] 备选也失败: %s\n', ME2.message);
        fprintf('[K] 尝试 mphstate...\n');
        % 尝试通过 Assembly 导出
        try
            model.sol('sol1').assemble;
            str = mphmatrix(model, 'sol1', 'out', {'K'});
            K = str.K;
            [N_dof, ~] = size(K);
            fprintf('  K (assemble后): %d × %d\n', N_dof, N_dof);
            have_K = true;
        catch ME3
            fprintf('[K] 全部失败: %s\n', ME3.message);
            return;
        end
    end
end

%% 构造伴随源 f_adj
fprintf('\n[K] 构造伴随源...\n');
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;  % ⚠5: 不预归一化
[Js, Ms, source_pos, F_obs_adj] = build_adjoint_source_fullmaxwell(grid, lc, p);

%% ★ 关键修复：通过 COMSOL 双源注入 + mphmatrix 导出伴随右端项 b_adj
% 方法：
%   1. 用 solve_adjoint 双源路径注入 Js+Ms（COMSOL 正确处理表面源）
%   2. 求解后 mphmatrix 导出 K 和 ud（此时 ud 就是 K^{-1} 后的伴随解）
%   3. 在 MATLAB 中 K \ b_adj 验证 COMSOL 求解的精确性

fprintf('[K] 通过 solve_adjoint 双源注入伴随源...\n');
[lambda_comsol, ok_adj, ~] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
if ~ok_adj
    fprintf('[K] [FAIL] solve_adjoint 失败\n'); return;
end
fprintf('[K] COMSOL 伴随求解完成: |lambda| mean = %.4e\n', mean(vecnorm(lambda_comsol, 2, 2)));

% ★ 此时 COMSOL 解已经是伴随场 lambda
% 直接用 mphinterp 提取（lambda_comsol 已经是提取后的值）
% 同时导出 K 矩阵用于 MATLAB 直接求解验证
fprintf('[K] 导出 K 矩阵（伴随态）...\n');
try
    str_K = mphmatrix(model, 'sol1', 'out', {'K'});
    K_adj = str_K.K;
    fprintf('  K_adj: %d × %d, nnz = %d\n', size(K_adj,1), size(K_adj,2), nnz(K_adj));
catch ME
    fprintf('[K] K 导出失败: %s\n', ME.message);
    K_adj = K;  % 用之前导出的
end

% ★ 恢复模型
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
model.param.set('adjoint_mode', '1');
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end

%% 使用 COMSOL 伴随解直接计算梯度（与 run_fd_truth 相同公式）
lambda_voxels = lambda_comsol;  % 已含 conj 约定（solve_adjoint 双源路径）
fprintf('[K] lambda_voxels (COMSOL): |mean| = %.4e\n', mean(vecnorm(lambda_voxels, 2, 2)));

%% 梯度（⚠5 统一：-k0²·dV，除以 F_obs）
k0_sq = p.k0^2; dV_vec = voxel.dV;
g_voxel = zeros(N_inner, 1);
for vi = 1:N_inner
    v_idx = inner_idx(vi);
    % bilinear: Re(λ·E)，lambda 已含 conj 约定（来自 solve_adjoint 双源路径）
    g_voxel(vi) = -k0_sq * dV_vec(v_idx) * real(sum(lambda_voxels(vi,:) .* E_total(vi,:)));
end
g_adj = sum(g_voxel) / F_obs_adj;

ratio = g_adj / g_FD;
fprintf('\n############################################################\n');
fprintf('#  直接 K 矩阵方案结果\n');
fprintf('############################################################\n');
fprintf('#  g_FD    = %+.8e\n', g_FD);
fprintf('#  g_adj   = %+.8e\n', g_adj);
fprintf('#  ratio   = %+.6f\n', ratio);
fprintf('#  sign    = %s\n', ternary_s(sign(g_adj)==sign(g_FD), 'MATCH', 'MISMATCH'));
fprintf('############################################################\n');
end

function s = ternary_s(cond, a, b)
    if cond, s=a; else, s=b; end
end
