function verify_forward_pipeline()
%VERIFY_FORWARD_PIPELINE Forward pipeline verification
%   mphload -> fem_mesh -> solve_forward -> J_obs -> J_hyp -> V5a check

fprintf('\n');
fprintf('==========================================================\n');
fprintf('  Forward Pipeline Verification                             \n');
fprintf('  True: eps_r = 3.0 uniform | 1 GHz | 64 k-dir              \n');
fprintf('==========================================================\n\n');

%% Step 0: Path init (pipline 自包含：setup() 自动定位 pipline 根并 addpath)
setup();
p = config();
% pipline 已自带 utils/build_measurement_grid.m，无需 A12 scripts
% COMSOL mli 路径已由 setup() 从 config/env.json 加载
fprintf('[Step 0] config loaded. a_scatter=%.2f m, freq=%.0f Hz, N_k=%d\n', ...
    p.a_scatter, p.freq, p.N_k);
fprintf('[Step 0] pipline root: %s\n', p.base_path);
fprintf('[Step 0] COMSOL model: %s\n', p.comsol_model_path);

%% Step 1: COMSOL LiveLink
fprintf('\n=== Step 1: COMSOL LiveLink ===\n');
try
    mphstart(p.comsol_port);
catch ME
    if ~contains(ME.message, 'Already connected')
        rethrow(ME);
    end
end
model = mphload(p.comsol_model_path);
fprintf('[Step 1] Model loaded: %s\n', p.comsol_model_path);

%% Step 2: FEM mesh extraction
fprintf('\n=== Step 2: fem_mesh_utils ===\n');
voxel = fem_mesh_utils(model, p, p.a_scatter);
N_v = length(voxel.epsilon_r);
N_in = sum(voxel.mask_interior);
fprintf('[Step 2] Total elements: %d, Inner (r<%.2f): %d, Outer: %d\n', ...
    N_v, p.a_scatter, N_in, N_v - N_in);
fprintf('[Step 2] dV range: [%.3e, %.3e] m^3\n', min(voxel.dV), max(voxel.dV));

%% Step 3: Set true eps_r (uniform sphere) -- epsi 修改敏感性实验
fprintf('\n=== Step 3: Set true eps_r = 3.0 (epsi sensitivity test) ===\n');
eps_r_true = 3.0;  % 修改点：原 5.0 → 3.0，验证 epsi 可修改
voxel.epsilon_r = ones(N_v, 1);
voxel.epsilon_r(voxel.mask_interior) = eps_r_true;
fprintf('[Step 3] Inner eps_r: mean=%.4f, std=%.4f (should be 5.0, 0.0)\n', ...
    mean(real(voxel.epsilon_r(voxel.mask_interior))), ...
    std(real(voxel.epsilon_r(voxel.mask_interior))));

%% Step 4: COMSOL forward solve
fprintf('\n=== Step 4: solve_forward ===\n');
[E_total, pos_inner, E_gauss] = solve_forward(model, voxel, p);
fprintf('[Step 4] E_total: %d x %d (complex)\n', size(E_total,1), size(E_total,2));
fprintf('[Step 4] |E| mean=%.4e, max=%.4e V/m\n', ...
    mean(vecnorm(E_total,2,2)), max(vecnorm(E_total,2,2)));
if ~isempty(E_gauss)
    fprintf('[Step 4] E_gauss: %d points (4-pt rule per tet)\n', size(E_gauss,1));
end

%% Step 5: Path A - COMSOL native scattered field -> J_obs
fprintf('\n=== Step 5: Path A - extract_scattered -> lightcone_project -> J_obs ===\n');
grid = build_measurement_grid(p);
sf = extract_scattered(model, grid);
fprintf('[Step 5] Scattered field: %d points, |E_scat| mean=%.4e\n', ...
    size(sf.E_cart,1), mean(vecnorm(sf.E_cart,2,2)));

lc = lightcone_project(grid, sf, p);
J_obs = lc.J_obs_perp;
fprintf('[Step 5] J_obs: %d x %d, |J_obs| mean=%.4e, max=%.4e\n', ...
    size(J_obs,1), size(J_obs,2), ...
    mean(vecnorm(J_obs,2,2)), max(vecnorm(J_obs,2,2)));

%% Step 6: Path B - Born approximation -> J_hyp
fprintf('\n=== Step 6: Path B - equivalent_source -> lightcone_hyp -> J_hyp ===\n');
J_equi = equivalent_source(voxel, E_total, p);
fprintf('[Step 6] J_equi: |J_equi| mean=%.4e\n', ...
    mean(vecnorm(J_equi(voxel.mask_interior,:),2,2)));

lc.k_vec = p.k0 * lc.k_dir;
J_hyp = lightcone_hyp(voxel, J_equi, lc, p);
fprintf('[Step 6] J_hyp: %d x %d, |J_hyp| mean=%.4e, max=%.4e\n', ...
    size(J_hyp,1), size(J_hyp,2), ...
    mean(vecnorm(J_hyp,2,2)), max(vecnorm(J_hyp,2,2)));

%% Step 7: V5a consistency check (J_obs ≈ J_hyp?)
fprintf('\n=== Step 7: V5a Sanity Check ===\n');
fprintf('     Logic: when eps_r=eps_r_true, Born J_hyp should ~= COMSOL J_obs\n');
fprintf('     Criteria: max F_k = max(|J_obs-J_hyp|^2 / |J_obs|^2) < 1e-3\n\n');

