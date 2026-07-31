function diag_conjS_voxel(N_sample)
%DIAG_CONJS_VOXEL Compare S injection vs conj(S) injection on all voxels
if nargin < 1, N_sample = 10; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  Diagnostic: S vs conj(S) injection comparison\n');
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

%% 4. Build S manually
N_k = p.N_k;
S_field = zeros(N_inner, 3);
for ki = 1:N_k
    phase = exp(+1i * voxel.pos(inner_idx,:) * k_vec(ki,:)');
    S_field = S_field + dOmega(ki) * Delta_J(ki,:) .* phase;
end

coeff = -1i * p.omega(1) * p.eps0 ./ (-1i * p.omega(1) * p.mu0);
source_pos_vol = voxel.pos(inner_idx, :);

%% 5. Adjoint A: S injection (scan #8)
fprintf('\n=== Adjoint A: S injection (scan #8) ===\n');
f_adj_A = (coeff ./ F_obs) .* (voxel.epsilon_r(inner) - 1) .* S_field;
[lambda_A, ok_A, lambda_gauss_A] = solve_adjoint(model, voxel, p, f_adj_A, source_pos_vol);

%% 6. Adjoint B: conj(S) injection
fprintf('\n=== Adjoint B: conj(S) injection ===\n');
f_adj_B = (coeff ./ F_obs) .* (voxel.epsilon_r(inner) - 1) .* conj(S_field);
[lambda_B, ok_B, lambda_gauss_B] = solve_adjoint(model, voxel, p, f_adj_B, source_pos_vol);

if ~ok_A || ~ok_B, fprintf('[FAIL] adjoint solve\n'); return; end

%% 7. Compute gradient for both
omega = p.omega(1); k0 = p.k0; eps0 = p.eps0; dV_vec = voxel.dV;
gauss_w = voxel.gauss_w;

r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);
fd_delta = 0.01;

gFD_re = zeros(N_s,1); gFD_im = zeros(N_s,1);
gA_re = zeros(N_s,1); gA_im = zeros(N_s,1);
gB_re = zeros(N_s,1); gB_im = zeros(N_s,1);
gd_re_s = zeros(N_s,1); gd_im_s = zeros(N_s,1);
giA_re_s = zeros(N_s,1); giA_im_s = zeros(N_s,1);
giB_re_s = zeros(N_s,1); giB_im_s = zeros(N_s,1);

fprintf('\n=== Computing gradients for %d sample voxels ===\n', N_s);
for si=1:N_s
    vi = sample_idx(si); vg = inner_idx(vi);
    Ev = E_total(vi,:);
    Sv = S_field(vi,:);
    dV_v = dV_vec(vg);

    % Direct term (same for A and B)
    ES = dot(Ev, Sv);
    gd_re = +2*omega*eps0*dV_v*imag(ES)/F_obs;
    gd_im = -2*omega*eps0*dV_v*real(ES)/F_obs;

    % Approach A: S inject + conj(lambda) + Hermitian + Gauss
    gp = (4*(vi-1)+1):(4*vi);
    gs_re_A = 0; gs_im_A = 0;
    for gpi=1:4
        Eg = E_gauss(gp(gpi),:);
        LgA = conj(lambda_gauss_A(gp(gpi),:));
        ELgA = dot(Eg, LgA);
        gs_re_A = gs_re_A + gauss_w(gpi)*real(ELgA);
        gs_im_A = gs_im_A + gauss_w(gpi)*imag(ELgA);
    end
    giA_re_v = -k0^2 * dV_v * gs_re_A;
    giA_im_v = -k0^2 * dV_v * gs_im_A;

    % Approach B: conj(S) inject + lambda(no conj) + bilinear + Gauss
    gs_re_B = 0; gs_im_B = 0;
    for gpi=1:4
        Eg = E_gauss(gp(gpi),:);
        LgB = lambda_gauss_B(gp(gpi),:);
        ELgB = sum(Eg .* LgB, 2);
        gs_re_B = gs_re_B + gauss_w(gpi)*real(ELgB);
        gs_im_B = gs_im_B + gauss_w(gpi)*imag(ELgB);
    end
    giB_re_v = -k0^2 * dV_v * gs_re_B;
    giB_im_v = +k0^2 * dV_v * gs_im_B;

    gd_re_s(si) = gd_re; gd_im_s(si) = gd_im;
    giA_re_s(si) = giA_re_v; giA_im_s(si) = giA_im_v;
    giB_re_s(si) = giB_re_v; giB_im_s(si) = giB_im_v;
    gA_re(si) = gd_re + giA_re_v; gA_im(si) = gd_im + giA_im_v;
    gB_re(si) = gd_re + giB_re_v; gB_im(si) = gd_im + giB_im_v;
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

    okA_re = sign(gFD_re(si)*gA_re(si)) > 0;
    okA_im = sign(gFD_im(si)*gA_im(si)) > 0;
    okB_re = sign(gFD_re(si)*gB_re(si)) > 0;
    okB_im = sign(gFD_im(si)*gB_im(si)) > 0;
    r_v = vecnorm(voxel.pos(vg,:),2,2);
    fprintf('  [%2d] r=%.3f | FD_re=%+.2e A_re=%+.2e[%s] B_re=%+.2e[%s] | FD_im=%+.2e A_im=%+.2e[%s] B_im=%+.2e[%s]\n', ...
        si, r_v, gFD_re(si), gA_re(si), tn(okA_re), gB_re(si), tn(okB_re), ...
        gFD_im(si), gA_im(si), tn(okA_im), gB_im(si), tn(okB_im));
end

%% 9. Summary
sA_re = sum(sign(gFD_re.*gA_re)>0);
sA_im = sum(sign(gFD_im.*gA_im)>0);
sB_re = sum(sign(gFD_re.*gB_re)>0);
sB_im = sum(sign(gFD_im.*gB_im)>0);

fprintf('\n############################################################\n');
fprintf('#  SUMMARY (N=%d)\n', N_s);
fprintf('#  A (S+conj_lambda+Hermitian): g_re %d/%d  g_im %d/%d\n', sA_re, N_s, sA_im, N_s);
fprintf('#  B (conj(S)+lambda+bilinear): g_re %d/%d  g_im %d/%d\n', sB_re, N_s, sB_im, N_s);
fprintf('############################################################\n');

fprintf('\n=== g_im detail ===\n');
fprintf('%3s | %11s | %11s %11s %4s | %11s %11s %4s\n', ...
    '#','FD_im','gd_im','giA_im','okA','giB_im','adjB_im','okB');
for si=1:N_s
    okA = sign(gFD_im(si)*gA_im(si)) > 0;
    okB = sign(gFD_im(si)*gB_im(si)) > 0;
    fprintf('%3d | %+11.3e | %+11.3e %+11.3e %4s | %+11.3e %+11.3e %4s\n', ...
        si, gFD_im(si), gd_im_s(si), giA_im_s(si), tn(okA), ...
        giB_im_s(si), gB_im(si), tn(okB));
end

result = struct('gFD_re',gFD_re,'gFD_im',gFD_im,...
    'gA_re',gA_re,'gA_im',gA_im,'gB_re',gB_re,'gB_im',gB_im,...
    'gd_re_s',gd_re_s,'gd_im_s',gd_im_s,...
    'giA_re_s',giA_re_s,'giA_im_s',giA_im_s,...
    'giB_re_s',giB_re_s,'giB_im_s',giB_im_s,...
    'sA_re',sA_re,'sA_im',sA_im,'sB_re',sB_re,'sB_im',sB_im,'N',N_s);
save(fullfile(p.dir_result,'diag_conjS_voxel_result.mat'),'result');
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

function s = tn(c)
    if c, s='OK'; else, s='XX'; end
end
