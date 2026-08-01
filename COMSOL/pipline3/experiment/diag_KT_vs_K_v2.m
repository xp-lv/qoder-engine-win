function diag_KT_vs_K_v2(which_voxel)
%DIAG_KT_VS_K_V2 K^T 伴随求解，用 mphxmeshinfo 做 DOF 映射
%   正确的 DOF→坐标映射，绕过 COMSOL mphinterp 限制

if nargin < 1, which_voxel = 3; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  K vs K^T 对比 (mphxmeshinfo DOF 映射)\n');
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

%% 2. 获取 xmesh DOF 信息（关键！）
fprintf('获取 DOF 映射 (mphxmeshinfo)...\n');
xinfo = mphxmeshinfo(model);
fprintf('  ndofs = %d\n', xinfo.ndofs);
fprintf('  fieldnames = %s\n', strjoin(xinfo.fieldnames, ', '));
fprintf('  fieldndofs = %s\n', mat2str(xinfo.fieldndofs));

% DOF 坐标和索引
dof_coords = xinfo.dofs.coords;       % [3 x N_dofs]
dof_names_raw = xinfo.dofs.dofnames; % cell array of unique DOF names
dof_nameinds = xinfo.dofs.nameinds;  % 0-based index into dof_names
dof_solinds = xinfo.dofs.solvectorinds; % 0-based index into solution vector

N_dofs = size(dof_coords, 2);
fprintf('  dof_coords: %dx%d\n', size(dof_coords,1), size(dof_coords,2));
fprintf('  dof_solinds: %d elements, range [%d, %d]\n', ...
    length(dof_solinds), min(dof_solinds), max(dof_solinds));

% 获取每个 DOF 的名称
dof_name_list = cell(N_dofs, 1);
for d = 1:N_dofs
    dof_name_list{d} = dof_names_raw{dof_nameinds(d) + 1};  % 0-based → 1-based
end
% 统计 DOF 名称
[uniq_names, ~, name_grp] = unique(dof_name_list);
fprintf('  DOF 名称: ');
for i = 1:length(uniq_names)
    fprintf('%s(%d) ', uniq_names{i}, sum(name_grp==i));
end
fprintf('\n');

%% 3. J_obs + 正演（复数 eps_r）
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[E_true, ~, ~] = solve_forward(model, voxel, p);
% J_obs 用 Born FT（与 J_hyp 同路径，消除路径不一致偏差）
[k_dir_obs, dOmega] = fibonacci_sphere(p.N_k);
k_vec_obs = p.k0 * k_dir_obs;
lc_obs.k_dir = k_dir_obs; lc_obs.k_vec = k_vec_obs; lc_obs.dOmega = dOmega; lc_obs.J_obs_perp = [];
[~, lc_obs] = born_forward_project(voxel, E_true, p, lc_obs);
J_obs = lc_obs.J_hyp_perp;
lc_obs.J_obs_perp = J_obs;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end

for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;

%% 4. 定位目标体素
r_inner_all = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner_all);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
vi_target = sample_idx(which_voxel);
v_global = inner_idx(vi_target);
eps_orig = voxel.epsilon_r(v_global);
fprintf('目标体素: vi=%d, r=%.4f\n', vi_target, r_inner_all(vi_target));

%% 5. 伴随源 + mphmatrix
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);

phys.prop('BackgroundField').set('Eb', [0 0 0]);
model.param.set('adjoint_mode', '0');
func_names = {'int_adj_x_re','int_adj_x_im','int_adj_y_re','int_adj_y_im','int_adj_z_re','int_adj_z_im'};
for d = 1:3
    for part = 1:2
        idx_fn = (d-1)*2 + part; fn = func_names{idx_fn};
        try model.component('comp1').func(fn); catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        if part == 1, vals = real(f_adj(:, d)); else, vals = imag(f_adj(:, d)); end
        tmp = [tempname, '.csv']; dlmwrite(tmp, [source_pos_vol, vals(:)]);
        model.component('comp1').func(fn).importData(tmp); delete(tmp);
    end
end
try phys.feature('vec1').set('Je', {'(int_adj_x_re(x,y,z)+i*int_adj_x_im(x,y,z))', ...
    '(int_adj_y_re(x,y,z)+i*int_adj_y_im(x,y,z))', '(int_adj_z_re(x,y,z)+i*int_adj_z_im(x,y,z))'}); catch; end

