function result = compare_3path_gradient(N_sample)
%COMPARE_3PATH_GRADIENT 三路径梯度对比
%
%   路径1: FD（中心差分）= 真值
%   路径2: mphinterp（当前代码，含 Qv 对角近似）
%   路径3: FEM 自由度（精确矩阵运算 lambda^T * M_v * E）
%
%   对比目标：路径3 的 ratio 是否接近 1（证明偏差来自 mphinterp 近似）

if nargin < 1, N_sample = 15; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  三路径梯度对比\n');
fprintf('#  路径1: FD（真值）\n');
fprintf('#  路径2: mphinterp（当前代码）\n');
fprintf('#  路径3: FEM自由度（精确矩阵运算）\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[C3] [FAIL]\n'); return; end
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
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('[C3] N_inner=%d\n', N_inner);

% 获取 FEM 网格信息（用于路径3）
mesh_obj = model.mesh('mesh1');
fem_verts = mesh_obj.getVertex()';  % [N_vert x 3]
tet_conn_raw = mesh_obj.getElem('tet')';  % 注意 COMSOL 返回格式
tet_conn = double(tet_conn_raw) + 1;  % 1-indexed
N_tet = size(tet_conn, 1);
N_vert = size(fem_verts, 1);
fprintf('[C3] N_vert=%d, N_tet=%d\n', N_vert, N_tet);

%% 2. J_obs（真值 eps_r=5）
fprintf('[C3] 预计算 J_obs...\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
sf_obs = extract_scattered(model, grid_meas);
lc_obs = lightcone_project(grid_meas, sf_obs, p);
J_obs = lc_obs.J_obs_perp; dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end

%% 3. 正演 eps_r=3 + 导出 K, M, ud_fwd
fprintf('[C3] 正演 (eps_r=3) + 导出矩阵...\n');
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);

% 确保正演模式
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end
try model.param.set('adjoint_mode','1'); catch; end
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end

% PARDISO
try
    s1 = model.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
    end
    try s1.feature('fc1').set('linsolver','dDirect'); catch; end
catch
end
model.sol('sol1').runAll();
fprintf('[C3] 正演完成\n');

% 导出 K, E(质量矩阵), L(载荷), 解向量
fprintf('[C3] 导出 K, E(mass), L(load), U_fwd...\n');
try
    % K=刚度, E=质量矩阵(COOMSOL文档中E是mass), L=载荷向量
    str_fwd = mphmatrix(model, 'sol1', 'out', {'K', 'E', 'L'});
    K_fwd = str_fwd.K;
    M_global = str_fwd.E;   % ★ E = 质量矩阵（不是 M！）
    b_fwd = str_fwd.L;      % 载荷向量
    N_dof = size(K_fwd, 1);
    fprintf('[C3] K: %dx%d nnz=%d\n', N_dof, N_dof, nnz(K_fwd));
    fprintf('[C3] E(mass): %dx%d nnz=%d\n', N_dof, N_dof, nnz(M_global));
    fprintf('[C3] L(load): %dx1 |mean|=%.4e\n', length(b_fwd), mean(abs(b_fwd)));
    
    % 解向量从 mphstate 获取（散射场公式下 ud=0，真正解在 mphstate 中）
    U_fwd = mphstate(model, 'sol1');  % [N_dof x 1] complex 解向量
    fprintf('[C3] U_fwd: |mean|=%.4e, N=%d\n', mean(abs(U_fwd)), length(U_fwd));
    have_matrices = true;
catch ME
    fprintf('[C3] [WARN] mphmatrix/mphstate 失败: %s\n', ME.message);
    have_matrices = false;
end

