function diag_sbc_full_verify(N_sample)
%DIAG_SBC_FULL_VERIFY SBC 模型完整复数 ε_r 逐体素验证
%   J_obs=Born FT, lambda=mphinterp(runAll), K 近似对称

if nargin < 1, N_sample = 4; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  SBC 模型完整复数 ε_r 验证 (N=%d)\n', N_sample);
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
fprintf('N_inner=%d\n', N_inner);

%% 2. J_obs (Born FT, eps_r=5-3j)
fprintf('J_obs (Born FT, eps_r=5-3j)...\n');
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

%% 3. 正演 eps_r=3-1j（非均匀梯度）
fprintf('正演 (eps_r=3-1j)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;

%% 4. 伴随源 + runAll 求解
fprintf('伴随求解...\n');
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);
[lambda, ok_adj] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[FAIL] adjoint\n'); return; end

%% 5. 计算所有体素的伴随梯度
k0_sq = p.k0^2; omega_eps0 = p.omega(1)*p.eps0;

g_adj_re = zeros(N_inner, 1);
g_adj_im = zeros(N_inner, 1);
g_direct_re = zeros(N_inner, 1);
g_direct_im = zeros(N_inner, 1);
g_indirect_re = zeros(N_inner, 1);
g_indirect_im = zeros(N_inner, 1);

for vi = 1:N_inner
    v_global = inner_idx(vi);
    dV_v = voxel.dV(v_global);
    E_v = E_total(vi,:);
    S_v = S_field(vi,:);
    L_v = lambda(vi,:);
    L_c = conj(L_v);

    ES = sum(conj(E_v).*S_v);
    EL = sum(conj(E_v).*L_c);

    g_direct_re(vi) = +2*dV_v*omega_eps0*imag(ES)/F_obs;
    g_direct_im(vi) = -2*dV_v*omega_eps0*real(ES)/F_obs;
    g_indirect_re(vi) = -k0_sq*dV_v*real(EL);
    g_indirect_im(vi) = -k0_sq*dV_v*imag(EL);

    g_adj_re(vi) = g_direct_re(vi) + g_indirect_re(vi);
    g_adj_im(vi) = g_direct_im(vi) + g_indirect_im(vi);
end

%% 6. 逐体素 FD
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fprintf('\n逐体素 FD (N=%d, δ=0.01)...\n\n', N_s);
fd_delta = 0.01;
g_FD_re = zeros(N_s,1); g_FD_im = zeros(N_s,1);

for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi); eps_orig = voxel.epsilon_r(v_global);

    % FD re
    voxel.epsilon_r(v_global) = (real(eps_orig)+fd_delta)+1i*imag(eps_orig);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Ep,~,~] = solve_forward(model, voxel, p);
    [~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
    Fp = sum(dOmega .* sum(abs(J_obs-lcp.J_hyp_perp).^2,2))/F_obs;

    voxel.epsilon_r(v_global) = (real(eps_orig)-fd_delta)+1i*imag(eps_orig);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Em,~,~] = solve_forward(model, voxel, p);
    [~,lcm_f] = born_forward_project(voxel, Em, p, lc_obs);
    Fm = sum(dOmega .* sum(abs(J_obs-lcm_f.J_hyp_perp).^2,2))/F_obs;
    g_FD_re(si) = (Fp-Fm)/(2*fd_delta);

    % FD im
    voxel.epsilon_r(v_global) = real(eps_orig)+1i*(imag(eps_orig)+fd_delta);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Ep,~,~] = solve_forward(model, voxel, p);
    [~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
    Fp = sum(dOmega .* sum(abs(J_obs-lcp.J_hyp_perp).^2,2))/F_obs;

    voxel.epsilon_r(v_global) = real(eps_orig)+1i*(imag(eps_orig)-fd_delta);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Em,~,~] = solve_forward(model, voxel, p);
    [~,lcm_f] = born_forward_project(voxel, Em, p, lc_obs);
    Fm = sum(dOmega .* sum(abs(J_obs-lcm_f.J_hyp_perp).^2,2))/F_obs;
    g_FD_im(si) = (Fp-Fm)/(2*fd_delta);

    voxel.epsilon_r(v_global) = eps_orig;

    r_re = g_adj_re(vi)/max(abs(g_FD_re(si)),1e-30);
    r_im = g_adj_im(vi)/max(abs(g_FD_im(si)),1e-30);
    s_re = ts(g_FD_re(si)*g_adj_re(vi)>0);
    s_im = ts(g_FD_im(si)*g_adj_im(vi)>0);

    fprintf('[%d/%d] r=%.4f:\n  re: FD=%+.3e adj=%+.3e ratio=%+.2f %s\n  im: FD=%+.3e adj=%+.3e ratio=%+.2f %s\n', ...
        si,N_s,r_inner(vi), g_FD_re(si),g_adj_re(vi),r_re,s_re, g_FD_im(si),g_adj_im(vi),r_im,s_im);
end

%% 7. 统计
sign_re = sign(g_FD_re .* g_adj_re(sample_idx)) > 0;
sign_im = sign(g_FD_im .* g_adj_im(sample_idx)) > 0;
cos_re = dot(g_FD_re, g_adj_re(sample_idx)) / (norm(g_FD_re)*norm(g_adj_re(sample_idx)));
cos_im = dot(g_FD_im, g_adj_im(sample_idx)) / (norm(g_FD_im)*norm(g_adj_im(sample_idx)));
ratios_re = g_adj_re(sample_idx) ./ g_FD_re; ratios_im = g_adj_im(sample_idx) ./ g_FD_im;
v_re = abs(g_FD_re)>1e-30; v_im = abs(g_FD_im)>1e-30;

fprintf('\n############################################################\n');
fprintf('#  SBC 模型复数 ε_r 验证结果\n');
fprintf('############################################################\n');
fprintf('#  [实部] sign=%d/%d=%.0f%%  cosθ=%.4f\n', sum(sign_re),N_s,100*sum(sign_re)/N_s,cos_re);
if sum(v_re)>0, fprintf('#         ratio mean=%.4f CV=%.4f\n', mean(ratios_re(v_re)), std(ratios_re(v_re))/abs(mean(ratios_re(v_re)))); end
fprintf('#  [虚部] sign=%d/%d=%.0f%%  cosθ=%.4f\n', sum(sign_im),N_s,100*sum(sign_im)/N_s,cos_im);
if sum(v_im)>0, fprintf('#         ratio mean=%.4f CV=%.4f\n', mean(ratios_im(v_im)), std(ratios_im(v_im))/abs(mean(ratios_im(v_im)))); end
if sum(sign_re)>=0.75*N_s && sum(sign_im)>=0.75*N_s && cos_re>0.8 && cos_im>0.8
    fprintf('#  ★★★ PASS ★★★\n');
else
    fprintf('#  ⚠ 部分通过\n');
end
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
