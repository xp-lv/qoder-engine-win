function result = diag_conjK_adjoint(N_sample)
%DIAG_CONJK_ADJOINT Test K^{-H} hypothesis: solve adjoint on conj(eps_r) model
%
%   Scheme A (baseline): K(eps_r)*lambda = f_adj, then conj(lambda) in gradient
%   Scheme E (conj K):   K(conj(eps_r))*mu = f_adj, then mu directly (Hermitian dot)
%
%   Theory: for complex symmetric K, K^{-H} != K^{-1}
%   Solving on conj(eps_r) model gives conj(K)^{-1} = K^{-H}
%   This should fix the ratio for complex eps_r.

if nargin < 1, N_sample = 10; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  Conj-K Adjoint Test: Scheme A vs Scheme E\n');
fprintf('#  N_sample = %d\n', N_sample);
fprintf('############################################################\n\n');

%% 1. Init
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[FAIL] COMSOL\n'); return; end
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

%% 2. J_obs (eps_r = 5-5j)
eps_true = 5.0 - 5j;
voxel.epsilon_r(inner) = eps_true;
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

%% 3. Forward (non-uniform complex eps_r)
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    re_val = 3.0 + 1.5*xx/p.R_inner;
    im_val = -3.0 - 0.5*xx/p.R_inner;
    voxel.epsilon_r(inner_idx(vi)) = re_val + 1j * im_val;
end
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;

%% 4. Build S and f_adj
N_k = p.N_k;
S_field = zeros(N_inner, 3);
for ki = 1:N_k
    phase = exp(+1i * voxel.pos(inner_idx,:) * k_vec(ki,:)');
    S_field = S_field + dOmega(ki) * Delta_J(ki,:) .* phase;
end

coeff = -1i * p.omega(1) * p.eps0 ./ (-1i * p.omega(1) * p.mu0);
source_pos_vol = voxel.pos(inner_idx, :);
eps_inner = voxel.epsilon_r(inner);

% Scheme A adjoint source (same as baseline)
f_adj_A = (coeff ./ F_obs) .* (eps_inner - 1) .* S_field;
fprintf('\n|f_adj| mean=%.4e\n', mean(vecnorm(f_adj_A,2,2)));

%% 5a. Solve adjoint A: K(eps_r)*lambda = f_adj  [CURRENT BASELINE]
fprintf('\n=== Adjoint A: K(eps_r)*lambda = f_adj [baseline] ===\n');
[lambda_A, ok_A, lambda_gauss_A] = solve_adjoint(model, voxel, p, f_adj_A, source_pos_vol);
if ~ok_A, fprintf('[FAIL] adjoint A\n'); result = struct('ok',false); return; end

%% 5b. Solve adjoint E: K(conj(eps_r))*mu = f_adj  [CONJ-K HYPOTHESIS]
fprintf('\n=== Adjoint E: K(conj(eps_r))*mu = f_adj [conj-K] ===\n');
% Save original eps
eps_save = voxel.epsilon_r(inner);
% Conjugate eps_r
voxel.epsilon_r(inner) = conj(eps_save);
update_epsilon(model, voxel, p);
% Clear solution for re-factorization with new K
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
% Solve adjoint on conj(eps_r) model
[mu_E, ok_E, mu_gauss_E] = solve_adjoint(model, voxel, p, f_adj_A, source_pos_vol);
% Restore original eps_r
voxel.epsilon_r(inner) = eps_save;
update_epsilon(model, voxel, p);
% Clear solution (will be re-solved in FD loop)
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
if ~ok_E, fprintf('[FAIL] adjoint E\n'); result = struct('ok',false); return; end

fprintf('\n|lambda_A| mean=%.4e, |mu_E| mean=%.4e\n', ...
    mean(vecnorm(lambda_A,2,2)), mean(vecnorm(mu_E,2,2)));

%% 6. Sample selection
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);
fd_delta = 0.01;

%% 7. Compute analytic gradients
omega = p.omega(1); k0 = p.k0; eps0 = p.eps0; dV_vec = voxel.dV;
gauss_w = voxel.gauss_w;

gFD_re = zeros(N_s,1); gFD_im = zeros(N_s,1);
gA_re = zeros(N_s,1); gA_im = zeros(N_s,1);
gE_re = zeros(N_s,1); gE_im = zeros(N_s,1);
gd_re_s = zeros(N_s,1); gd_im_s = zeros(N_s,1);
giA_re_s = zeros(N_s,1); giA_im_s = zeros(N_s,1);
giE_re_s = zeros(N_s,1); giE_im_s = zeros(N_s,1);

