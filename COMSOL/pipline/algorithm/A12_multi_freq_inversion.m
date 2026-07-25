function A12_multi_freq_inversion()
%A12_MULTI_FREQ_INVERSION A12 multi-freq inversion (PoU fix + F_data-only Armijo)
%   3 freqs (1/2/3 GHz) + cold start (c=4.0*ones) + Full Maxwell J_hyp
%
%   A12 = A10 (F_data-only Armijo) + A11 (PoU fix + c_init=4.0*ones)
%
%   A08->A09->A10->A11->A12 chain:
%   A08: λ=0.02, F_total, 0/10 accepted (TV blocks gradient+cost)
%   A09: λ=0.001, F_total, 0/10 accepted (TV blocks cost, gradient fixed)
%   A10: λ=0.001, F_data-only, 3/5 accepted (TV unblocked but explodes, PoU broken)
%   A11: λ=0.001, F_total, PoU fixed, 0/2 accepted (zero-TV trap: R_TV~0, any step blocked)
%   A12: λ=0.001, F_data-only, PoU fixed → combine A10+A11 fixes
%        Expected: steps accepted (F_data-only avoids zero-TV trap),
%        inner_mean moves toward 5.0 (PoU fix gives cos=0.340, good direction)

fprintf('\n');
fprintf('========================================================\n');
fprintf('  A12 - PoU Fix + F_data-only Armijo (A10+A11 combined) \n');
fprintf('  B-spline row sums = 1.0 | c_init = 4.0*ones           \n');
fprintf('  lambda_TV=0.001 | F_data Armijo (not F_total)        \n');
fprintf('========================================================\n\n');

global A12_MODEL;

%% Step 0: Path init + COMSOL start
fprintf('=== Step 0: Path init + COMSOL start ===\n');
setup();
p = config();
if ~isfield(p, 'rel_err_floor')
    p.rel_err_floor = 1e-12;
end

p.max_iter = 10;
p.eps_tol = 1e-6;
p.dir_result_A12 = fullfile(p.dir_result, 'A12');
if ~exist(p.dir_result_A12, 'dir')
    mkdir(p.dir_result_A12);
end
% pipline 自包含：algorithm/ 已包含 A12 所需脚本（exp07a_bspline_param, exp07a_tv_reg）
addpath(fullfile(p.base_path, 'algorithm'));

p.n_cx = 10;
p.n_cy = 10;
p.n_cz = 2;
p.bspline_order = 3;
p.lambda_tv = 0.001;

freqs = [1e9, 2e9, 3e9];
N_freq = length(freqs);
fprintf('[Step 0] Frequencies: %s GHz\n', strjoin(arrayfun(@(f) sprintf('%.0f', f/1e9), freqs, 'UniformOutput', false), ', '));
fprintf('[Step 0] B-spline: %dx%dx%d = %d control points\n', p.n_cx, p.n_cy, p.n_cz, p.n_cx*p.n_cy*p.n_cz);
fprintf('[Step 0] lambda_TV: %.4f\n', p.lambda_tv);
fprintf('[Step 0] Armijo: F_data-only (A10 style, avoids zero-TV trap)\n');
fprintf('[Step 0] PoU: fixed (row sums = 1.0, c=4.0 -> eps_r=4.0 everywhere)\n');
fprintf('[Step 0] Cold start: c_init = 4.0*ones (PoU guarantees eps_r=4.0 everywhere)\n');

fprintf('[Step 0] Starting COMSOL LiveLink (port %d)...\n', p.comsol_port);
try
    mphstart(p.comsol_port);
catch ME
    if ~contains(ME.message, 'Already connected')
        rethrow(ME);
    end
end
model = mphload(p.comsol_model_path);
A12_MODEL = model;

%% Step 1: Scattering model
fprintf('\n=== Step 1: Scattering model (inner-only) ===\n');
voxel = fem_mesh_utils(model, p, p.a_scatter);
N_v = length(voxel.epsilon_r);
N_in = sum(voxel.mask_interior);
fprintf('[Step 1] voxel total: %d, inner: %d\n', N_v, N_in);

voxel.epsilon_r_true = ones(N_v, 1);
voxel.epsilon_r_true(voxel.mask_interior) = 5.0;

grid = build_measurement_grid(p);
[k_dir, dOmega] = fibonacci_sphere(p.N_k);
lc.k_dir = k_dir;
lc.dOmega = dOmega;

%% Step 2: V5a sanity check
fprintf('\n=== Step 2: V5a sanity check at %d frequencies ===\n', N_freq);
voxel.epsilon_r = voxel.epsilon_r_true;

