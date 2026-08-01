function diag_KT_vs_K_gradient(which_voxel)
%DIAG_KT_VS_K_GRADIENT 纯 MATLAB K^T 伴随求解 + FEM 形函数插值
%   对比 K\b 和 K'\b 对第 which_voxel 体素虚部梯度 sign 的影响

if nargin < 1, which_voxel = 3; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  K vs K^T 伴随梯度对比 (纯 MATLAB FEM 插值)\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[DIAG] [FAIL]\n'); return; end
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

%% 2. 获取 FEM 网格拓扑（用于纯 MATLAB 场值插值）
mesh = model.mesh('mesh1');
verts = mesh.getVertex()';          % [N_vert x 3]
tet_conn = double(mesh.getElem('tet'))' + 1;  % [N_tet x 4] 1-indexed
N_tet = size(tet_conn, 1);
fprintf('FEM 网格: %d 顶点, %d tet\n', size(verts,1), N_tet);

%% 3. J_obs (Stratton-Chu, 真值 eps_r=5-3j)
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[E_true, ~, ~] = solve_forward(model, voxel, p);
sf_true = extract_scattered(model, grid_meas);
lc_obs = lightcone_project(grid_meas, sf_true, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;

%% 4. 正演 eps_r=3-1j
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;

%% 5. 定位目标体素
r_inner_all = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner_all);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
vi_target = sample_idx(which_voxel);
v_global = inner_idx(vi_target);
eps_orig = voxel.epsilon_r(v_global);
fprintf('目标体素: vi=%d, r=%.4f, eps_r=%.4f%+.4fi\n', vi_target, r_inner_all(vi_target), real(eps_orig), imag(eps_orig));

%% 6. 设置伴随源（写入 COMSOL）
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);

% 归零背景场 + 写入伴随源
phys.prop('BackgroundField').set('Eb', [0 0 0]);
model.param.set('adjoint_mode', '0');
func_names = {'int_adj_x_re','int_adj_x_im','int_adj_y_re','int_adj_y_im','int_adj_z_re','int_adj_z_im'};
for d = 1:3
    for part = 1:2
        idx_fn = (d-1)*2 + part;
        fn = func_names{idx_fn};
        try model.component('comp1').func(fn); catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        if part == 1, vals = real(f_adj(:, d)); else, vals = imag(f_adj(:, d)); end
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [source_pos_vol, vals(:)]);
        model.component('comp1').func(fn).importData(tmp);
        delete(tmp);
    end
end
Je_x = '(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))';
Je_y = '(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))';
Je_z = '(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))';
try phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z}); catch; end

%% 7. mphmatrix 提取 Kc, Lc
fprintf('\n提取系统矩阵...\n');
MA = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
fprintf('Kc: %dx%d\n', size(MA.Kc,1), size(MA.Kc,2));

%% 8. 求解 K\Lc 和 K'\Lc
Uc_K  = MA.Kc  \ MA.Lc;
Uc_KT = MA.Kc' \ MA.Lc;

U_K  = (MA.Null * Uc_K  + MA.ud) .* MA.uscale;   % 36778 x 1
U_KT = (MA.Null * Uc_KT + MA.ud) .* MA.uscale;

fprintf('解差异 |U_K - U_KT|/|U_K| = %.2f%%\n', norm(U_K - U_KT)/norm(U_K)*100);

%% 9. 纯 MATLAB FEM 插值：DOF → 体素中心
% 用 mphxmeshinfo 获取正确的 DOF 排列
fprintf('\n获取 DOF 映射...\n');
xmesh_info = mphxmeshinfo(model);
fprintf('  xmesh 字段: %s\n', strjoin(fieldnames(xmesh_info), ', '));

% 获取节点坐标和 DOF 索引
if isfield(xmesh_info, 'nodes')
    fem_nodes = xmesh_info.nodes;  % [3 x N_nodes]
    fprintf('  fem_nodes: %dx%d\n', size(fem_nodes,1), size(fem_nodes,2));
end
if isfield(xmesh_info, 'dofs')
    fem_dofs = xmesh_info.dofs;
    fprintf('  fem_dofs: %dx%d\n', size(fem_dofs,1), size(fem_dofs,2));
end

