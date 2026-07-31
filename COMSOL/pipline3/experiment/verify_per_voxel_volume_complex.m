function result = verify_per_voxel_volume_complex(N_sample)
%VERIFY_PER_VOXEL_VOLUME_COMPLEX 复数 eps_r 体积等效源路径验证
%
%   真值: eps_r = 5.0 - 3.0j
%   初值: eps_r = 3.0 - 1.0j（非均匀梯度）
%   FD:  只扰动实部

if nargin < 1, N_sample = 30; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  复数 eps_r 体积等效源路径验证\n');
fprintf('#  真值: eps_r = 5.0 - 3.0j\n');
fprintf('#  初值: eps_r = 3.0 - 1.0j (非均匀梯度)\n');
fprintf('#  N_sample = %d\n', N_sample);
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[PVC] [FAIL]\n'); return; end
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
fprintf('[PVC] N_inner=%d\n', N_inner);

%% 2. J_obs（真值 eps_r = 5-3j，Stratton-Chu 表面等效定理）
% 原理 §8.2: J_obs 从 COMSOL 表面场用 Stratton-Chu 计算
fprintf('[PVC] 预计算 J_obs (eps_r=5-3j, Stratton-Chu)...\n');
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
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end
fprintf('[PVC] F_obs=%.4e\n', F_obs);

%% 3. 正演 eps_r=3-1j（非均匀梯度）
fprintf('[PVC] 正演 (eps_r=3-1j 非均匀梯度)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[PVC] F_data=%.6e\n', F_data);

%% 4. 伴随源构建
fprintf('[PVC] 构建体积伴随源...\n');
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);

%% 5. 伴随求解
fprintf('[PVC] 伴随求解...\n');
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[PVC] [FAIL] adjoint\n'); return; end
fprintf('[PVC] |lambda| mean=%.4e\n', mean(vecnorm(lambda,2,2)));

%% 6. 梯度计算（复数 ε_r，原理 §7.5.3 四分量）
% 复数 ε_r 下间接项需 conj(λ) 做 bilinear 配对（原理 §7.5.5 路径B）
%   g_re = gd_re + gi_re = +2ωε₀dV·Im[conj(E)·S]/F_obs - k₀²dV·Re[E·λ]
%   g_im = gd_im + gi_im = -2ωε₀dV·Re[conj(E)·S]/F_obs + k₀²dV·Im[E·λ]
% 其中 conj(λ) 使 dot(E,conj(λ)) = conj(E·λ)，实部 = Re[E·λ]，虚部 = -Im[E·λ]
k0_sq = p.k0^2; dV_vec = voxel.dV;
omega_eps0 = p.omega(1) * p.eps0;

lambda_c = conj(lambda);           % bilinear 配对：conj(λ)
if ~isempty(lambda_gauss), lambda_gauss_c = conj(lambda_gauss); else, lambda_gauss_c = []; end

g_indirect_re = zeros(N_inner, 1); g_indirect_im = zeros(N_inner, 1);
g_direct_re   = zeros(N_inner, 1); g_direct_im   = zeros(N_inner, 1);

use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss_c) && size(E_gauss,1)==size(voxel.gauss_pos,1);
if use_gauss
    gw = voxel.gauss_w;
    for vi=1:N_inner
        gp=(4*(vi-1)+1):(4*vi);
        gs_re=0; gs_im=0;
        for gpi=1:4
            EL = sum(conj(E_gauss(gp(gpi),:)).*lambda_gauss_c(gp(gpi),:));  % conj(E)·conj(λ) = conj(E·λ)
            gs_re=gs_re+gw(gpi)*real(EL);
            gs_im=gs_im+gw(gpi)*imag(EL);
        end
        g_indirect_re(vi) = -k0_sq*dV_vec(inner_idx(vi))*gs_re;             % -k₀²Re[E·λ]
        g_indirect_im(vi) = -k0_sq*dV_vec(inner_idx(vi))*gs_im;             % = +k₀²Im[E·λ]
    end
else
    for vi=1:N_inner
        EL = sum(conj(E_total(vi,:)).*lambda_c(vi,:));                       % conj(E)·conj(λ) = conj(E·λ)
        g_indirect_re(vi) = -k0_sq*dV_vec(inner_idx(vi))*real(EL);           % -k₀²Re[E·λ]
        g_indirect_im(vi) = -k0_sq*dV_vec(inner_idx(vi))*imag(EL);           % = +k₀²Im[E·λ]
    end
end

% 直接项（原理 §7.5.3: 直接项始终 Hermitian conj(E)·S）
for vi=1:N_inner
    ES = sum(conj(E_total(vi,:)).*S_field(vi,:));
    g_direct_re(vi) = +2 * dV_vec(inner_idx(vi)) * omega_eps0 * imag(ES) / F_obs;
    g_direct_im(vi) = -2 * dV_vec(inner_idx(vi)) * omega_eps0 * real(ES) / F_obs;
end

g_adj_re = g_direct_re + g_indirect_re;
g_adj_im = g_direct_im + g_indirect_im;
g_adj_all = g_adj_re + 1j * g_adj_im;  % 复数打包
fprintf('[PVC] ||g_re||=%.4e, ||g_im||=%.4e\n', norm(g_adj_re), norm(g_adj_im));
fprintf('[PVC]   re: ||gd||=%.4e ||gi||=%.4e | im: ||gd||=%.4e ||gi||=%.4e\n', ...
    norm(g_direct_re), norm(g_indirect_re), norm(g_direct_im), norm(g_indirect_im));

%% 7. 逐体素 FD（实部 + 虚部双分量）
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fprintf('\n[PVC] ===== 逐体素 FD (N=%d, 实部+虚部双分量) =====\n', N_s);
fd_delta = 0.001;
g_FD_re = zeros(N_s,1); g_FD_im = zeros(N_s,1);
g_adj_re_s = zeros(N_s,1); g_adj_im_s = zeros(N_s,1);

