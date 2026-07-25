function C01_uniform_complex_inversion()
%C01_UNIFORM_COMPLEX_INVERSION C01 uniform complex sphere inversion
%   True model: eps_r = 5.0 - 5.0j (uniform, no hollow)
%   B-spline: 2x3x4 = 24 control points
%   Frequency: 1.0 GHz single freq
%   Cold start: c = 3.0 + 0j (real, let inversion discover loss)
%
%   Purpose: Isolate complex eps_r pipeline validation.
%   A02 (real uniform 5/7 PASS) proved real pipeline correct.
%   C01 is the complex counterpart.

fprintf('\n');
fprintf('========================================================\n');
fprintf('  C01 - Uniform Complex Sphere Inversion               \n');
fprintf('  True: eps_r = 5.0 - 5.0j (uniform, no hollow)        \n');
fprintf('  B-spline 2x3x4=24 | 1 freq 1GHz | eps_tol=0.05       \n');
fprintf('  Hot start c=4.0-4.0j | Complex inversion             \n');
fprintf('========================================================\n\n');

global C01_MODEL;

%% Step 0: Path init + COMSOL start
fprintf('=== Step 0: Path init + COMSOL start ===\n');
setup();
p = config();
if ~isfield(p, 'rel_err_floor')
    p.rel_err_floor = 1e-12;
end

p.max_iter = 20;
p.eps_tol = 0.05;
p.dir_result_C01 = fullfile(p.dir_result, 'C01');
if ~exist(p.dir_result_C01, 'dir')
    mkdir(p.dir_result_C01);
end
% pipline 自包含：algorithm/ 已包含 C01 所需脚本（exp07a_bspline_param, exp07a_tv_reg）
addpath(fullfile(p.base_path, 'algorithm'));

%% C01-specific parameters
p.n_cx = 2;
p.n_cy = 3;
p.n_cz = 4;
p.bspline_order = 3;
p.lambda_tv = 0.0;

%% Complex true model parameters (uniform, no hollow)
p.eps_r_true_re = 5.0;
p.eps_r_true_im = -5.0;

freqs = [1.0e9];
N_freq = length(freqs);
fprintf('[Step 0] Frequency: %s GHz (single)\n', strjoin(arrayfun(@(f) sprintf('%.1f', f/1e9), freqs, 'UniformOutput', false), ', '));
fprintf('[Step 0] B-spline: %dx%dx%d = %d control points\n', ...
    p.n_cx, p.n_cy, p.n_cz, p.n_cx*p.n_cy*p.n_cz);
fprintf('[Step 0] True model: eps_r = %.1f %+.1fj (uniform)\n', ...
    p.eps_r_true_re, p.eps_r_true_im);
fprintf('[Step 0] Hot start: c_init=4.0-4.0j (near truth 5-5j)\n');
fprintf('[Step 0] lambda_TV: %.4f (disabled)\n', p.lambda_tv);
fprintf('[Step 0] eps_tol: %.4f (strict, simple scene should achieve)\n', p.eps_tol);

fprintf('[Step 0] Starting COMSOL LiveLink (port %d)...\n', p.comsol_port);
try
    mphstart(p.comsol_port);
catch ME
    if ~contains(ME.message, 'Already connected')
        rethrow(ME);
    end
end
model = mphload(p.comsol_model_path);
C01_MODEL = model;

%% Step 1: Scattering model with complex eps_r (uniform, no hollow)
fprintf('\n=== Step 1: Scattering model (uniform complex) ===\n');
voxel = fem_mesh_utils(model, p, p.a_scatter);
N_v = length(voxel.epsilon_r);
N_in = sum(voxel.mask_interior);
fprintf('[Step 1] voxel total: %d, inner: %d\n', N_v, N_in);

% True model: all inner voxels = 5.0 - 5.0j
voxel.epsilon_r_true = ones(N_v, 1);
voxel.epsilon_r_true(voxel.mask_interior) = p.eps_r_true_re + 1i * p.eps_r_true_im;

fprintf('[Step 1] True: eps_r = %.1f %+.1fj (uniform, all %d inner voxels)\n', ...
    p.eps_r_true_re, p.eps_r_true_im, N_in);

grid = build_measurement_grid(p);
[k_dir, dOmega] = fibonacci_sphere(p.N_k);
lc.k_dir = k_dir;
lc.dOmega = dOmega;

%% Step 2: V5a sanity check (complex true model, single freq)
fprintf('\n=== Step 2: V5a sanity check at %d frequency ===\n', N_freq);
voxel.epsilon_r = voxel.epsilon_r_true;

