function verify_forward_pipeline_nonuniform()
%VERIFY_FORWARD_PIPELINE_NONUNIFORM 非均匀 eps_r 空间分布注入实验
%   把内层 673 体素按 x 坐标一分为二：
%     左半 (x<0):  eps_r = 5.0
%     右半 (x>=0): eps_r = 2.0
%   对比均匀基线 (eps_r=3.0)，观察空间分布对 E/J_obs/J_hyp 的影响。
%
%   验证目标：
%     ① COMSOL 正演能否吃下空间非均匀 eps_r（int2 插值表已支持坐标依赖）
%     ② 非均匀分布下 J_obs vs J_hyp 的 V5a 一致性是否退化
%     ③ E_total 场是否呈现左右不对称的物理预期

fprintf('\n');
fprintf('==========================================================\n');
fprintf('  Forward Pipeline - NONUNIFORM eps_r Spatial Injection    \n');
fprintf('  Left (x<0):  eps_r = 5.0  |  Right (x>=0): eps_r = 2.0   \n');
fprintf('  1 GHz | 64 k-dir                                          \n');
fprintf('==========================================================\n\n');

%% Step 0: Path init
setup();
p = config();
fprintf('[Step 0] config loaded. a_scatter=%.2f m, freq=%.0f Hz, N_k=%d\n', ...
    p.a_scatter, p.freq, p.N_k);

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
fprintf('[Step 1] Model loaded\n');

%% Step 2: FEM mesh
fprintf('\n=== Step 2: fem_mesh_utils ===\n');
voxel = fem_mesh_utils(model, p, p.a_scatter);
N_v = length(voxel.epsilon_r);
N_in = sum(voxel.mask_interior);
fprintf('[Step 2] Inner voxels: %d\n', N_in);

%% Step 3: NONUNIFORM eps_r injection
fprintf('\n=== Step 3: NONUNIFORM eps_r (left=5.0, right=2.0) ===\n');
voxel.epsilon_r = ones(N_v, 1);
inner_pos = voxel.pos(voxel.mask_interior, :);
inner_idx = find(voxel.mask_interior);

% 按 x 坐标切分（中心 x=0）
left_mask  = inner_pos(:,1) < 0;
right_mask = ~left_mask;

left_idx  = inner_idx(left_mask);
right_idx = inner_idx(right_mask);

voxel.epsilon_r(left_idx)  = 5.0;
voxel.epsilon_r(right_idx) = 2.0;

eps_left  = voxel.epsilon_r(left_idx);
eps_right = voxel.epsilon_r(right_idx);
fprintf('[Step 3] Left  (x<0):  %d voxels, eps_r mean=%.4f, std=%.4f\n', ...
    numel(left_idx), mean(real(eps_left)), std(real(eps_left)));
fprintf('[Step 3] Right (x>=0): %d voxels, eps_r mean=%.4f, std=%.4f\n', ...
    numel(right_idx), mean(real(eps_right)), std(real(eps_right)));
fprintf('[Step 3] Total inner eps_r mean=%.4f (geometric expectation ~3.5)\n', ...
    mean(real(voxel.epsilon_r(voxel.mask_interior))));

%% Step 4: COMSOL forward solve
fprintf('\n=== Step 4: solve_forward ===\n');
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

% 分左右两侧统计 E 场
E_left  = E_total(left_mask, :);
E_right = E_total(right_mask, :);
fprintf('[Step 4] |E| left  (eps=5): mean=%.4e V/m\n', mean(vecnorm(E_left,2,2)));
fprintf('[Step 4] |E| right (eps=2): mean=%.4e V/m\n', mean(vecnorm(E_right,2,2)));
fprintf('[Step 4] |E| overall:        mean=%.4e V/m\n', mean(vecnorm(E_total,2,2)));
fprintf('[Step 4] Asymmetry ratio |E_left|/|E_right| = %.4f\n', ...
    mean(vecnorm(E_left,2,2)) / mean(vecnorm(E_right,2,2)));