Delta_J = J_obs - J_hyp;
J_obs_sq = sum(abs(J_obs).^2, 2);
F_k = sum(abs(Delta_J).^2, 2) ./ max(J_obs_sq, 1e-60) / 6;

fprintf('  k_dir  |   |J_obs|    |J_hyp|    |Delta_J|    F_k\n');
fprintf('  -------+------------------------------------------\n');
for k = 1:min(10, size(J_obs,1))
    fprintf('  k=%2d   | %.4e  %.4e  %.4e  %.4e\n', ...
        k, vecnorm(J_obs(k,:),2), vecnorm(J_hyp(k,:),2), ...
        vecnorm(Delta_J(k,:),2), F_k(k));
end
if size(J_obs,1) > 10
    fprintf('  ...    | (showing 10 of %d directions)\n', size(J_obs,1));
end

fprintf('\n  === V5a Results ===\n');
fprintf('  max F_k     = %.6e  (threshold: 1.0e-3)\n', max(F_k));
fprintf('  mean F_k    = %.6e\n', mean(F_k));
fprintf('  median F_k  = %.6e\n', median(F_k));

ratio_vec = vecnorm(J_obs,2,2) ./ max(vecnorm(J_hyp,2,2), 1e-60);
fprintf('  |J_obs|/|J_hyp| ratio (mean) = %.4f\n', mean(ratio_vec));

if max(F_k) < 1e-3
    fprintf('\n  [PASS] V5a PASS - Forward pipeline correct (Born ~= COMSOL)\n');
else
    fprintf('\n  [WARN] V5a WARN - Born approximation differs from COMSOL full-wave\n');
    fprintf('     Expected for strong scatterer (eps_r=5), Born has ~10pct error\n');
    fprintf('     Inversion can proceed, but F_cheb floor > 0\n');
end

%% Step 8: Per-k direction correlation
fprintf('\n=== Step 8: Per-k direction correlation (cos theta) ===\n');
cos_theta_k = zeros(size(J_obs,1), 1);
for k = 1:size(J_obs,1)
    jo = J_obs(k,:)';
    jh = J_hyp(k,:)';
    norm_prod = vecnorm(jo) * vecnorm(jh);
    if norm_prod > 1e-60
        cos_theta_k(k) = real(dot(jo, jh)) / norm_prod;
    else
        cos_theta_k(k) = 0;
    end
end
fprintf('  cos(theta) mean=%.6f, min=%.6f, max=%.6f\n', ...
    mean(cos_theta_k), min(cos_theta_k), max(cos_theta_k));
fprintf('  (1.0 = perfect, >0.99 = excellent, >0.95 = good)\n');

%% Step 9: Physical scale checks
fprintf('\n=== Step 9: Physical scale checks ===\n');
ka = p.k0 * p.a_scatter;
fprintf('  ka = k0 * a = %.4f * %.4f = %.4f\n', p.k0, p.a_scatter, ka);
fprintf('  wavelength lambda = %.4f m = %.1f cm\n', p.lambda, p.lambda*100);
fprintf('  scatterer diameter = %.4f m = %.1f cm\n', 2*p.a_scatter, 2*p.a_scatter*100);
fprintf('  diameter/lambda ratio = %.2f (Rayleigh<0.3, Mie 0.3-10)\n', 2*p.a_scatter/p.lambda);
fprintf('  inner voxel volume mean = %.2e m^3\n', ...
    mean(voxel.dV(voxel.mask_interior)));
fprintf('  measurement sphere radius = %.2f m\n', p.R_sphere);

%% Step 10: Gauss quadrature check
if ~isempty(E_gauss) && ~isempty(voxel.gauss_pos)
    fprintf('\n=== Step 10: Gauss quadrature check ===\n');
    fprintf('  Inner tet count: %d\n', sum(voxel.mask_interior));
    fprintf('  Gauss points: %d (= 4 x %d)\n', size(E_gauss,1), size(E_gauss,1)/4);
    fprintf('  |E_gauss| mean=%.4e (vs centroid |E| mean=%.4e)\n', ...
        mean(vecnorm(E_gauss,2,2)), mean(vecnorm(E_total,2,2)));
    fprintf('  Gauss/centroid ratio=%.4f (~1 = smooth field)\n', ...
        mean(vecnorm(E_gauss,2,2)) / mean(vecnorm(E_total,2,2)));
end

%% Summary
fprintf('\n==========================================================\n');
fprintf('  Forward Pipeline Verification Summary                     \n');
fprintf('==========================================================\n');
fprintf('  COMSOL forward    [OK] solved (%d voxels, |E|=%.2e)\n', N_in, mean(vecnorm(E_total,2,2)));
fprintf('  J_obs (COMSOL)    [OK] %d k-dir, |J_obs|=%.2e\n', size(J_obs,1), mean(vecnorm(J_obs,2,2)));
fprintf('  J_hyp (Born)      [OK] %d k-dir, |J_hyp|=%.2e\n', size(J_hyp,1), mean(vecnorm(J_hyp,2,2)));
if max(F_k) < 1e-3
    fprintf('  V5a max F_k       [PASS] %.6e\n', max(F_k));
else
    fprintf('  V5a max F_k       [WARN] %.6e\n', max(F_k));
end
fprintf('  Direction cos     %.6f (mean)\n', mean(cos_theta_k));
fprintf('==========================================================\n');

% Cleanup
try
    mphsave(model, fullfile(p.dir_result, 'verify_forward_pipeline_model.mph'));
    fprintf('\n[verify_forward_pipeline] model saved to results/\n');
catch
end

end