v5a_results = struct('pass', false(1, N_freq), 'max_F_k', zeros(1, N_freq));
for fi = 1:N_freq
    p_freq = p;
    p_freq.freq = freqs(fi);
    p_freq.omega = 2*pi*p_freq.freq;
    p_freq.k0 = p_freq.omega / p_freq.c;
    p_freq.lambda = p_freq.c / p_freq.freq;

    fprintf('[V5a freq=%d] forward solve with complex true model...\n', fi);
    [E_true, ~, ~] = solve_forward(model, voxel, p_freq);

    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, p_freq);
    J_obs_fi = lc_obs.J_obs_perp;
    J_hyp_fi = J_obs_fi;

    Delta = J_obs_fi - J_hyp_fi;
    J_obs_sq = sum(abs(J_obs_fi).^2, 2);
    F_truth_k = sum(abs(Delta).^2, 2) ./ max(J_obs_sq, p.rel_err_floor) / 6;

    v5a_results.pass(fi) = max(F_truth_k) < p.tol_equivalence;
    v5a_results.max_F_k(fi) = max(F_truth_k);

    fprintf('[V5a freq=%d (%.0f GHz)] max F_truth_k=%.4e, %s\n', ...
        fi, freqs(fi)/1e9, max(F_truth_k), ...
        ternary(v5a_results.pass(fi), 'PASS', 'WARN'));
end

%% Step 3: Pre-compute J_obs (complex true model)
fprintf('\n=== Step 3: Pre-compute J_obs at %d frequency ===\n', N_freq);
voxel.epsilon_r = voxel.epsilon_r_true;

J_obs_perp_multi = cell(1, N_freq);
for fi = 1:N_freq
    p_freq = p;
    p_freq.freq = freqs(fi);
    p_freq.omega = 2*pi*p_freq.freq;
    p_freq.k0 = p_freq.omega / p_freq.c;
    p_freq.lambda = p_freq.c / p_freq.freq;

    fprintf('[Step 3 freq=%d] forward solve (complex true model)...\n', fi);
    [E_true, ~, ~] = solve_forward(model, voxel, p_freq);
    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, p_freq);
    J_obs_perp_multi{fi} = lc_obs.J_obs_perp;

    fprintf('[Step 3 freq=%d] |J_obs| mean=%.4e, max=%.4e\n', ...
        fi, mean(vecnorm(J_obs_perp_multi{fi}, 2, 2)), max(vecnorm(J_obs_perp_multi{fi}, 2, 2)));
end

%% Step 4: Hot start (eps_r = 4.0 - 4.0j, near truth)
fprintf('\n=== Step 4: Hot start (eps_r = 4.0-4.0j) ===\n');
voxel.epsilon_r = ones(N_v, 1);
voxel.epsilon_r(voxel.mask_interior) = 4.0 - 4.0j;
fprintf('[Step 4] Hot start: inner eps_r=4.0-4.0j (near truth 5-5j)\n');

%% Step 5: B-spline operator
fprintf('\n=== Step 5: B-spline operator (Nc=%d) ===\n', p.n_cx*p.n_cy*p.n_cz);
B_op = exp07a_bspline_param(voxel, p);
N_c = size(B_op, 2);
fprintf('[Step 5] B_op: %d x %d\n', size(B_op, 1), N_c);

c_init = (4.0 - 4.0j) * ones(N_c, 1);
eps_recon = B_op * c_init;
fprintf('[Step 5] c_init=4.0-4.0j: inner_mean_re=%.4f, inner_mean_im=%.4f\n', ...
    mean(real(eps_recon(voxel.mask_interior))), mean(imag(eps_recon(voxel.mask_interior))));

%% Step 6: Complex inversion loop
fprintf('\n=== Step 6: Complex inversion loop (%d iters, simple descent) ===\n', p.max_iter);
state = C01_inversion_loop(voxel, lc, J_obs_perp_multi, freqs, grid, model, p, B_op, c_init);

%% Step 7: Save state
fprintf('\n=== Step 7: Save inversion_state.mat ===\n');
state.v5a_results = v5a_results;
state.freqs = freqs;
state.N_freq = N_freq;
state.voxel_epsilon_r_true = voxel.epsilon_r_true;
state.voxel_mask_interior = voxel.mask_interior;
state.voxel_pos = voxel.pos;
state.grid_pos = grid.pos;
state.N_v = N_v;
state.N_in = N_in;
state.B_op = B_op;
state.N_c = N_c;
state.lambda_tv = p.lambda_tv;
state.n_cx = p.n_cx;
state.n_cy = p.n_cy;
state.n_cz = p.n_cz;
state.eps_r_true_re = p.eps_r_true_re;
state.eps_r_true_im = p.eps_r_true_im;
state.hot_start = false;
state.algorithm = 'C01_uniform_complex_inversion';

mat_path = fullfile(p.dir_result_C01, 'C01_inversion_state.mat');
fprintf('[Step 7] Saving: %s\n', mat_path);
save(mat_path, 'state', '-v7.3');

mph_path = fullfile(p.dir_result_C01, 'livelink_after.mph');
mphsave(model, mph_path);
fprintf('[Step 7] mphsave: %s\n', mph_path);

%% Step 8: Post-process
fprintf('\n=== Step 8: Post-process ===\n');
C01_postprocess(state, lc, J_obs_perp_multi, freqs, p);

fprintf('\n========================================================\n');
fprintf('  C01 Uniform Complex Inversion Complete (%d iters)    \n', state.iteration);
fprintf('========================================================\n');

end

%% Helper: ternary
function s = ternary(cond, a, b)
    if cond, s = a; else, s = b; end
end
