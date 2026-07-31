function diag_real_voxel3()
%DIAG_REAL_VOXEL3 实数 eps_r 场景下第3体素的 FD vs 伴随法梯度
%   真值 eps_r=5.0, 初值 eps_r=3.0（非均匀梯度）

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  实数 eps_r 验证: 真值=5.0, 初值=3.0\n');
fprintf('#  测试 4 个体素（含第3体素 r≈0.048）\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[DIAG] [FAIL] mphstart\n'); return; end
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

%% 2. J_obs（真值 eps_r=5，Stratton-Chu）
fprintf('[DIAG] J_obs (eps_r=5.0, Stratton-Chu)...\n');
voxel.epsilon_r(inner) = 5.0;
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
fprintf('[DIAG] F_obs=%.4e\n\n', F_obs);

%% 3. 正演 eps_r=3（非均匀梯度，纯实数）
fprintf('[DIAG] 正演 (eps_r=3 非均匀梯度, 纯实数)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = 3.0 + 1.5*xx/p.R_inner;  % 纯实数
end
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[DIAG] F_data=%.6e\n\n', F_data);

%% 4. 伴随源 + 求解
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[DIAG] [FAIL] adjoint\n'); return; end
fprintf('[DIAG] |lambda| mean=%.4e\n\n', mean(vecnorm(lambda,2,2)));

%% 5. 选 4 个体素
k0_sq = p.k0^2; omega_eps0 = p.omega(1)*p.eps0;
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
N_s = length(sample_idx);

%% 6. 伴随梯度（质心取值，实数 ε_r → 只有 g_re）
g_adj = zeros(N_s, 1);
g_direct_all = zeros(N_s, 1);
g_indirect_all = zeros(N_s, 1);
for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi);
    Ev = E_total(vi,:); Sv = S_field(vi,:); Lv = lambda(vi,:);
    dV_v = voxel.dV(v_global);
    ES = sum(conj(Ev) .* Sv);   % Hermitian
    EL = sum(conj(Ev) .* Lv);   % Hermitian (实数 eps_r 不需 conj(λ))
    gd = +2*dV_v*omega_eps0*imag(ES)/F_obs;
    gi = -k0_sq*dV_v*real(EL);
    g_adj(si) = gd + gi;
    g_direct_all(si) = gd;
    g_indirect_all(si) = gi;
end

%% 7. 逐体素 FD（实部扰动）
fprintf('===== 逐体素 FD (实数 eps_r, δ=0.01) =====\n\n');
fd_delta = 0.01;
g_FD = zeros(N_s, 1);

for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi); eps_orig = voxel.epsilon_r(v_global);

    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Ep,~,~] = solve_forward(model, voxel, p);
    [~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
    Fp = sum(dOmega .* sum(abs(J_obs - lcp.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Em,~,~] = solve_forward(model, voxel, p);
    [~,lcm] = born_forward_project(voxel, Em, p, lc_obs);
    Fm = sum(dOmega .* sum(abs(J_obs - lcm.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = eps_orig;
    g_FD(si) = (Fp - Fm) / (2*fd_delta);

    ratio = g_adj(si) / max(abs(g_FD(si)), 1e-30);
    s = '-'; if g_FD(si)*g_adj(si) > 0, s = 'OK'; end
    fprintf('  [%d/%d] r=%.4f: g_FD=%+.4e g_adj=%+.4e gd=%+.4e gi=%+.4e ratio=%+.4f %s\n', ...
        si, N_s, r_inner(vi), g_FD(si), g_adj(si), g_direct_all(si), g_indirect_all(si), ratio, s);
end

%% 8. 统计
sign_match = sign(g_FD .* g_adj) > 0;
sign_rate = sum(sign_match) / N_s;
cos_theta = dot(g_FD, g_adj) / (norm(g_FD)*norm(g_adj));
ratios = g_adj ./ g_FD;
valid = abs(g_FD) > 1e-30;

fprintf('\n############################################################\n');
fprintf('#  实数 eps_r 验证结果\n');
fprintf('############################################################\n');
fprintf('#  sign 一致率: %d/%d = %.1f%%\n', sum(sign_match), N_s, 100*sign_rate);
if sum(valid)>0
    rv = ratios(valid);
    fprintf('#  ratio mean=%.4f CV=%.4f\n', mean(rv), std(rv)/abs(mean(rv)));
end
fprintf('#  cos θ = %.6f\n', cos_theta);
if sign_rate >= 0.75 && cos_theta > 0.8
    fprintf('#  ★★★ PASS ★★★\n');
else
    fprintf('#  ⚠ FAIL\n');
end
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
