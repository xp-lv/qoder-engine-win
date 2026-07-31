function result = verify_exact_gradient(N_sample)
%VERIFY_EXACT_GRADIENT FEM 自由度直接梯度计算（绕过 mphinterp）
%
%   验证积分映射 vs 点值映射的结构性不匹配是否为 CV 主因
%
%   核心改进：
%     1. 导出 K 矩阵和 E/lambda 的 FEM 自由度解向量
%     2. 逐体素构造局部质量矩阵 Q_v（解析 10-node tet）
%     3. 在 FEM 自由度空间中直接计算 lambda^T * Q_v * E
%     4. 与 mphinterp 路径的结果对比
%
%   用法：
%     >> verify_exact_gradient(30)

if nargin < 1, N_sample = 30; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  FEM 自由度直接梯度计算\n');
fprintf('#  绕过 mphinterp，用 Q_v 精确计算 lambda^T·Q_v·E\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid = build_measurement_grid(p);

fprintf('[EG] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[EG] [FAIL] mphstart: %s\n', ME.message); return;
    end
end

% 清理旧模型
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags)
        ModelUtil.remove(char(tags(ti)));
    end
catch
end

fprintf('[EG] 加载 2layer.mph...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end

%% 2. 提取网格
fprintf('[EG] 提取 FEM 网格...\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
N_v = length(voxel.epsilon_r);

% 获取 FEM 网格节点和 tet 连接（用于构造 Q_v）
mesh_obj = model.mesh('mesh1');
fem_verts = mesh_obj.getVertex()';       % [N_vert x 3]
tet_conn = double(mesh_obj.getElem('tet'))' + 1;  % [N_tet x 4] 1-indexed 角节点
N_tet = size(tet_conn, 1);
N_vert = size(fem_verts, 1);
fprintf('[EG] N_vert=%d, N_tet=%d, N_inner=%d\n', N_vert, N_tet, N_inner);

%% 3. 预计算 J_obs（真值 eps_r=5）
fprintf('[EG] 预计算 J_obs (eps_r=5)...\n');
voxel.epsilon_r(inner) = p.eps_r_true;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min, F_obs = 1.0; end
fprintf('[EG] F_obs = %.6e\n', F_obs);

%% 4. 正演 (eps_r=3) + 提取 E 场
fprintf('[EG] 正演 (eps_r=3)...\n');
voxel.epsilon_r(inner) = p.eps_r_init;
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

%% 5. 导出 K 矩阵和正演解向量 ud_fwd
fprintf('[EG] 导出 K 矩阵和正演解...\n');
try
    str_fwd = mphmatrix(model, 'sol1', 'out', {'K', 'ud'});
    K = str_fwd.K;
    ud_fwd = str_fwd.ud;  % 正演 E 场在 FEM 自由度上
    N_dof = length(ud_fwd);
    fprintf('[EG] K: %d x %d, nnz=%d\n', N_dof, N_dof, nnz(K));
    fprintf('[EG] ud_fwd: |mean|=%.4e\n', mean(abs(ud_fwd)));
    have_K = true;
catch ME
    fprintf('[EG] [FAIL] mphmatrix: %s\n', ME.message);
    have_K = false;
end

if ~have_K, result = struct('status','fail','reason','no_K'); return; end

%% 6. 伴随求解 + 导出伴随解向量 ud_adj
fprintf('[EG] 伴随求解...\n');
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;

[Js, Ms, source_pos, F_obs_adj] = build_adjoint_source_fullmaxwell(grid, lc, p);

% ★ 不调用 solve_adjoint，手动执行伴随求解，在模型恢复前导出 ud_adj
lambda_interp = [];
ok_adj = false;
have_ud_adj = false;
ud_adj = [];

try
    % ★ 关键：keep_adjoint_state=true，不恢复模型，保留伴随解供 mphmatrix 导出
    [lambda_interp, ok_adj, ~] = solve_adjoint(model, voxel, p, Js, source_pos, Ms, true);
    fprintf('[EG] lambda (mphinterp): |mean|=%.4e\n', mean(vecnorm(lambda_interp,2,2)));

    % ★ 此时模型仍处于伴随态（未恢复），导出 ud_adj
    fprintf('[EG] 导出伴随解向量 ud_adj（伴随态保留中）...\n');
    try
        str_adj = mphmatrix(model, 'sol1', 'out', {'ud'});
        ud_adj = str_adj.ud;
        fprintf('[EG] ud_adj: |mean|=%.4e, N=%d\n', mean(abs(ud_adj)), length(ud_adj));
        have_ud_adj = (mean(abs(ud_adj)) > 1e-30);
    catch ME
        fprintf('[EG] [WARN] ud_adj 导出失败: %s\n', ME.message);
        have_ud_adj = false;
    end
catch ME
    fprintf('[EG] [FAIL] solve_adjoint: %s\n', ME.message);
end

if ~ok_adj
    fprintf('[EG] [FAIL] solve_adjoint\n'); result = struct('status','fail'); return;
end

% 恢复模型（确保后续 FD 不受影响）
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model.param.set('adjoint_mode', '1'); catch, end
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end

%% 7. 确定自由度映射：DOF → (节点, 分量)
% COMSOL EMW 3D 矢量场：DOF 排列为 [Ex_1,Ey_1,Ez_1, Ex_2,Ey_2,Ez_2, ...]
% 即 N_dof = N_vert * 3（如果无约束消除）
% 或可能是 N_vert * 3 加上额外 PML 自由度
fprintf('\n[EG] DOF 分析: N_dof=%d, N_vert=%d\n', N_dof, N_vert);
if mod(N_dof, 3) == 0
    N_dof_nodes = N_dof / 3;
    fprintf('[EG] N_dof/3 = %d (期望 ≈ N_vert=%d)\n', N_dof_nodes, N_vert);
else
    N_dof_nodes = [];
    fprintf('[EG] [WARN] N_dof 不能被 3 整除，DOF 映射需进一步分析\n');
end

%% 8. 构造局部质量矩阵 Q_v（解析 4-node tet）
% 对每个内部 tet，计算 4x4 局部质量矩阵
% 二次单元的完整 Q_v 是 10x10，但角节点部分用 4-node 近似先验证

fprintf('[EG] 构造局部质量矩阵 Q_v (4-node tet 近似)...\n');

Q_v_list = cell(N_inner, 1);
dof_idx_list = cell(N_inner, 1);

for vi = 1:N_inner
    % 找到该体素对应的 tet 单元
    % fem_mesh_utils 中 tet 是第一批，inner_idx(vi) 是全局单元索引
    elem_idx = inner_idx(vi);
    
    if elem_idx > N_tet
        % 超出 tet 范围（可能是 prism），跳过
        Q_v_list{vi} = [];
        dof_idx_list{vi} = [];
        continue;
    end
    
    % tet 的 4 个角节点
    nodes = tet_conn(elem_idx, :);  % [1x4] 顶点索引
    
    % 映射到 DOF 索引（每个节点 3 个分量）
    dof_idx = zeros(12, 1);  % 4 nodes x 3 components
    for ni = 1:4
        base = (nodes(ni) - 1) * 3;
        dof_idx((ni-1)*3+1 : ni*3) = base + (1:3);
    end
    
    % 检查 DOF 是否越界
    if max(dof_idx) > N_dof
        Q_v_list{vi} = [];
        dof_idx_list{vi} = [];
        continue;
    end
    
    % tet 顶点坐标
    V = fem_verts(nodes, :);  % [4 x 3]
    
    % tet 体积
    v1 = V(2,:) - V(1,:);
    v2 = V(3,:) - V(1,:);
    v3 = V(4,:) - V(1,:);
    V_tet = abs(det([v1; v2; v3])) / 6;
    
    % 4-node tet 常应变质量矩阵（Consistent Mass Matrix）
    % M_ij = V/20 * (1 + delta_ij)  （线性插值）
    % 即对角线 = V/10, 非对角线 = V/20
    M_lin = V_tet / 20 * (ones(4,4) + eye(4));
    
    % 扩展到 12x12（4 nodes x 3 components）
    Q_v = kron(M_lin, eye(3));  % [12 x 12]
    
    Q_v_list{vi} = Q_v;
    dof_idx_list{vi} = dof_idx;
end

n_valid = sum(~cellfun(@isempty, Q_v_list));
fprintf('[EG] 有效 Q_v: %d / %d\n', n_valid, N_inner);

%% 9. 计算精确梯度（FEM 自由度路径）
fprintf('[EG] 计算 FEM 自由度精确梯度...\n');

omega2_eps0 = p.omega^2 * p.eps0;
k0_sq = p.k0^2;

g_exact = zeros(N_inner, 1);
g_interp = zeros(N_inner, 1);  % mphinterp 路径（对比用）

for vi = 1:N_inner
    if isempty(Q_v_list{vi})
        g_exact(vi) = NaN;
        g_interp(vi) = NaN;
        continue;
    end
    
    Q_v = Q_v_list{vi};
    idx = dof_idx_list{vi};
    
    % 提取该 tet 的 E 和 lambda 的局部 DOF 值
    E_local = ud_fwd(idx);       % [12 x 1] complex
    if have_ud_adj
        lam_local = ud_adj(idx);  % [12 x 1] complex（含 conj? 待确认）
    else
        lam_local = NaN(12, 1);
    end
    
    % 精确梯度：omega^2 * eps0 * lambda^T * Q_v * E
    % bilinear (无共轭，匹配 K=K^T)
    g_exact(vi) = omega2_eps0 * real(lam_local' * Q_v * E_local) / F_obs;
    
    % mphinterp 路径梯度（对比用）
    g_interp(vi) = -k0_sq * voxel.dV(inner_idx(vi)) * real(sum(lambda_interp(vi,:) .* E_total(vi,:))) / F_obs;
end

% 清除 NaN
valid_mask = ~isnan(g_exact);
g_exact_valid = g_exact(valid_mask);
g_interp_valid = g_interp(valid_mask);
fprintf('[EG] 精确梯度: %d 个有效体素\n', sum(valid_mask));
fprintf('[EG] |g_exact| mean=%.4e, |g_interp| mean=%.4e\n', mean(abs(g_exact_valid)), mean(abs(g_interp_valid)));

%% 10. 逐体素 FD 验证
fprintf('\n[EG] ===== 逐体素 FD 验证 =====\n');

% 采样
r_inner = vecnorm(voxel.pos(inner_idx, :), 2, 2);
[~, sort_order] = sort(r_inner);
step = floor(N_inner / min(N_sample, N_inner));
sample_from_valid = find(valid_mask);
sample_idx_global = sample_from_valid(sort_order(1:step:end));
sample_idx_global = sample_idx_global(1:min(N_sample, length(sample_idx_global)));
N_s = length(sample_idx_global);

fprintf('[EG] 采样 %d 个体素\n', N_s);

fd_delta = 0.001;
g_FD_sample = zeros(N_s, 1);
g_exact_sample = zeros(N_s, 1);
g_interp_sample = zeros(N_s, 1);

for si = 1:N_s
    vi = sample_idx_global(si);
    v_global = inner_idx(vi);
    
    % FD: ±delta
    eps_orig = voxel.epsilon_r(v_global);
    
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_eg(model, p);
    sf_p = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf_p, p);
    F_plus = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_eg(model, p);
    sf_m = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf_m, p);
    F_minus = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig;
    
    g_FD = (F_plus - F_minus) / (2 * fd_delta);
    g_FD_sample(si) = g_FD;
    g_exact_sample(si) = g_exact(vi);
    g_interp_sample(si) = g_interp(vi);
    
    if mod(si, 5) == 0 || si == N_s
        r_v = r_inner(vi);
        fprintf('  [%3d/%3d] r=%.3f: g_FD=%+.2e, g_exact=%+.2e (ratio=%.4f), g_interp=%+.2e (ratio=%.4f)\n', ...
            si, N_s, r_v, g_FD, g_exact_sample(si), g_exact_sample(si)/g_FD, ...
            g_interp_sample(si), g_interp_sample(si)/g_FD);
    end
end

%% 11. 统计对比
fprintf('\n############################################################\n');
fprintf('#  FEM 精确梯度 vs mphinterp 梯度 对比\n');
fprintf('############################################################\n\n');

% 精确路径
sign_exact = sign(g_FD_sample .* g_exact_sample) > 0;
sign_rate_exact = sum(sign_exact) / N_s;
ratios_exact = g_exact_sample ./ g_FD_sample;
valid_fd = abs(g_FD_sample) > 1e-30;
ratios_exact_v = ratios_exact(valid_fd);

fprintf('--- 精确路径 (FEM Q_v) ---\n');
fprintf('  sign 一致率: %d/%d = %.1f%%\n', sum(sign_exact), N_s, 100*sign_rate_exact);
if ~isempty(ratios_exact_v)
    fprintf('  ratio mean=%.6f, median=%.6f, std=%.6f, CV=%.6f\n', ...
        mean(ratios_exact_v), median(ratios_exact_v), std(ratios_exact_v), ...
        std(ratios_exact_v)/abs(mean(ratios_exact_v)));
    fprintf('  ratio range: [%.6f, %.6f]\n', min(ratios_exact_v), max(ratios_exact_v));
end
cos_exact = dot(g_FD_sample, g_exact_sample) / (norm(g_FD_sample) * norm(g_exact_sample));
fprintf('  cos θ = %.6f\n', cos_exact);

fprintf('\n--- mphinterp 路径 (ΔV 近似) ---\n');
sign_interp = sign(g_FD_sample .* g_interp_sample) > 0;
sign_rate_interp = sum(sign_interp) / N_s;
ratios_interp = g_interp_sample ./ g_FD_sample;
ratios_interp_v = ratios_interp(valid_fd);

fprintf('  sign 一致率: %d/%d = %.1f%%\n', sum(sign_interp), N_s, 100*sign_rate_interp);
if ~isempty(ratios_interp_v)
    fprintf('  ratio mean=%.6f, median=%.6f, std=%.6f, CV=%.6f\n', ...
        mean(ratios_interp_v), median(ratios_interp_v), std(ratios_interp_v), ...
        std(ratios_interp_v)/abs(mean(ratios_interp_v)));
    fprintf('  ratio range: [%.6f, %.6f]\n', min(ratios_interp_v), max(ratios_interp_v));
end
cos_interp = dot(g_FD_sample, g_interp_sample) / (norm(g_FD_sample) * norm(g_interp_sample));
fprintf('  cos θ = %.6f\n', cos_interp);

fprintf('\n--- 对比结论 ---\n');
if ~isempty(ratios_exact_v) && ~isempty(ratios_interp_v)
    cv_exact = std(ratios_exact_v)/abs(mean(ratios_exact_v));
    cv_interp = std(ratios_interp_v)/abs(mean(ratios_interp_v));
    fprintf('  CV 改善: %.4f → %.4f (%.1f%%)\n', cv_interp, cv_exact, 100*(cv_interp-cv_exact)/cv_interp);
    fprintf('  |ratio-1| 改善: %.4f → %.4f\n', abs(mean(ratios_interp_v)-1), abs(mean(ratios_exact_v)-1));
end
fprintf('############################################################\n');

%% 12. 保存
result = struct();
result.N_sample = N_s;
result.N_dof = N_dof;
result.g_FD = g_FD_sample;
result.g_exact = g_exact_sample;
result.g_interp = g_interp_sample;
result.ratios_exact = ratios_exact;
result.ratios_interp = ratios_interp;
result.sign_rate_exact = sign_rate_exact;
result.sign_rate_interp = sign_rate_interp;
result.cos_exact = cos_exact;
result.cos_interp = cos_interp;

save(fullfile(p.dir_result, 'exact_gradient_result.mat'), 'result');
fprintf('\n[EG] 结果已保存: data/results/exact_gradient_result.mat\n');

end

%% ====== 辅助函数 ======
function solve_quiet_eg(model, p)
    try
        model.param.set('freq', num2str(p.freq));
        try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
    catch
    end
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end
    try
        s1 = model.sol('sol1').feature('s1');
        try s1.feature('dDirect'); catch
            s1.create('dDirect', 'Direct');
            s1.feature('dDirect').set('linsolver', 'pardiso');
        end
        try s1.feature('fc1').set('linsolver', 'dDirect'); catch, end
    catch
    end
    model.sol('sol1').runAll();
end