% 路径2: mphinterp 正演场
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
sf = extract_scattered(model, grid_meas);
lc = lightcone_project(grid_meas, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[C3] F_data=%.6e\n', F_data);

%% 4. 伴随求解 + 导出 ud_adj
fprintf('[C3] 伴随求解...\n');
lc.k_vec = p.k0 * lc.k_dir; lc.J_obs_perp = J_obs; lc.Delta_J_perp = Delta_J;
[Js, Ms_adj, source_pos, ~] = build_adjoint_source_fullmaxwell(grid_meas, lc, p);

% 用 keep_adjoint_state=true 保留伴随态
[lambda_interp, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms_adj, true);
if ~ok_adj, fprintf('[C3] [FAIL] adjoint\n'); return; end

% 导出伴随解向量（此时模型处于伴随态）
if have_matrices
    fprintf('[C3] 导出 U_adj (mphstate)...\n');
    try
        U_adj = mphstate(model, 'sol1');  % 伴随解向量
        fprintf('[C3] U_adj: |mean|=%.4e, N=%d\n', mean(abs(U_adj)), length(U_adj));
        have_ud_adj = (mean(abs(U_adj)) > 1e-30);
        if length(U_adj) ~= N_dof
            fprintf('[C3] [WARN] U_adj 长度=%d != K 长度=%d\n', length(U_adj), N_dof);
            have_ud_adj = false;
        end
    catch ME
        fprintf('[C3] [WARN] U_adj 导出失败: %s\n', ME.message);
        have_ud_adj = false;
    end
end

% 恢复模型
try phys.feature('vec1').set('Je',{'0','0','0'}); catch; end
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try model.param.set('adjoint_mode','1'); catch; end
try phys.feature().remove('sc_adj'); catch; end
try phys.feature().remove('ms_adj'); catch; end

%% 5. 路径2: mphinterp 梯度（当前代码）
k0_sq = p.k0^2; dV_vec = voxel.dV;
g_mphinterp = zeros(N_inner, 1);
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) && size(E_gauss,1)==size(voxel.gauss_pos,1);
if use_gauss
    gw = voxel.gauss_w;
    for vi=1:N_inner
        gp=(4*(vi-1)+1):(4*vi); gs=0;
        for gpi=1:4, gs=gs+gw(gpi)*real(sum(E_gauss(gp(gpi),:).*lambda_gauss(gp(gpi),:))); end
        g_mphinterp(vi) = -k0_sq*dV_vec(inner_idx(vi))*gs;
    end
else
    for vi=1:N_inner, g_mphinterp(vi)=-k0_sq*dV_vec(inner_idx(vi))*real(sum(E_total(vi,:).*lambda_interp(vi,:))); end
end
g_mphinterp = g_mphinterp / F_obs;

%% 6. 路径3: FEM 自由度精确梯度
% ud_adj 取了 conj（与 solve_adjoint 双源路径一致）
omega2_eps0 = p.omega^2 * p.eps0;
g_fem = zeros(N_inner, 1);

