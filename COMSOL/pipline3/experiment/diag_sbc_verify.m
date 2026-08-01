function diag_sbc_verify(which_voxel)
%DIAG_SBC_VERIFY SBC 模型的复数 ε_r 逐体素验证（K 应对称，ratio 应趋于1）

if nargin < 1, which_voxel = 3; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  SBC 模型验证: K对称性 + 复数 ε_r 梯度 ratio\n');
fprintf('############################################################\n\n');

%% 1. 初始化（用 build_sbc_model 替代 mphload）
p = config();
grid_meas = build_measurement_grid(p);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[DIAG] [FAIL]\n'); return; end
end
try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

model = build_sbc_model(p);
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end
phys = model.physics('emw');
try model.param.set('adjoint_mode','1'); catch; end

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);
fprintf('N_inner=%d\n\n', N_inner);

%% 2. J_obs (Born FT 统一路径, eps_r=5-3j)
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
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
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end

%% 3. 正演 eps_r=3-1j
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;

%% 4. K 对称性检查（SBC 模型）
fprintf('=== K 对称性检查 (SBC 模型) ===\n');
MA_K = mphmatrix(model, 'sol1', ...
    'out', {'Kc'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
dK = MA_K.Kc - MA_K.Kc';
max_dK = full(max(max(abs(dK))));
fprintf('  max|K-K''| = %.4e\n', max_dK);
if max_dK < 1e-10
    fprintf('  ★ K 对称！(SBC 无 PML 复坐标变换)\n\n');
else
    fprintf('  K 仍不对称 (max=%.2e)\n\n', max_dK);
end

%% 5. 定位目标体素
r_inner_all = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner_all);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
vi_target = sample_idx(which_voxel);
v_global = inner_idx(vi_target);
eps_orig = voxel.epsilon_r(v_global);
fprintf('目标: vi=%d, r=%.4f\n\n', vi_target, r_inner_all(vi_target));

%% 6. 伴随源 + runAll 求解
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);
[lambda, ok_adj] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[DIAG] [FAIL] adjoint\n'); return; end

%% 7. 梯度（实部+虚部）+ FD
k0_sq = p.k0^2; omega_eps0 = p.omega(1)*p.eps0; dV_v = voxel.dV(v_global);
E_v = E_total(vi_target,:); S_v = S_field(vi_target,:);
L_v = lambda(vi_target,:); L_c = conj(L_v);

ES = sum(conj(E_v).*S_v); EL = sum(conj(E_v).*L_c);
gd_re = +2*dV_v*omega_eps0*imag(ES)/F_obs;
gd_im = -2*dV_v*omega_eps0*real(ES)/F_obs;
gi_re = -k0_sq*dV_v*real(EL);
gi_im = -k0_sq*dV_v*imag(EL);

fd_delta = 0.01;
% FD re
voxel.epsilon_r(v_global) = (real(eps_orig)+fd_delta)+1i*imag(eps_orig);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Ep,~,~] = solve_forward(model, voxel, p);
[~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
Fp_re = sum(dOmega .* sum(abs(J_obs-lcp.J_hyp_perp).^2,2))/F_obs;
voxel.epsilon_r(v_global) = (real(eps_orig)-fd_delta)+1i*imag(eps_orig);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Em,~,~] = solve_forward(model, voxel, p);
[~,lcm_f] = born_forward_project(voxel, Em, p, lc_obs);
Fm_re = sum(dOmega .* sum(abs(J_obs-lcm_f.J_hyp_perp).^2,2))/F_obs;
g_FD_re = (Fp_re-Fm_re)/(2*fd_delta);

% FD im
voxel.epsilon_r(v_global) = real(eps_orig)+1i*(imag(eps_orig)+fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Ep,~,~] = solve_forward(model, voxel, p);
[~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
Fp_im = sum(dOmega .* sum(abs(J_obs-lcp.J_hyp_perp).^2,2))/F_obs;
voxel.epsilon_r(v_global) = real(eps_orig)+1i*(imag(eps_orig)-fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Em,~,~] = solve_forward(model, voxel, p);
[~,lcm_f] = born_forward_project(voxel, Em, p, lc_obs);
Fm_im = sum(dOmega .* sum(abs(J_obs-lcm_f.J_hyp_perp).^2,2))/F_obs;
g_FD_im = (Fp_im-Fm_im)/(2*fd_delta);
voxel.epsilon_r(v_global) = eps_orig;

%% 8. 输出
fprintf('############################################################\n');
fprintf('#  SBC 模型 第%d体素 (r=%.4f) 实部+虚部梯度\n', which_voxel, r_inner_all(vi_target));
fprintf('############################################################\n');
fprintf('  --- 实部 ε_re ---\n');
fprintf('    FD=%+.4e  gd=%+.4e gi=%+.4e 合计=%+.4e ratio=%+.4f %s\n', ...
    g_FD_re, gd_re, gi_re, gd_re+gi_re, (gd_re+gi_re)/g_FD_re, ts((gd_re+gi_re)*g_FD_re>0));
fprintf('  --- 虚部 ε_im ---\n');
fprintf('    FD=%+.4e  gd=%+.4e gi=%+.4e 合计=%+.4e ratio=%+.4f %s\n', ...
    g_FD_im, gd_im, gi_im, gd_im+gi_im, (gd_im+gi_im)/g_FD_im, ts((gd_im+gi_im)*g_FD_im>0));
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

function s = ts(c), if c, s='OK'; else, s='XX'; end, end