fprintf('\n=== Analytic gradients for %d voxels ===\n', N_s);
for si=1:N_s
    vi = sample_idx(si); vg = inner_idx(vi);
    Ev = E_total(vi,:);
    Sv = S_field(vi,:);
    dV_v = dV_vec(vg);

    % Direct term (same for all schemes)
    ES = dot(Ev, Sv);
    gd_re = +2*omega*eps0*dV_v*imag(ES)/F_obs;
    gd_im = -2*omega*eps0*dV_v*real(ES)/F_obs;

    gp = (4*(vi-1)+1):(4*vi);

    % Scheme A: conj(lambda_A) + bilinear dot
    gs_re_A = 0; gs_im_A = 0;
    for gpi=1:4
        Eg = E_gauss(gp(gpi),:);
        LgA = conj(lambda_gauss_A(gp(gpi),:));
        ELgA = dot(Eg, LgA);  % conj(Eg)*conj(lambda) = conj(Eg*lambda)
        gs_re_A = gs_re_A + gauss_w(gpi)*real(ELgA);
        gs_im_A = gs_im_A + gauss_w(gpi)*imag(ELgA);
    end
    giA_re_v = -k0^2 * dV_v * gs_re_A;
    giA_im_v = -k0^2 * dV_v * gs_im_A;

    % Scheme E: mu_E directly (no conj!) + Hermitian dot
    gs_re_E = 0; gs_im_E = 0;
    for gpi=1:4
        Eg = E_gauss(gp(gpi),:);
        LgE = mu_gauss_E(gp(gpi),:);  % NO conj!
        ELgE = dot(Eg, LgE);  % conj(Eg)*mu = Hermitian inner product
        gs_re_E = gs_re_E + gauss_w(gpi)*real(ELgE);
        gs_im_E = gs_im_E + gauss_w(gpi)*imag(ELgE);
    end
    giE_re_v = -k0^2 * dV_v * gs_re_E;
    giE_im_v = -k0^2 * dV_v * gs_im_E;

    gd_re_s(si) = gd_re; gd_im_s(si) = gd_im;
    giA_re_s(si) = giA_re_v; giA_im_s(si) = giA_im_v;
    giE_re_s(si) = giE_re_v; giE_im_s(si) = giE_im_v;
    gA_re(si) = gd_re + giA_re_v; gA_im(si) = gd_im + giA_im_v;
    gE_re(si) = gd_re + giE_re_v; gE_im(si) = gd_im + giE_im_v;
end

