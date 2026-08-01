function diag_ratio_optimize(which_voxel)
%DIAG_RATIO_OPTIMIZE 用 mphinterp 精确 lambda + Born FT 统一 J_obs 优化 ratio

if nargin < 1, which_voxel = 3; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  ratio 优化: mphinterp lambda + Born FT J_obs\n');
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

%% 2. J_obs (Born FT 统一路径)
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
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
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
fprintf('目标: vi=%d, r=%.4f, eps_r=%.4f%+.4fi\n', vi_target, r_inner_all(vi_target), real(eps_orig), imag(eps_orig));

%% 5. 伴随源 + runAll 求解（mphinterp 精确提取 lambda）
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[DIAG] [FAIL] adjoint\n'); return; end

%% 6. 梯度计算（实部 + 虚部，质心 + Gauss 两种取值）
k0_sq = p.k0^2; omega_eps0 = p.omega(1)*p.eps0;
dV_v = voxel.dV(v_global);

E_v = E_total(vi_target, :);
S_v = S_field(vi_target, :);
L_v = lambda(vi_target, :);
L_c = conj(L_v);  % bilinear 配对

% --- 质心取值 ---
ES = sum(conj(E_v) .* S_v);
EL = sum(conj(E_v) .* L_c);

gd_re = +2*dV_v*omega_eps0*imag(ES)/F_obs;
gd_im = -2*dV_v*omega_eps0*real(ES)/F_obs;
gi_re = -k0_sq*dV_v*real(EL);
gi_im = -k0_sq*dV_v*imag(EL);
g_re_centroid = gd_re + gi_re;
g_im_centroid = gd_im + gi_im;

% --- Gauss 取值（如果可用）---
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) && size(E_gauss,1)==size(voxel.gauss_pos,1);
g_re_gauss = 0; g_im_gauss = 0;
if use_gauss
    gw = voxel.gauss_w;
    inner_idx_list = find(inner);
    vi_in_inner = find(inner_idx_list == inner_idx(vi_target), 1);
    gp_range = (4*(vi_in_inner-1)+1):(4*vi_in_inner);
    gs_re_EL = 0; gs_im_EL = 0;
    for gpi = 1:4
        Eg = E_gauss(gp_range(gpi), :);
        Lg = conj(lambda_gauss(gp_range(gpi), :));  % bilinear conj(λ)
        EL_g = sum(conj(Eg) .* Lg);
        gs_re_EL = gs_re_EL + gw(gpi) * real(EL_g);
        gs_im_EL = gs_im_EL + gw(gpi) * imag(EL_g);
    end
    gi_re_g = -k0_sq*dV_v*gs_re_EL;
    gi_im_g = -k0_sq*dV_v*gs_im_EL;
    g_re_gauss = gd_re + gi_re_g;  % 直接项不变（S 场无 Gauss 点版本）
    g_im_gauss = gd_im + gi_im_g;
end

%% 7. FD（实部 + 虚部）
fd_delta = 0.01;
% FD 实部
voxel.epsilon_r(v_global) = (real(eps_orig)+fd_delta) + 1i*imag(eps_orig);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Ep,~,~] = solve_forward(model, voxel, p);
[~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
Fp_re = sum(dOmega .* sum(abs(J_obs - lcp.J_hyp_perp).^2,2)) / F_obs;
voxel.epsilon_r(v_global) = (real(eps_orig)-fd_delta) + 1i*imag(eps_orig);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Em,~,~] = solve_forward(model, voxel, p);
[~,lcm_f] = born_forward_project(voxel, Em, p, lc_obs);
Fm_re = sum(dOmega .* sum(abs(J_obs - lcm_f.J_hyp_perp).^2,2)) / F_obs;
g_FD_re = (Fp_re - Fm_re)/(2*fd_delta);

% FD 虚部
voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)+fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Ep,~,~] = solve_forward(model, voxel, p);
[~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
Fp_im = sum(dOmega .* sum(abs(J_obs - lcp.J_hyp_perp).^2,2)) / F_obs;
voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)-fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Em,~,~] = solve_forward(model, voxel, p);
[~,lcm_f] = born_forward_project(voxel, Em, p, lc_obs);
Fm_im = sum(dOmega .* sum(abs(J_obs - lcm_f.J_hyp_perp).^2,2)) / F_obs;
g_FD_im = (Fp_im - Fm_im)/(2*fd_delta);
voxel.epsilon_r(v_global) = eps_orig;

%% 8. 结果输出
fprintf('\n############################################################\n');
fprintf('#  第%d体素 (r=%.4f) 实部+虚部梯度对比\n', which_voxel, r_inner_all(vi_target));
fprintf('#  J_obs=Born FT, lambda=mphinterp(runAll)\n');
fprintf('############################################################\n\n');

fprintf('--- 实部 ε_re ---\n');
fprintf('  FD:         g_FD_re = %+.6e\n', g_FD_re);
fprintf('  质心:       gd=%+.4e gi=%+.4e 合计=%+.4e ratio=%+.4f %s\n', ...
    gd_re, gi_re, g_re_centroid, g_re_centroid/g_FD_re, ts(g_re_centroid*g_FD_re>0));
if use_gauss
    fprintf('  Gauss间接项: gi=%+.4e 合计=%+.4e ratio=%+.4f %s\n', ...
        gi_re_g, g_re_gauss, g_re_gauss/g_FD_re, ts(g_re_gauss*g_FD_re>0));
end

fprintf('\n--- 虚部 ε_im ---\n');
fprintf('  FD:         g_FD_im = %+.6e\n', g_FD_im);
fprintf('  质心:       gd=%+.4e gi=%+.4e 合计=%+.4e ratio=%+.4f %s\n', ...
    gd_im, gi_im, g_im_centroid, g_im_centroid/g_FD_im, ts(g_im_centroid*g_FD_im>0));
if use_gauss
    fprintf('  Gauss间接项: gi=%+.4e 合计=%+.4e ratio=%+.4f %s\n', ...
        gi_im_g, g_im_gauss, g_im_gauss/g_FD_im, ts(g_im_gauss*g_FD_im>0));
end

fprintf('\n--- 分解分析 ---\n');
fprintf('  直接项占比: re=%.1f%%  im=%.1f%%\n', ...
    abs(gd_re)/abs(g_FD_re)*100, abs(gd_im)/abs(g_FD_im)*100);
fprintf('  间接项占比: re=%.1f%%  im=%.1f%%\n', ...
    abs(gi_re)/abs(g_FD_re)*100, abs(gi_im)/abs(g_FD_im)*100);
fprintf('  间接项/直接项: re=%.2f  im=%.2f\n', ...
    abs(gi_re)/max(abs(gd_re),1e-30), abs(gi_im)/max(abs(gd_im),1e-30));
fprintf('############################################################\n');

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