fprintf('\n提取 Kc, Lc...\n');
MA = mphmatrix(model, 'sol1', 'out', {'Kc','Lc','Null','ud','uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

% K\Lc 和 K'\Lc
Uc_K  = MA.Kc  \ MA.Lc;
Uc_KT = MA.Kc' \ MA.Lc;
U_K  = (MA.Null * Uc_K  + MA.ud) .* MA.uscale;
U_KT = (MA.Null * Uc_KT + MA.ud) .* MA.uscale;
fprintf('解差异: %.2f%%\n', norm(U_K-U_KT)/norm(U_K)*100);

%% 6. 用 mphxmeshinfo 的 solvectorinds 从 U 提取每个 DOF 的值
% U_full 的索引是 1-based，solvectorinds 是 0-based
dof_vals_K  = U_K(dof_solinds + 1);    % [N_dofs x 1]
dof_vals_KT = U_KT(dof_solinds + 1);   % [N_dofs x 1]

% 按 DOF 名称分组（Ex, Ey, Ez）
Ex_mask = strcmp(dof_name_list, uniq_names{1});  % 假设第1个是 Ex
Ey_mask = strcmp(dof_name_list, uniq_names{2});  % Ey
Ez_mask = strcmp(dof_name_list, uniq_names{3});  % Ez

% 确认名称
fprintf('DOF 分组: %s=%d, %s=%d, %s=%d\n', ...
    uniq_names{1}, sum(Ex_mask), uniq_names{2}, sum(Ey_mask), uniq_names{3}, sum(Ez_mask));

% 各分量的坐标和值
Ex_coords = dof_coords(:, Ex_mask)';  % [N_ex x 3]
Ey_coords = dof_coords(:, Ey_mask)';
Ez_coords = dof_coords(:, Ez_mask)';

%% 7. 用 dsearchn 将 DOF 值映射到体素中心
inner_pos = voxel.pos(inner, :);  % [N_inner x 3]

% 对每个分量做最近邻映射
idx_Ex = dsearchn(Ex_coords, inner_pos);
idx_Ey = dsearchn(Ey_coords, inner_pos);
idx_Ez = dsearchn(Ez_coords, inner_pos);

val_Ex_K  = dof_vals_K(Ex_mask);  val_Ey_K  = dof_vals_K(Ey_mask);  val_Ez_K  = dof_vals_K(Ez_mask);
val_Ex_KT = dof_vals_KT(Ex_mask); val_Ey_KT = dof_vals_KT(Ey_mask); val_Ez_KT = dof_vals_KT(Ez_mask);

lambda_K_vox  = [val_Ex_K(idx_Ex),  val_Ey_K(idx_Ey),  val_Ez_K(idx_Ez)];
lambda_KT_vox = [val_Ex_KT(idx_Ex), val_Ey_KT(idx_Ey), val_Ez_KT(idx_Ez)];

fprintf('\nlambda 映射完成:\n');
fprintf('  |lambda_K|  mean=%.4e\n', mean(vecnorm(lambda_K_vox,2,2)));
fprintf('  |lambda_KT| mean=%.4e\n', mean(vecnorm(lambda_KT_vox,2,2)));

%% 8. 对比梯度 sign
k0_sq = p.k0^2; omega_eps0 = p.omega(1)*p.eps0;
E_v = E_total(vi_target, :); S_v = S_field(vi_target, :); dV_v = voxel.dV(v_global);

% FD
fd_delta = 0.01;
voxel.epsilon_r(v_global) = real(eps_orig)+1i*(imag(eps_orig)+fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Ep,~,~] = solve_forward(model, voxel, p);
[~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
Fp = sum(dOmega .* sum(abs(J_obs-lcp.J_hyp_perp).^2,2)) / F_obs;
voxel.epsilon_r(v_global) = real(eps_orig)+1i*(imag(eps_orig)-fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Em,~,~] = solve_forward(model, voxel, p);
[~,lcm_f] = born_forward_project(voxel, Em, p, lc_obs);
Fm = sum(dOmega .* sum(abs(J_obs-lcm_f.J_hyp_perp).^2,2)) / F_obs;
voxel.epsilon_r(v_global) = eps_orig;
g_FD_im = (Fp-Fm)/(2*fd_delta);

ES = sum(conj(E_v).*S_v);
gd_im = -2*dV_v*omega_eps0*real(ES)/F_obs;

% K 解
L_K = lambda_K_vox(vi_target,:); L_K_c = conj(L_K);
EL_K = sum(conj(E_v).*L_K_c);
gi_im_K = -k0_sq*dV_v*imag(EL_K);

% K^T 解
L_KT = lambda_KT_vox(vi_target,:); L_KT_c = conj(L_KT);
EL_KT = sum(conj(E_v).*L_KT_c);
gi_im_KT = -k0_sq*dV_v*imag(EL_KT);

g_im_K = gd_im + gi_im_K;
g_im_KT = gd_im + gi_im_KT;

fprintf('\n############################################################\n');
fprintf('#  第%d体素 (r=%.4f) 虚部梯度: K\\b vs K''\\b\n', which_voxel, r_inner_all(vi_target));
fprintf('############################################################\n');
fprintf('  FD:        g_FD_im = %+.6e\n\n', g_FD_im);
fprintf('  K\\b:      gd=%+.4e gi=%+.4e 合计=%+.4e ratio=%+.2f %s\n', ...
    gd_im, gi_im_K, g_im_K, g_im_K/g_FD_im, ts(g_im_K*g_FD_im>0));
fprintf('  K''\\b:     gd=%+.4e gi=%+.4e 合计=%+.4e ratio=%+.2f %s\n', ...
    gd_im, gi_im_KT, g_im_KT, g_im_KT/g_FD_im, ts(g_im_KT*g_FD_im>0));
fprintf('\n  lambda_Ez 对比:\n');
fprintf('    K:  %.4e %+.4ei\n', real(L_K(3)), imag(L_K(3)));
fprintf('    K''\\b: %.4e %+.4ei\n', real(L_KT(3)), imag(L_KT(3)));
fprintf('############################################################\n');

%% 恢复
model.param.set('adjoint_mode','1');
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try phys.feature('vec1').set('Je',{'0','0','0'}); catch; end

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

function s = ts(cond), if cond, s='OK'; else, s='XX'; end, end