%% 8. FD perturbation
fprintf('\n=== FD perturbation (delta=%.4f) ===\n', fd_delta);
for si=1:N_s
    vi = sample_idx(si); vg = inner_idx(vi);
    eps_orig = voxel.epsilon_r(vg);
    eps_re_o = real(eps_orig); eps_im_o = imag(eps_orig);

    % FD g_re
    voxel.epsilon_r(vg) = (eps_re_o+fd_delta) + 1j*eps_im_o;
    update_epsilon(model, voxel, p);
    solve_quiet_dcv(model, p);
    [E_p,~,~] = solve_forward(model, voxel, p);
    [~, lc_p] = born_forward_project(voxel, E_p, p, lc_obs);
    Fp_re = sum(dOmega .* sum(abs(J_obs - lc_p.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(vg) = (eps_re_o-fd_delta) + 1j*eps_im_o;
    update_epsilon(model, voxel, p);
    solve_quiet_dcv(model, p);
    [E_m,~,~] = solve_forward(model, voxel, p);
    [~, lc_m] = born_forward_project(voxel, E_m, p, lc_obs);
    Fm_re = sum(dOmega .* sum(abs(J_obs - lc_m.J_hyp_perp).^2,2)) / F_obs;

    gFD_re(si) = (Fp_re - Fm_re) / (2*fd_delta);

    % FD g_im
    voxel.epsilon_r(vg) = eps_re_o + 1j*(eps_im_o+fd_delta);
    update_epsilon(model, voxel, p);
    solve_quiet_dcv(model, p);
    [E_p2,~,~] = solve_forward(model, voxel, p);
    [~, lc_p2] = born_forward_project(voxel, E_p2, p, lc_obs);
    Fp_im = sum(dOmega .* sum(abs(J_obs - lc_p2.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(vg) = eps_re_o + 1j*(eps_im_o-fd_delta);
    update_epsilon(model, voxel, p);
    solve_quiet_dcv(model, p);
    [E_m2,~,~] = solve_forward(model, voxel, p);
    [~, lc_m2] = born_forward_project(voxel, E_m2, p, lc_obs);
    Fm_im = sum(dOmega .* sum(abs(J_obs - lc_m2.J_hyp_perp).^2,2)) / F_obs;

    gFD_im(si) = (Fp_im - Fm_im) / (2*fd_delta);
    voxel.epsilon_r(vg) = eps_orig;

    r_v = vecnorm(voxel.pos(vg,:),2,2);
    fprintf('  [%2d] r=%.3f | FD_re=%+.2e A=%+.2e E=%+.2e | FD_im=%+.2e A=%+.2e E=%+.2e\n', ...
        si, r_v, gFD_re(si), gA_re(si), gE_re(si), ...
        gFD_im(si), gA_im(si), gE_im(si));
end

%% 9. Summary
sA_re = sum(sign(gFD_re.*gA_re)>0); sA_im = sum(sign(gFD_im.*gA_im)>0);
sE_re = sum(sign(gFD_re.*gE_re)>0); sE_im = sum(sign(gFD_im.*gE_im)>0);

v_re = abs(gFD_re) > 1e-15; v_im = abs(gFD_im) > 1e-15;
rA_re = mean(abs(gA_re(v_re)./gFD_re(v_re)));
rA_im = mean(abs(gA_im(v_im)./gFD_im(v_im)));
rE_re = mean(abs(gE_re(v_re)./gFD_re(v_re)));
rE_im = mean(abs(gE_im(v_im)./gFD_im(v_im)));

ctA_re = dot(gFD_re,gA_re)/(norm(gFD_re)*norm(gA_re)+1e-30);
ctA_im = dot(gFD_im,gA_im)/(norm(gFD_im)*norm(gA_im)+1e-30);
ctE_re = dot(gFD_re,gE_re)/(norm(gFD_re)*norm(gE_re)+1e-30);
ctE_im = dot(gFD_im,gE_im)/(norm(gFD_im)*norm(gE_im)+1e-30);

fprintf('\n############################################################\n');
fprintf('#  SUMMARY (N=%d)\n', N_s);
fprintf('#  A: K(eps)*lambda + conj(lambda)  [baseline]\n');
fprintf('#    sign_re=%d/%d sign_im=%d/%d ratio_re=%.2f ratio_im=%.2f cos_re=%.3f cos_im=%.3f\n', ...
    sA_re,N_s,sA_im,N_s,rA_re,rA_im,ctA_re,ctA_im);
fprintf('#  E: K(conj(eps))*mu + mu direct  [conj-K hypothesis]\n');
fprintf('#    sign_re=%d/%d sign_im=%d/%d ratio_re=%.2f ratio_im=%.2f cos_re=%.3f cos_im=%.3f\n', ...
    sE_re,N_s,sE_im,N_s,rE_re,rE_im,ctE_re,ctE_im);
fprintf('############################################################\n');

result = struct('ok',true,...
    'gFD_re',gFD_re,'gFD_im',gFD_im,...
    'gA_re',gA_re,'gA_im',gA_im,'gE_re',gE_re,'gE_im',gE_im,...
    'gd_re_s',gd_re_s,'gd_im_s',gd_im_s,...
    'giA_re_s',giA_re_s,'giA_im_s',giA_im_s,...
    'giE_re_s',giE_re_s,'giE_im_s',giE_im_s,...
    'sA_re',sA_re,'sA_im',sA_im,'sE_re',sE_re,'sE_im',sE_im,'N',N_s,...
    'rA_re',rA_re,'rA_im',rA_im,'rE_re',rE_re,'rE_im',rE_im,...
    'ctA_re',ctA_re,'ctA_im',ctA_im,'ctE_re',ctE_re,'ctE_im',ctE_im);
save(fullfile(p.dir_result,'diag_conjK_adjoint_result.mat'),'result');
fprintf('\nSaved.\n');
end

function solve_quiet_dcv(model, p)
    try model.param.set('freq',num2str(p.freq)); catch; end
    try model.study('std1').feature('freq').set('plist',sprintf('%g[Hz]',p.freq)); catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    try model.physics('emw').prop('BackgroundField').set('Eb',[0 0 1]); catch; end
    try model.param.set('adjoint_mode','1'); catch; end
    try model.physics('emw').feature('vec1').set('Je',{'0','0','0'}); catch; end
    model.sol('sol1').runAll();
end