if have_matrices && have_ud_adj
    fprintf('[C3] 计算路径3 (FEM自由度精确梯度)...\n');
    
    % U_adj 取 conj（双源路径约定）
    lambda_dof = conj(U_adj);
    E_dof = U_fwd;
    
    % 检查 M_global 是否有非零元素
    nnz_M = nnz(M_global);
    fprintf('[C3] M_global nnz=%d\n', nnz_M);
    
    if nnz_M > 0
    
    % 方法 A：全局内积 <lambda, M*E>
    global_product = lambda_dof' * M_global * E_dof;
    fprintf('[C3] 全局 <lambda, M*E> = %.8e + %.8ei\n', real(global_product), imag(global_product));
    
    % 全局精确梯度 = 2*omega^2*eps0 * Re(global_product)
    g_global_exact = 2 * omega2_eps0 * real(global_product) / F_obs;
    
    % 同时计算全局 mphinterp 梯度
    g_global_mphinterp = sum(g_mphinterp);
    
    fprintf('\n[C3] ===== 全局梯度对比 =====\n');
    fprintf('  mphinterp 全局: %+.8e\n', g_global_mphinterp);
    fprintf('  FEM精确 全局:   %+.8e\n', g_global_exact);
    if abs(g_global_mphinterp) > 1e-30
        fprintf('  ratio (FEM/mphinterp): %.6f\n', g_global_exact / g_global_mphinterp);
    end
    
    % 方法 B：逐体素提取局部块
    fprintf('\n[C3] 尝试逐体素路径3...\n');
    n_fem_success = 0;
    
    for vi = 1:N_inner
        elem_idx = inner_idx(vi);
        
        if elem_idx > N_tet
            g_fem(vi) = NaN; continue;
        end
        
        % tet 的角节点（4 节点线性 tet）
        nodes = tet_conn(elem_idx, :);
        
        % 映射到 DOF（每节点 3 分量）
        dof_idx = zeros(12, 1);
        for ni = 1:4
            base = (nodes(ni) - 1) * 3;
            dof_idx((ni-1)*3+1 : ni*3) = base + (1:3);
        end
        
        if max(dof_idx) > N_dof
            g_fem(vi) = NaN; continue;
        end
        
        % 提取局部向量
        E_local = E_dof(dof_idx);
        lam_local = lambda_dof(dof_idx);
        
        % 提取局部质量矩阵块 M_local [12x12]
        M_local = M_global(dof_idx, dof_idx);
        
        % 精确梯度
        g_fem(vi) = 2 * omega2_eps0 * real(lam_local' * M_local * E_local) / F_obs;
        n_fem_success = n_fem_success + 1;
    end
    
    fprintf('[C3] 路径3 成功: %d / %d 个体素\n', n_fem_success, N_inner);
    
    else
        fprintf('[C3] M_global 为零矩阵，跳过路径3\n');
        g_fem = NaN(N_inner, 1);
    end
    
else
    fprintf('[C3] [SKIP] 路径3（无矩阵）\n');
    g_fem = NaN(N_inner, 1);
end

%% 7. 路径1: FD（采样体素）
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fprintf('\n[C3] ===== 路径1 FD (N=%d) =====\n', N_s);
fd_delta = 0.001;
g_FD = zeros(N_s,1); g_mph = zeros(N_s,1); g_fem_s = zeros(N_s,1);

for si = 1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi); eps_orig = voxel.epsilon_r(v_global);
    
    % FD
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet3(model, p);
    sf_p = extract_scattered(model, grid_meas); lc_p = lightcone_project(grid_meas, sf_p, p);
    F_plus = sum(dOmega .* sum(abs(J_obs-lc_p.J_obs_perp).^2,2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet3(model, p);
    sf_m = extract_scattered(model, grid_meas); lc_m = lightcone_project(grid_meas, sf_m, p);
    F_minus = sum(dOmega .* sum(abs(J_obs-lc_m.J_obs_perp).^2,2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig;
    
    g_FD(si) = (F_plus - F_minus) / (2*fd_delta);
    g_mph(si) = g_mphinterp(vi);
    g_fem_s(si) = g_fem(vi);
    
    if mod(si,5)==0 || si==N_s
        r_mph = g_mph(si) / max(abs(g_FD(si)),1e-30);
        r_fem = g_fem_s(si) / max(abs(g_FD(si)),1e-30);
        fprintf('  [%2d/%d] r=%.3f: g_FD=%+.2e g_mph=%+.2e(r=%.4f) g_fem=%+.2e(r=%.4f) sign_mph=%s sign_fem=%s\n', ...
            si,N_s,r_inner(vi), g_FD(si), g_mph(si),r_mph, g_fem_s(si),r_fem, ...
            ternary_s(g_FD(si)*g_mph(si)>0,'OK','XX'), ...
            ternary_s(~isnan(g_fem_s(si)) && g_FD(si)*g_fem_s(si)>0,'OK','XX'));
    end
end

%% 8. 统计
fprintf('\n############################################################\n');
fprintf('#  三路径对比统计\n');
fprintf('############################################################\n');

% 路径2 vs FD
valid2 = abs(g_FD) > 1e-30;
sign2 = sum(sign(g_FD(valid2).*g_mph(valid2))>0);
ratios2 = g_mph(valid2)./g_FD(valid2);
fprintf('路径2 (mphinterp) vs FD:\n');
fprintf('  sign OK: %d/%d, ratio mean=%.6f, CV=%.4f\n', sign2, sum(valid2), mean(ratios2), std(ratios2)/abs(mean(ratios2)));

% 路径3 vs FD
valid3 = abs(g_FD) > 1e-30 & ~isnan(g_fem_s);
if sum(valid3) > 0
    sign3 = sum(sign(g_FD(valid3).*g_fem_s(valid3))>0);
    ratios3 = g_fem_s(valid3)./g_FD(valid3);
    fprintf('路径3 (FEM精确) vs FD:\n');
    fprintf('  sign OK: %d/%d, ratio mean=%.6f, CV=%.4f\n', sign3, sum(valid3), mean(ratios3), std(ratios3)/abs(mean(ratios3)));
    
    if abs(mean(ratios3) - 1) < 0.1
        fprintf('\n  ★★★ 路径3 ratio ≈ 1！偏差来自 mphinterp + Qv 对角近似 ★★★\n');
    else
        fprintf('\n  路径3 ratio 仍偏离 1，说明还有更深层问题\n');
    end
else
    fprintf('路径3: 无有效数据\n');
end
fprintf('############################################################\n');

%% 9. 保存
result = struct();
result.g_FD = g_FD; result.g_mph = g_mph; result.g_fem = g_fem_s;
result.sample_idx = sample_idx;
result.r_inner = r_inner(sample_idx);
result.N_dof = N_dof;
result.have_matrices = have_matrices;
result.have_ud_adj = have_ud_adj;

save(fullfile(p.dir_result, 'compare_3path.mat'), 'result');
fprintf('\n[C3] 结果已保存\n');

end

function solve_quiet3(model, p)
    try model.param.set('freq',num2str(p.freq)); try model.study('std1').feature('freq').set('plist',sprintf('%g[Hz]',p.freq)); catch; end; catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    try model.physics('emw').prop('BackgroundField').set('Eb',[0 0 1]); catch; end
    try model.param.set('adjoint_mode','1'); catch; end
    try model.physics('emw').feature('vec1').set('Je',{'0','0','0'}); catch; end
    try; s1=model.sol('sol1').feature('s1'); try s1.feature('dDirect'); catch; s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso'); end; try s1.feature('fc1').set('linsolver','dDirect'); catch; end; catch; end
    model.sol('sol1').runAll();
end

function s = ternary_s(cond, a, b), if cond, s=a; else, s=b; end; end
