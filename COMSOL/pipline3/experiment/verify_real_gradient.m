function result = verify_real_gradient(N_sample)
%VERIFY_REAL_GRADIENT Pure real eps_r FD verification using compute_gradient.m
if nargin < 1, N_sample = 10; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  Pure real eps_r FD verification (compute_gradient.m)\n');
fprintf('#  N_sample = %d\n', N_sample);
fprintf('############################################################\n\n');

p = config();
grid_meas = build_measurement_grid(p);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[VRG] [FAIL] COMSOL\n'); return; end
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
fprintf('[VRG] N_inner=%d\n', N_inner);

fprintf('[VRG] J_obs (eps_r=5, real)...\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

[E_true, ~, ~] = solve_forward(model, voxel, p);
[k_dir, dOmega] = fibonacci_sphere(p.N_k);
k_vec = p.k0 * k_dir;
lc_obs.k_dir = k_dir; lc_obs.k_vec = k_vec; lc_obs.dOmega = dOmega;
lc_obs.J_obs_perp = [];
[~, lc_obs] = born_forward_project(voxel, E_true, p, lc_obs);
J_obs = lc_obs.J_hyp_perp;
dOmega = lc_obs.dOmega;
lc_obs.J_obs_perp = J_obs;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2));
if F_obs < p.F_obs_min, F_obs = 1.0; end
fprintf('[VRG] F_obs=%.4e\n', F_obs);

fprintf('[VRG] Forward (non-uniform real eps_r)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = 3.0 + 1.5*xx/p.R_inner;
end
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[VRG] F_data=%.6e\n', F_data);

lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);
fprintf('[VRG] Adjoint solve...\n');
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[VRG] [FAIL] adjoint\n'); return; end

fprintf('[VRG] compute_gradient...\n');
[g_adj, gd_adj, gi_adj] = compute_gradient(voxel, E_total, S_field, lambda, p, F_obs, true, E_gauss, lambda_gauss);
fprintf('[VRG] |g| mean=%.4e\n', mean(abs(g_adj(inner_idx))));

r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);
fd_delta = 0.01;
fprintf('\n[VRG] ===== Per-voxel FD (N=%d, delta=%.4f) =====\n', N_s, fd_delta);

g_FD = zeros(N_s, 1); g_adj_s = zeros(N_s, 1);
for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi);
    eps_orig = voxel.epsilon_r(v_global);
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_vrg(model, p);
    [E_p,~,~] = solve_forward(model, voxel, p);
    [~, lc_p] = born_forward_project(voxel, E_p, p, lc_obs);
    F_plus = sum(dOmega .* sum(abs(J_obs - lc_p.J_hyp_perp).^2,2)) / F_obs;
    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_vrg(model, p);
    [E_m,~,~] = solve_forward(model, voxel, p);
    [~, lc_m] = born_forward_project(voxel, E_m, p, lc_obs);
    F_minus = sum(dOmega .* sum(abs(J_obs - lc_m.J_hyp_perp).^2,2)) / F_obs;
    g_FD(si) = (F_plus - F_minus) / (2*fd_delta);
    g_adj_s(si) = g_adj(v_global);
    voxel.epsilon_r(v_global) = eps_orig;
    if mod(si,5)==0 || si==N_s
        sr = sign(g_FD(si)*g_adj_s(si)) > 0;
        ratio = g_adj_s(si) / (g_FD(si)+1e-30);
        fprintf('  [%2d/%d] g_FD=%+.3e g_adj=%+.3e ratio=%.3f [%s]\n', si, N_s, g_FD(si), g_adj_s(si), ratio, tn(sr));
    end
end

sign_ok = sign(g_FD .* g_adj_s) > 0;
rate = sum(sign_ok) / N_s;
cos_t = dot(g_FD, g_adj_s) / (norm(g_FD)*norm(g_adj_s) + 1e-30);
valid = abs(g_FD) > 1e-30;
ratio = mean(g_adj_s(valid) ./ g_FD(valid));
fprintf('\n############################################################\n');
fprintf('#  Real eps_r gradient result\n');
fprintf('############################################################\n');
fprintf('#  sign: %d/%d = %.1f%%, cos_th=%.4f, ratio=%.4f\n', sum(sign_ok), N_s, 100*rate, cos_t, ratio);
if rate > 0.9 && cos_t > 0.8, fprintf('#  *** PASS ***\n'); else, fprintf('#  ! FAIL\n'); end
fprintf('############################################################\n');
result = struct('g_FD',g_FD,'g_adj',g_adj_s,'sign_rate',rate,'cos_theta',cos_t,'ratio',ratio);
save(fullfile(p.dir_result,'verify_real_gradient_result.mat'),'result');
fprintf('\n[VRG] Saved\n');
end

function solve_quiet_vrg(model, p)
    try model.param.set('freq',num2str(p.freq)); catch; end
    try model.study('std1').feature('freq').set('plist',sprintf('%g[Hz]',p.freq)); catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    try model.physics('emw').prop('BackgroundField').set('Eb',[0 0 1]); catch; end
    try model.param.set('adjoint_mode','1'); catch; end
    try model.physics('emw').feature('vec1').set('Je',{'0','0','0'}); catch; end
    model.sol('sol1').runAll();
end

function s = tn(c), if c, s='OK'; else, s='XX'; end, end