% 尝试获取 EMW 的 DOF 映射
try
    % EMW 有 3 个分量场: Ex, Ey, Ez
    % mphxmeshinfo 返回的 dofs 结构包含每个节点的 DOF 索引
    field_dofs = xmesh_info.fieldDofs;  % 各物理场的 DOF
    fprintf('  fieldDofs: %s, size=%dx%d\n', class(field_dofs), size(field_dofs,1), size(field_dofs,2));
    
    % EMW 场名
    emw_dofs = field_dofs('emw');  % 可能是 cell 或 struct
    fprintf('  emw_dofs class: %s\n', class(emw_dofs));
catch ME
    fprintf('  fieldDofs 不可用: %s\n', ME.message);
    % 尝试其他方式获取 DOF 排列
    fprintf('  尝试用 mphgetu 的 sol 参数推断排列...\n');
end

%% 10. 构建体素中心 → tet 节点映射 + 形函数插值
fprintf('\n构建体素中心场值映射...\n');

inner_pos = voxel.pos(inner, :);  % [N_inner x 3]
lambda_K_vox = zeros(N_inner, 3);
lambda_KT_vox = zeros(N_inner, 3);
n_found = 0;

% 预计算 tet 质心
tet_centers = zeros(N_tet, 3);
for ti = 1:N_tet
    tet_centers(ti, :) = mean(verts(tet_conn(ti, :), :), 1);
end

for vi = 1:N_inner
    % 找最近的 tet 质心
    [~, closest_tet] = dsearchn(tet_centers, inner_pos(vi, :));
    if isempty(closest_tet) || closest_tet < 1, continue; end
    
    % 该 tet 的 4 个节点
    nodes = tet_conn(closest_tet, :);
    node_coords = verts(nodes, :);  % [4 x 3]
    
    % 计算体素质心在 tet 中的重心坐标
    T = node_coords(2:4,:) - node_coords(1,:);  % [3x3]
    p = inner_pos(vi,:)' - node_coords(1,:)';     % [3x1]
    bary = T \ p;  % [3x1] = (λ2, λ3, λ4)
    bary = [1 - sum(bary); bary];  % [4x1] = (λ1, λ2, λ3, λ4)
    
    if all(bary > -0.01)
        n_found = n_found + 1;
        % 提取 4 个节点的 DOF 值
        for ni = 1:4
            node_id = nodes(ni);
            % 尝试两种排列：分组 vs 交替
            % 排列 A (交替): [Ex1,Ey1,Ez1, Ex2,Ey2,Ez2, ...]
            dof_base_A = (node_id - 1) * 3;
            if dof_base_A + 3 <= length(U_K)
                val_K_A = [U_K(dof_base_A+1), U_K(dof_base_A+2), U_K(dof_base_A+3)];
                val_KT_A = [U_KT(dof_base_A+1), U_KT(dof_base_A+2), U_KT(dof_base_A+3)];
            else
                val_K_A = [0; 0; 0]';
                val_KT_A = [0; 0; 0]';
            end
            lambda_K_vox(vi, :) = lambda_K_vox(vi, :) + bary(ni) * val_K_A;
            lambda_KT_vox(vi, :) = lambda_KT_vox(vi, :) + bary(ni) * val_KT_A;
        end
    end
end
fprintf('  找到包含 tet: %d/%d (%.1f%%)\n', n_found, N_inner, n_found/N_inner*100);

% 如果 DOF 排列不正确，结果会是 0——需要进一步修正
if max(abs(lambda_K_vox(:))) < 1e-15
    fprintf('  ⚠ DOF 排列 A (交替) 失效，尝试排列 B (分组)...\n');
    % 排列 B (分组): [Ex1,Ex2,...,ExN, Ey1,...,EyN, Ez1,...,EzN]
    N_total = length(U_K) / 3;
    lambda_K_vox = zeros(N_inner, 3);
    lambda_KT_vox = zeros(N_inner, 3);
    n_found = 0;
    for vi = 1:N_inner
        [~, closest_tet] = dsearchn(tet_centers, inner_pos(vi, :));
        if isempty(closest_tet) || closest_tet < 1, continue; end
        nodes = tet_conn(closest_tet, :);
        node_coords = verts(nodes, :);
        T = node_coords(2:4,:) - node_coords(1,:);
        p = inner_pos(vi,:)' - node_coords(1,:)';
        bary = [1 - sum(T\p); T\p];
        if all(bary > -0.01)
            n_found = n_found + 1;
            for ni = 1:4
                node_id = nodes(ni);
                % 分组排列
                val_K_B = [U_K(node_id), U_K(N_total + node_id), U_K(2*N_total + node_id)];
                val_KT_B = [U_KT(node_id), U_KT(N_total + node_id), U_KT(2*N_total + node_id)];
                lambda_K_vox(vi, :) = lambda_K_vox(vi, :) + bary(ni) * val_K_B;
                lambda_KT_vox(vi, :) = lambda_KT_vox(vi, :) + bary(ni) * val_KT_B;
            end
        end
    end
    fprintf('  排列 B: 找到 %d/%d, |lambda_K| max=%.4e\n', n_found, N_inner, max(abs(lambda_K_vox(:))));