for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi); eps_orig = voxel.epsilon_r(v_global);

    % --- FD 实部（扰动 ε_re）---
    voxel.epsilon_r(v_global) = (real(eps_orig) + fd_delta) + 1i*imag(eps_orig);
    update_epsilon(model, voxel, p); solve_quiet_pvc(model, p);
    [E_p,~,~] = solve_forward(model, voxel, p);
    [~,lc_fwd_p] = born_forward_project(voxel, E_p, p, lc_obs);
    F_plus_re = sum(dOmega .* sum(abs(J_obs - lc_fwd_p.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = (real(eps_orig) - fd_delta) + 1i*imag(eps_orig);
    update_epsilon(model, voxel, p); solve_quiet_pvc(model, p);
    [E_m,~,~] = solve_forward(model, voxel, p);
    [~,lc_fwd_m] = born_forward_project(voxel, E_m, p, lc_obs);
    F_minus_re = sum(dOmega .* sum(abs(J_obs - lc_fwd_m.J_hyp_perp).^2,2)) / F_obs;

    % --- FD 虚部（扰动 ε_im）---
    voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig) + fd_delta);
    update_epsilon(model, voxel, p); solve_quiet_pvc(model, p);
    [E_p,~,~] = solve_forward(model, voxel, p);
    [~,lc_fwd_p] = born_forward_project(voxel, E_p, p, lc_obs);
    F_plus_im = sum(dOmega .* sum(abs(J_obs - lc_fwd_p.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig) - fd_delta);
    update_epsilon(model, voxel, p); solve_quiet_pvc(model, p);
    [E_m,~,~] = solve_forward(model, voxel, p);
    [~,lc_fwd_m] = born_forward_project(voxel, E_m, p, lc_obs);
    F_minus_im = sum(dOmega .* sum(abs(J_obs - lc_fwd_m.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = eps_orig;
    g_FD_re(si) = (F_plus_re - F_minus_re) / (2*fd_delta);
    g_FD_im(si) = (F_plus_im - F_minus_im) / (2*fd_delta);
    g_adj_re_s(si) = g_adj_re(vi);
    g_adj_im_s(si) = g_adj_im(vi);

    if mod(si,5)==0 || si==N_s
        r_re = g_adj_re_s(si)/max(abs(g_FD_re(si)),1e-30);
        r_im = g_adj_im_s(si)/max(abs(g_FD_im(si)),1e-30);
        s_re = ternary_s(g_FD_re(si)*g_adj_re_s(si)>0,'OK','XX');
        s_im = ternary_s(g_FD_im(si)*g_adj_im_s(si)>0,'OK','XX');
        fprintf('  [%2d/%d] r=%.3f:\n    re: FD=%+.2e adj=%+.2e ratio=%.4f %s\n    im: FD=%+.2e adj=%+.2e ratio=%.4f %s\n', ...
            si,N_s,r_inner(vi), g_FD_re(si),g_adj_re_s(si),r_re,s_re, g_FD_im(si),g_adj_im_s(si),r_im,s_im);
    end
end

%% 8. 统计（实部 + 虚部分别统计）
sign_re = sign(g_FD_re .* g_adj_re_s) > 0;
sign_im = sign(g_FD_im .* g_adj_im_s) > 0;
sign_rate_re = sum(sign_re)/N_s; sign_rate_im = sum(sign_im)/N_s;
cos_re = dot(g_FD_re,g_adj_re_s)/(norm(g_FD_re)*norm(g_adj_re_s));
cos_im = dot(g_FD_im,g_adj_im_s)/(norm(g_FD_im)*norm(g_adj_im_s));
ratios_re = g_adj_re_s./g_FD_re; ratios_im = g_adj_im_s./g_FD_im;
v_re = abs(g_FD_re)>1e-30; v_im = abs(g_FD_im)>1e-30;

fprintf('\n############################################################\n');
fprintf('#  复数 eps_r (5-3j→3-1j) 体积路径验证结果\n');
fprintf('############################################################\n');
fprintf('#  [实部 ε_re] sign: %d/%d=%.1f%%  cosθ=%.4f\n', sum(sign_re),N_s,100*sign_rate_re,cos_re);
if sum(v_re)>0, fprintf('#    ratio mean=%.6f CV=%.4f\n', mean(ratios_re(v_re)), std(ratios_re(v_re))/abs(mean(ratios_re(v_re)))); end
fprintf('#  [虚部 ε_im] sign: %d/%d=%.1f%%  cosθ=%.4f\n', sum(sign_im),N_s,100*sign_rate_im,cos_im);
if sum(v_im)>0, fprintf('#    ratio mean=%.6f CV=%.4f\n', mean(ratios_im(v_im)), std(ratios_im(v_im))/abs(mean(ratios_im(v_im)))); end
if sign_rate_re>0.9 && sign_rate_im>0.9 && cos_re>0.8 && cos_im>0.8
    fprintf('#  ★★★ PASS ★★★\n');
else
    fprintf('#  ⚠ FAIL 或部分通过\n');
end
fprintf('############################################################\n');

result = struct('g_FD_re',g_FD_re,'g_FD_im',g_FD_im,'g_adj_re',g_adj_re_s,'g_adj_im',g_adj_im_s, ...
    'sign_rate_re',sign_rate_re,'sign_rate_im',sign_rate_im,'cos_re',cos_re,'cos_im',cos_im);
save(fullfile(p.dir_result,'per_voxel_volume_complex_result.mat'),'result');
fprintf('\n[PVC] 结果已保存\n');

end

function solve_quiet_pvc(model, p)
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
