function diag_scale_factor(which_voxel)
%DIAG_SCALE_FACTOR 验证伴随源量纲一致性 + 确定正确缩放因子
%   方法: 对正演源做同样的 ExternalCurrentDensity 注入，验证 COMSOL 的 K*E = jwmu0*Je 约定

if nargin < 1, which_voxel = 3; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  量纲验证: COMSOL ExternalCurrentDensity 的物理约定\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
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

omega = p.omega(1); mu0 = p.mu0; eps0 = p.eps0; k0 = p.k0;

%% 2. 正常正演（eps_r=3-1j，带背景场）→ 提取 E
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 提取正演解的 DOF 向量
U_fwd = mphgetu(model);
N_dof = length(U_fwd);
fprintf('正演 DOF: %d, |U| range [%.4e, %.4e]\n', N_dof, min(abs(U_fwd)), max(abs(U_fwd)));

%% 3. 导出正演的 K 和 L（L 含背景场源）
MA = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');

% 验证: Kc \ Lc 应该恢复正演解
Uc_check = MA.Kc \ MA.Lc;
U_check = (MA.Null * Uc_check + MA.ud) .* MA.uscale;
fprintf('验证 K\\L 恢复正演解: 误差 = %.2e\n', norm(U_fwd - U_check) / norm(U_fwd));

%% 4. 构造单位测试源: Je = [1, 0, 0]（均匀 x 方向单位电流密度）
% 设 vec1 为 Je = [1, 0, 0]，归零背景场，runAll
fprintf('\n=== 测试 1: Je = [1,0,0]（单位体积电流） ===\n');
model.param.set('adjoint_mode', '0');
try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch; end
phys.feature('vec1').set('Je', {'1', '0', '0'});
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 提取解（这就是 K\E_test = jwmu0*Je_test 的解）
test_pos = [0.04; 0; 0];  % 散射体内部一点
Ex_test = mphinterp(model, 'emw.Ex', 'coord', test_pos);
Ey_test = mphinterp(model, 'emw.Ey', 'coord', test_pos);
Ez_test = mphinterp(model, 'emw.Ez', 'coord', test_pos);
E_test_runAll = [Ex_test(1), Ey_test(1), Ez_test(1)];
fprintf('  runAll E(0.04,0,0) = [%.4e, %.4e, %.4e]\n', real(E_test_runAll(1)), real(E_test_runAll(2)), real(E_test_runAll(3)));

% 同时导出 Lc（应该含 Je=[1,0,0] 的贡献）
MA_test = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
Uc_test = MA_test.Kc \ MA_test.Lc;
U_test = (MA_test.Null * Uc_test + MA_test.ud) .* MA_test.uscale;

% 从 DOF 解提取同一点（用 mphsetu 写回然后读）
try mphsetu(model, 'sol1', U_test); catch
    try model.sol('sol1').setU(1, U_test); catch; end
end
Ex_dof = mphinterp(model, 'emw.Ex', 'coord', test_pos);
Ey_dof = mphinterp(model, 'emw.Ey', 'coord', test_pos);
Ez_dof = mphinterp(model, 'emw.Ez', 'coord', test_pos);
E_test_dof = [Ex_dof(1), Ey_dof(1), Ez_dof(1)];
fprintf('  K\\L (mphmatrix) E   = [%.4e, %.4e, %.4e]\n', real(E_test_dof(1)), real(E_test_dof(2)), real(E_test_dof(3)));
fprintf('  误差 = %.2e\n', norm(E_test_runAll - E_test_dof) / norm(E_test_runAll));

%% 5. 验证 Lc 的物理含义
% Lc 应该 = jwmu0 * Je 的离散化
% 如果 Je=[1,0,0] 均匀分布，则 Lc 的每一行 = jwmu0 * (对应的形函数积分)
fprintf('\n  Lc 分析:\n');
fprintf('    |Lc| range [%.4e, %.4e]\n', min(abs(MA_test.Lc)), max(abs(MA_test.Lc)));
fprintf('    |Lc_fwd| range [%.4e, %.4e]\n', min(abs(MA.Lc)), max(abs(MA.Lc)));
fprintf('    |Lc_test| / jwmu0 = %.4e (应≈1 if Je=[1,0,0] 均匀)\n', max(abs(MA_test.Lc)) / (omega*mu0));

%% 6. 对比正演 L_fwd vs 测试 L_test
% 正演的 L 含背景场源（平面波），测试的 L 含 Je=[1,0,0]
% 差值 = 背景场源贡献
L_diff = MA.Lc - MA_test.Lc;
fprintf('\n  正演 L_fwd vs 测试 L_test 差异:\n');
fprintf('    |L_fwd - L_test| / |L_fwd| = %.4f%%\n', norm(L_diff)/norm(MA.Lc)*100);
fprintf('    → 差异来自背景场源（平面波）\n');