end

%% 11. 对比 K vs K^T 的梯度 sign
k0_sq = p.k0^2; omega_eps0 = p.omega(1)*p.eps0;
E_v = E_total(vi_target, :);
S_v = S_field(vi_target, :);
dV_v = voxel.dV(v_global);
F_obs_val = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs_val<p.F_obs_min, F_obs_val=1.0; end

% FD 虚部
fd_delta = 0.01;
voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)+fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Ep,~,~] = solve_forward(model, voxel, p);
[~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
Fp = sum(dOmega .* sum(abs(J_obs - lcp.J_hyp_perp).^2,2)) / F_obs_val;
voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)-fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Em,~,~] = solve_forward(model, voxel, p);
[~,lcm] = born_forward_project(voxel, Em, p, lc_obs);
Fm = sum(dOmega .* sum(abs(J_obs - lcm.J_hyp_perp).^2,2)) / F_obs_val;
voxel.epsilon_r(v_global) = eps_orig;
g_FD_im = (Fp - Fm) / (2*fd_delta);

% 直接项（与 lambda 无关）
ES = sum(conj(E_v) .* S_v);
gd_im = -2*dV_v*omega_eps0*real(ES)/F_obs_val;

% 间接项: 用 K 解的 lambda
L_K = lambda_K_vox(vi_target, :); L_K_c = conj(L_K);
EL_K = sum(conj(E_v) .* L_K_c);
gi_im_K = -k0_sq*dV_v*imag(EL_K);

% 间接项: 用 K^T 解的 lambda
L_KT = lambda_KT_vox(vi_target, :); L_KT_c = conj(L_KT);
EL_KT = sum(conj(E_v) .* L_KT_c);
gi_im_KT = -k0_sq*dV_v*imag(EL_KT);

g_im_K  = gd_im + gi_im_K;
g_im_KT = gd_im + gi_im_KT;

fprintf('\n############################################################\n');
fprintf('#  第%d体素 (r=%.4f) 虚部梯度: K\\b vs K''\\b\n', which_voxel, r_inner_all(vi_target));
fprintf('############################################################\n');
fprintf('  FD (真值):      g_FD_im = %+.6e\n\n', g_FD_im);
fprintf('  K\\b (当前管线): gd=%+.4e gi=%+.4e 合计=%+.4e ratio=%+.2f %s\n', ...
    gd_im, gi_im_K, g_im_K, g_im_K/g_FD_im, ternary_s(g_im_K*g_FD_im>0,'OK','XX'));
fprintf('  K''\\b (K^T修复): gd=%+.4e gi=%+.4e 合计=%+.4e ratio=%+.2f %s\n', ...
    gd_im, gi_im_KT, g_im_KT, g_im_KT/g_FD_im, ternary_s(g_im_KT*g_FD_im>0,'OK','XX'));
fprintf('\n  lambda 对比:\n');
fprintf('    |lambda_K|  = %.4e, arg(z)=%.4f rad\n', vecnorm(L_K,2), angle(L_K(3)));
fprintf('    |lambda_KT| = %.4e, arg(z)=%.4f rad\n', vecnorm(L_KT,2), angle(L_KT(3)));
fprintf('############################################################\n');

%% 恢复模型
model.param.set('adjoint_mode', '1');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end
try phys.feature('vec1').set('Je', {'0','0','0'}); catch; end

end

function solve_quiet(model, p)
    try model.param.set('freq',num2str(p.freq)); try model.study('std1').feature('freq').set('plist',sprintf('%g[Hz]',p.freq)); catch; end; catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    try model.physics('emw').prop('BackgroundField').set('Eb',[0 0 1]); catch; end
    try model.param.set('adjoint_mode','1'); catch; end
    try model.physics('emw').feature('vec1').set('Je',{'0','0','0'}); catch; end
    try; s1=model.sol('sol1').feature('s1'); try s1.feature('dDirect'); catch; s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso'); end; try s1.feature('fc1').set('linsolver','dDirect'); catch; end; catch; end
    model.sol('sol1').runAll();
end

function s = ternary_s(cond, a, b), if cond, s=a; else, s=b; end, end
