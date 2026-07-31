function result = verify_per_voxel_volume(N_sample)
%VERIFY_PER_VOXEL_VOLUME 体积等效源路径的逐体素 FD 验证
%
%   使用文档方法：
%     1. Born FT 正向算子计算 J_hyp
%     2. 残差反投影 S(r) 构建体积伴随源
%     3. COMSOL 求解伴随场 λ
%     4. 梯度 = g_direct + g_indirect

if nargin < 1, N_sample = 30; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  体积等效源路径 逐体素 FD 验证\n');
fprintf('#  N_sample = %d\n', N_sample);
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[PVV] [FAIL]\n'); return; end
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
fprintf('[PVV] N_inner=%d\n', N_inner);

%% 2. J_obs（真值 eps_r=5，用 Stratton-Chu 表面等效定理）
% 原理 §8.2: J_obs 从 COMSOL 表面场用 Stratton-Chu 计算（lightcone_project）
fprintf('[PVV] 预计算 J_obs (eps_r=5, Stratton-Chu)...\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 真值场 E_true（mphinterp 提取）
[E_true, ~, ~] = solve_forward(model, voxel, p);
% J_obs 用 Stratton-Chu（原理 §8.2：表面等效定理 → 光锥投影）
sf_true = extract_scattered(model, grid_meas);
lc_obs = lightcone_project(grid_meas, sf_true, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
lc_obs.J_obs_perp = J_obs;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end
fprintf('[PVV] F_obs=%.4e\n', F_obs);

%% 3. 正演 eps_r=3（非均匀梯度初值）
fprintf('[PVV] 正演 (非均匀梯度 eps_r)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = 3.0 + 1.5*xx/p.R_inner;
end
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

% Born FT J_hyp
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[PVV] F_data=%.6e\n', F_data);

%% 4. 伴随源构建（体积路径）
fprintf('[PVV] 构建体积伴随源...\n');
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);

% 伴随源位置 = 内部体素位置
source_pos_vol = voxel.pos(inner_idx, :);

%% 5. 伴随求解
fprintf('[PVV] 伴随求解...\n');
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[PVV] [FAIL] adjoint\n'); return; end
fprintf('[PVV] |lambda| mean=%.4e\n', mean(vecnorm(lambda,2,2)));

%% 6. 梯度计算（g_direct + g_indirect）
k0_sq = p.k0^2; dV_vec = voxel.dV;
omega_eps0 = p.omega(1) * p.eps0;

g_indirect = zeros(N_inner, 1);
g_direct = zeros(N_inner, 1);

use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) && size(E_gauss,1)==size(voxel.gauss_pos,1);
if use_gauss
    gw = voxel.gauss_w;
    for vi=1:N_inner
        gp=(4*(vi-1)+1):(4*vi); gs=0;
        for gpi=1:4, gs=gs+gw(gpi)*real(sum(conj(E_gauss(gp(gpi),:)).*lambda_gauss(gp(gpi),:))); end  % Hermitian
        g_indirect(vi) = -k0_sq*dV_vec(inner_idx(vi))*gs;
    end
else
    for vi=1:N_inner
        g_indirect(vi) = -k0_sq*dV_vec(inner_idx(vi))*real(sum(conj(E_total(vi,:)).*lambda(vi,:)));  % Hermitian
    end
end

% 直接项: g_direct = +2·dV·ωε₀ · Im[conj(E)·S] / F_obs  (Hermitian)
for vi=1:N_inner
    g_direct(vi) = +2 * dV_vec(inner_idx(vi)) * omega_eps0 ...
        * imag(sum(conj(E_total(vi,:)).*S_field(vi,:))) / F_obs;  % Hermitian
end

g_adj_all = g_direct + g_indirect;

fprintf('[PVV] ||g_direct||=%.4e, ||g_indirect||=%.4e, ||g_total||=%.4e\n', ...
    norm(g_direct), norm(g_indirect), norm(g_adj_all));

%% 7. 逐体素 FD
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fprintf('\n[PVV] ===== 逐体素 FD (N=%d) =====\n', N_s);
fd_delta = 0.001;
g_FD = zeros(N_s,1); g_adj = zeros(N_s,1);
g_dir_s = zeros(N_s,1); g_ind_s = zeros(N_s,1);

for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi); eps_orig = voxel.epsilon_r(v_global);

    % FD：微扰 eps_r ± δ，重新正演 + Born FT
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_pvv(model, p);
    [E_p, ~, ~] = solve_forward(model, voxel, p);
    [~, lc_fwd_p] = born_forward_project(voxel, E_p, p, lc_obs);
    F_plus = sum(dOmega .* sum(abs(J_obs - lc_fwd_p.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_pvv(model, p);
    [E_m, ~, ~] = solve_forward(model, voxel, p);
    [~, lc_fwd_m] = born_forward_project(voxel, E_m, p, lc_obs);
    F_minus = sum(dOmega .* sum(abs(J_obs - lc_fwd_m.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = eps_orig;
    g_FD(si) = (F_plus - F_minus) / (2*fd_delta);
    g_adj(si) = g_adj_all(vi);
    g_dir_s(si) = g_direct(vi);
    g_ind_s(si) = g_indirect(vi);

    if mod(si,5)==0 || si==N_s
        ratio = g_adj(si)/max(abs(g_FD(si)),1e-30);
        s = ternary_s(g_FD(si)*g_adj(si)>0,'OK','XX');
        fprintf('  [%2d/%d] r=%.3f: g_FD=%+.2e g_adj=%+.2e g_dir=%+.2e g_ind=%+.2e ratio=%.4f sign=%s\n', ...
            si,N_s,r_inner(vi), g_FD(si),g_adj(si),g_dir_s(si),g_ind_s(si), ratio,s);
    end
end

%% 8. 统计
sign_match = sign(g_FD .* g_adj) > 0;
sign_rate = sum(sign_match) / N_s;
ratios = g_adj ./ g_FD;
valid = abs(g_FD) > 1e-30;
cos_theta = dot(g_FD, g_adj) / (norm(g_FD)*norm(g_adj));

fprintf('\n############################################################\n');
fprintf('#  体积等效源路径验证结果\n');
fprintf('############################################################\n');
fprintf('#  sign 一致率: %d/%d = %.1f%%\n', sum(sign_match), N_s, 100*sign_rate);
if sum(valid)>0
    rv = ratios(valid);
    fprintf('#  ratio mean=%.6f CV=%.4f\n', mean(rv), std(rv)/abs(mean(rv)));
end
fprintf('#  cos θ = %.6f\n', cos_theta);
if sign_rate>0.9 && cos_theta>0.8
    fprintf('#  ★★★ PASS ★★★\n');
else
    fprintf('#  ⚠ FAIL 或部分通过\n');
end
fprintf('############################################################\n');

result = struct('g_FD',g_FD,'g_adj',g_adj,'g_direct',g_dir_s,'g_indirect',g_ind_s, ...
    'sign_rate',sign_rate,'cos_theta',cos_theta);
save(fullfile(p.dir_result,'per_voxel_volume_result.mat'),'result');
fprintf('\n[PVV] 结果已保存\n');

end

function solve_quiet_pvv(model, p)
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