%% Step 5: J_obs (COMSOL)
fprintf('\n=== Step 5: J_obs (COMSOL scattered) ===\n');
grid = build_measurement_grid(p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
J_obs = lc.J_obs_perp;
fprintf('[Step 5] |J_obs| mean=%.4e, max=%.4e\n', ...
    mean(vecnorm(J_obs,2,2)), max(vecnorm(J_obs,2,2)));

%% Step 6: J_hyp (Born)
fprintf('\n=== Step 6: J_hyp (Born) ===\n');
J_equi = equivalent_source(voxel, E_total, p);
lc.k_vec = p.k0 * lc.k_dir;
J_hyp = lightcone_hyp(voxel, J_equi, lc, p);
fprintf('[Step 6] |J_hyp| mean=%.4e, max=%.4e\n', ...
    mean(vecnorm(J_hyp,2,2)), max(vecnorm(J_hyp,2,2)));

%% Step 7: V5a consistency
fprintf('\n=== Step 7: V5a Sanity Check (nonuniform eps_r) ===\n');
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

fprintf('\n  === V5a Results (nonuniform) ===\n');
fprintf('  max F_k     = %.6e  (threshold: 1.0e-3)\n', max(F_k));
fprintf('  mean F_k    = %.6e\n', mean(F_k));
fprintf('  median F_k  = %.6e\n', median(F_k));
ratio_vec = vecnorm(J_obs,2,2) ./ max(vecnorm(J_hyp,2,2), 1e-60);
fprintf('  |J_obs|/|J_hyp| ratio (mean) = %.4f\n', mean(ratio_vec));

if max(F_k) < 1e-3
    fprintf('\n  [PASS] V5a PASS\n');
else
    fprintf('\n  [WARN] V5a WARN - Born approximation differs from COMSOL\n');
end

%% Step 8: Per-k correlation
fprintf('\n=== Step 8: Per-k direction correlation ===\n');
cos_theta_k = zeros(size(J_obs,1), 1);
for k = 1:size(J_obs,1)
    jo = J_obs(k,:)';
    jh = J_hyp(k,:)';
    norm_prod = vecnorm(jo) * vecnorm(jh);
    if norm_prod > 1e-60
        cos_theta_k(k) = real(dot(jo, jh)) / norm_prod;
    end
end
fprintf('  cos(theta) mean=%.6f, min=%.6f, max=%.6f\n', ...
    mean(cos_theta_k), min(cos_theta_k), max(cos_theta_k));

%% Summary
fprintf('\n==========================================================\n');
fprintf('  Nonuniform eps_r Verification Summary                   \n');
fprintf('==========================================================\n');
fprintf('  Distribution     Left (x<0) = 5.0 | Right (x>=0) = 2.0  \n');
fprintf('  Voxel split      %d left | %d right                   \n', ...
    numel(left_idx), numel(right_idx));
fprintf('  |E| left/right   %.4e / %.4e (asymmetry=%.4f)        \n', ...
    mean(vecnorm(E_left,2,2)), mean(vecnorm(E_right,2,2)), ...
    mean(vecnorm(E_left,2,2))/mean(vecnorm(E_right,2,2)));
fprintf('  COMSOL forward   [OK] |E| overall=%.2e\n', mean(vecnorm(E_total,2,2)));
fprintf('  J_obs (COMSOL)   [OK] |J_obs|=%.2e\n', mean(vecnorm(J_obs,2,2)));
fprintf('  J_hyp (Born)     [OK] |J_hyp|=%.2e\n', mean(vecnorm(J_hyp,2,2)));
if max(F_k) < 1e-3
    fprintf('  V5a max F_k      [PASS] %.6e\n', max(F_k));
else
    fprintf('  V5a max F_k      [WARN] %.6e\n', max(F_k));
end
fprintf('  Direction cos    %.6f (mean)\n', mean(cos_theta_k));
fprintf('==========================================================\n');

% Cleanup
try
    mphsave(model, fullfile(p.dir_result, 'verify_nonuniform_model.mph'));
    fprintf('\n[verify_nonuniform] model saved to results/\n');
catch
end

end