v5a_results = struct('pass', false(1, N_freq), 'max_F_k', zeros(1, N_freq));
for fi = 1:N_freq
    p_freq = p;
    p_freq.freq = freqs(fi);
    p_freq.omega = 2*pi*p_freq.freq;
    p_freq.k0 = p_freq.omega / p_freq.c;
    p_freq.lambda = p_freq.c / p_freq.freq;

    fprintf('[V5a freq=%d] forward solve with true eps_r=5.0...\n', fi);
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

if any(~v5a_results.pass)
    warning('[A12] V5a sanity check WARN. Inversion continues.');
end

%% Step 3: Pre-compute J_obs
fprintf('\n=== Step 3: Pre-compute J_obs at %d frequencies ===\n', N_freq);
voxel.epsilon_r = voxel.epsilon_r_true;

J_obs_perp_multi = cell(1, N_freq);
for fi = 1:N_freq
    p_freq = p;
    p_freq.freq = freqs(fi);
    p_freq.omega = 2*pi*p_freq.freq;
    p_freq.k0 = p_freq.omega / p_freq.c;
    p_freq.lambda = p_freq.c / p_freq.freq;

    fprintf('[Step 3 freq=%d] forward solve (true eps_r=5.0)...\n', fi);
    [E_true, ~, ~] = solve_forward(model, voxel, p_freq);
    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, p_freq);
    J_obs_perp_multi{fi} = lc_obs.J_obs_perp;

    fprintf('[Step 3 freq=%d] |J_obs| mean=%.4e, max=%.4e\n', ...
        fi, mean(vecnorm(J_obs_perp_multi{fi}, 2, 2)), max(vecnorm(J_obs_perp_multi{fi}, 2, 2)));
end

%% Step 4: Cold start (eps_r = 4.0)
fprintf('\n=== Step 4: Cold start (eps_r = 4.0) ===\n');
voxel.epsilon_r(voxel.mask_interior) = 4.0;
voxel.epsilon_r(~voxel.mask_interior) = 1.0;
fprintf('[Step 4] Cold start: inner_mean=4.0 (vs true 5.0)\n');

%% Step 5: B-spline operator construction (with PoU fix)
fprintf('\n=== Step 5: B-spline operator construction (Nc=%d, PoU fixed) ===\n', p.n_cx*p.n_cy*p.n_cz);
B_op = exp07a_bspline_param(voxel, p);
N_c = size(B_op, 2);
fprintf('[Step 5] B_op: %d x %d\n', size(B_op, 1), N_c);

% A12: c_init = 4.0 * ones (PoU guarantees eps_r=4.0 everywhere)
c_init = 4.0 * ones(N_c, 1);
eps_recon = B_op * c_init;
recon_err = norm(eps_recon - voxel.epsilon_r(:)) / max(norm(voxel.epsilon_r(:)), eps);
inner_mean_recon = mean(real(eps_recon(voxel.mask_interior)));
fprintf('[Step 5] c_init=4.0*ones: inner_mean=%.6f (A10 was 2.324, A11 fixed=4.0, target=4.0)\n', inner_mean_recon);
fprintf('[Step 5] recon_err vs mixed eps_r: %.4e (expected non-zero, outer=1.0 vs 4.0)\n', recon_err);

%% Step 6: Multi-freq inversion loop
fprintf('\n=== Step 6: Multi-freq inversion loop (c-space, %d iters, F_data-only Armijo) ===\n', p.max_iter);
state = A12_inversion_loop(voxel, lc, J_obs_perp_multi, freqs, grid, model, p, B_op, c_init);

%% Step 7: Save state + mph
fprintf('\n=== Step 7: Save inversion_state.mat + mph ===\n');
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
state.hot_start = false;
state.hot_start_source = 'cold_pou_fixed_fdata_armijo';
state.algorithm = 'A12_multi_freq_v3_bspline_pou_fix_fdata_armijo_full_maxwell';

mat_path = fullfile(p.dir_result_A12, 'A12_inversion_state_3.0.mat');
fprintf('[Step 7] Saving: %s\n', mat_path);
save(mat_path, 'state', '-v7.3');

mph_path = fullfile(p.dir_result_A12, 'livelink_after.mph');
mphsave(model, mph_path);
fprintf('[Step 7] mphsave: %s\n', mph_path);

%% Step 8: Post-process
fprintf('\n=== Step 8: Post-process ===\n');
A12_postprocess(state, lc, J_obs_perp_multi, freqs, p);

fprintf('\n========================================================\n');
fprintf('  A12 Multi-Freq Inversion Complete (%d iters)          \n', state.iteration);
fprintf('========================================================\n');

end

%% Helper: ternary
function s = ternary(cond, a, b)
    if cond, s = a; else, s = b; end
end
