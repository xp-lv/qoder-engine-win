function diag_sbc_real_verify(N_sample)
%DIAG_SBC_REAL_VERIFY SBC模型 实数eps_r=5 逐体素 FD vs 伴随法
%   纯实数 → K应为实对称 → ratio应趋于1

if nargin < 1, N_sample = 4; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  SBC模型 实数 eps_r=5 验证 (N=%d)\n', N_sample);
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

%% 2. J_obs (Born FT, eps_r=5 纯实数)
fprintf('J_obs (Born FT, eps_r=5.0)...\n');
voxel.epsilon_r(inner) = 5.0;
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

%% 3. 正演 eps_r=3 (纯实数，非均匀梯度)
fprintf('正演 (eps_r=3, 非均匀梯度)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = 3.0 + 1.5*xx/p.R_inner;
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

%% 5. 计算所有体素的伴随梯度（实数eps_r → 只有实部）
k0_sq = p.k0^2; omega_eps0 = p.omega(1)*p.eps0;
g_adj = zeros(N_inner, 1);
g_direct = zeros(N_inner, 1);
g_indirect = zeros(N_inner, 1);

for vi = 1:N_inner
    v_global = inner_idx(vi);
    dV_v = voxel.dV(v_global);
    E_v = E_total(vi,:);
    S_v = S_field(vi,:);
    L_v = lambda(vi,:);
    % 实数 eps_r → Hermitian dot(E,λ) = conj(E)·λ
    ES = sum(conj(E_v).*S_v);
    EL = sum(conj(E_v).*L_v);
    g_direct(vi) = +2*dV_v*omega_eps0*imag(ES)/F_obs;
    g_indirect(vi) = -k0_sq*dV_v*real(EL);
    g_adj(vi) = g_direct(vi) + g_indirect(vi);
end

%% 6. 逐体素 FD
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fprintf('\n逐体素 FD (N=%d, δ=0.01, 实数eps_r)...\n\n', N_s);
fd_delta = 0.01;
g_FD = zeros(N_s,1);

for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi); eps_orig = voxel.epsilon_r(v_global);

    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Ep,~,~] = solve_forward(model, voxel, p);
    [~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
    Fp = sum(dOmega .* sum(abs(J_obs-lcp.J_hyp_perp).^2,2))/F_obs;

    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Em,~,~] = solve_forward(model, voxel, p);
    [~,lcm_f] = born_forward_project(voxel, Em, p, lc_obs);
    Fm = sum(dOmega .* sum(abs(J_obs-lcm_f.J_hyp_perp).^2,2))/F_obs;

    voxel.epsilon_r(v_global) = eps_orig;
    g_FD(si) = (Fp-Fm)/(2*fd_delta);

    r_ratio = g_adj(vi)/max(abs(g_FD(si)),1e-30);
    s = ts(g_FD(si)*g_adj(vi)>0);
    fprintf('[%d/%d] r=%.4f: FD=%+.4e adj=%+.4e gd=%+.4e gi=%+.4e ratio=%+.4f %s\n', ...
        si,N_s,r_inner(vi), g_FD(si),g_adj(vi),g_direct(vi),g_indirect(vi), r_ratio, s);
end

%% 7. 统计
sign_match = sign(g_FD .* g_adj(sample_idx)) > 0;
sign_rate = sum(sign_match)/N_s;
cos_theta = dot(g_FD, g_adj(sample_idx)) / (norm(g_FD)*norm(g_adj(sample_idx)));
ratios = g_adj(sample_idx) ./ g_FD;
valid = abs(g_FD) > 1e-30;

fprintf('\n############################################################\n');
fprintf('#  SBC模型 实数 eps_r=5 验证结果\n');
fprintf('############################################################\n');
fprintf('#  sign: %d/%d=%.0f%%  cosθ=%.4f\n', sum(sign_match),N_s,100*sign_rate,cos_theta);
if sum(valid)>0
    rv = ratios(valid);
    fprintf('#  ratio mean=%.4f CV=%.4f\n', mean(rv), std(rv)/abs(mean(rv)));
end
if sign_rate>=0.75 && cos_theta>0.8
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