%% 7. 关键验证: 伴随源的 Lc 与 f_adj 的关系
% 当注入伴随源 f_adj 到 vec1 后，COMSOL 组装的 Lc 应该 = jwmu0 * f_adj 的离散化
% 但 f_adj 只在内部体素有值，外部为 0
fprintf('\n=== 验证: 伴随源注入后 Lc 的物理含义 ===\n');

% 重新设置伴随源（用实际 f_adj）
% 先恢复背景场，做 J_obs 和正演
model.param.set('adjoint_mode', '1');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end
phys.feature('vec1').set('Je', {'0', '0', '0'});
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[E_true, ~, ~] = solve_forward(model, voxel, p);
[k_dir_obs, dOmega] = fibonacci_sphere(p.N_k);
k_vec_obs = p.k0 * k_dir_obs;
lc_obs.k_dir = k_dir_obs; lc_obs.k_vec = k_vec_obs; lc_obs.dOmega = dOmega; lc_obs.J_obs_perp = [];
[~, lc_obs] = born_forward_project(voxel, E_true, p, lc_obs);
J_obs = lc_obs.J_hyp_perp;
lc_obs.J_obs_perp = J_obs;

for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;

lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, F_obs] = build_adjoint_source_volume(voxel, lc_fwd, p);

fprintf('  f_adj: |f| mean=%.4e\n', mean(vecnorm(f_adj,2,2)));

% 注入伴随源
source_pos_vol = voxel.pos(inner_idx, :);
model.param.set('adjoint_mode', '0');
try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch; end
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
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 提取 lambda
inner_pos = voxel.pos(inner, :)';
Lx = mphinterp(model, 'emw.Ex', 'coord', inner_pos);
Ly = mphinterp(model, 'emw.Ey', 'coord', inner_pos);
Lz = mphinterp(model, 'emw.Ez', 'coord', inner_pos);
lambda = [Lx(:), Ly(:), Lz(:)];
fprintf('  lambda (runAll): |λ| mean=%.4e\n', mean(vecnorm(lambda,2,2)));

% 导出伴随的 Lc
MA_adj = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');

fprintf('\n  伴随 Lc 分析:\n');
fprintf('    |Lc_adj| range [%.4e, %.4e]\n', min(abs(MA_adj.Lc)), max(abs(MA_adj.Lc)));
fprintf('    |Lc_adj| / (ωμ₀) = %.4e (最大)\n', max(abs(MA_adj.Lc)) / (omega*mu0));
fprintf('    |f_adj| max = %.4e\n', max(vecnorm(f_adj,2,2)));

% 检查 Lc_adj 是否 ≈ jωμ₀ * f_adj 的离散化
% 如果 COMSOL 对 Je 直接组装 L = jωμ₀ * ∫(N_i · Je) dV
% 那 Lc_adj / (jωμ₀) 应该 = f_adj 的质量矩阵加权积分
fprintf('\n  → 如果 Lc ≈ jωμ₀ × f_adj 的体积积分，则伴随源量纲正确\n');
fprintf('    ratio = max|Lc_adj| / (ωμ₀ × max|f_adj|) = %.4f\n', ...
    max(abs(MA_adj.Lc)) / (omega*mu0*max(vecnorm(f_adj,2,2))));

% 8. 确定 ratio 修复因子
r_inner_all = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner_all);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
vi_target = sample_idx(which_voxel);
v_global = inner_idx(vi_target);
eps_orig = voxel.epsilon_r(v_global);

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

% 梯度
k0_sq = k0^2; omega_eps0 = omega*eps0; dV_v = voxel.dV(v_global);
E_v = E_total(vi_target,:); S_v = S_field(vi_target,:);
L_v = lambda(vi_target,:); L_c = conj(L_v);
ES = sum(conj(E_v).*S_v); EL = sum(conj(E_v).*L_c);
gd_im = -2*dV_v*omega_eps0*real(ES)/F_obs;
gi_im = -k0_sq*dV_v*imag(EL);
g_adj_im = gd_im + gi_im;

fprintf('\n############################################################\n');
fprintf('#  第%d体素 (r=%.4f) 虚部梯度\n', which_voxel, r_inner_all(vi_target));
fprintf('############################################################\n');
fprintf('  FD:       %+.6e\n', g_FD_im);
fprintf('  直接项:   %+.6e  (%.1f%% of FD)\n', gd_im, abs(gd_im)/abs(g_FD_im)*100);
fprintf('  间接项:   %+.6e  (%.1f%% of FD)\n', gi_im, abs(gi_im)/abs(g_FD_im)*100);
fprintf('  合计:     %+.6e  ratio=%.2f\n', g_adj_im, g_adj_im/g_FD_im);
fprintf('\n  量纲关键比值:\n');
fprintf('    max|Lc_adj|/(ωμ₀×max|f_adj|) = %.4f\n', ...
    max(abs(MA_adj.Lc)) / (omega*mu0*max(vecnorm(f_adj,2,2))));
fprintf('    → 若≈1 则 COMSOL 正确组装了 jωμ₀×Je\n');
fprintf('    → 若>>1 则 COMSOL 有额外的缩放\n');
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
