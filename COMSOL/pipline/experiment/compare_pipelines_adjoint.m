function compare_pipelines_adjoint()
%COMPARE_PIPELINES_ADJOINT 对比管线1和管线2的伴随梯度
%   两条管线：R=0.06, eps_true=5, eps_init=3, 无cavity
%   输出：J_obs, lambda, g_adj 的数值对比

fprintf('\n############################################################\n');
fprintf('#  管线1 vs 管线2 伴随法对比\n');
fprintf('#  R=0.06, eps_true=5, eps_init=3\n');
fprintf('############################################################\n\n');

addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

%% ====== 管线 1 ======
fprintf('========== 管线 1 (pipline, livelink_model.mph) ==========\n');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
addpath('config','experiment','core_forward','core_jhyp','core_jobs','utils','algorithm','core_adjoint');

p1 = config();
fprintf('R_body=%.2f, R_sphere=%.2f, freq=%.0e\n', p1.a_scatter, p1.R_sphere, p1.freq);

% COMSOL
mphstart(2036);
model1 = mphload(p1.comsol_model_path);

% Mesh
voxel1 = fem_mesh_utils(model1, p1, p1.a_scatter);
inner1 = voxel1.mask_interior;
inner_idx1 = find(inner1);
N_inner1 = sum(inner1);
fprintf('N_total=%d, N_inner=%d\n', length(voxel1.epsilon_r), N_inner1);

grid1 = build_measurement_grid(p1);

% 真值正演 → J_obs
voxel1.epsilon_r(inner1) = 5.0;
voxel1.epsilon_r(~inner1) = 1.0;
solve_forward(model1, voxel1, p1);
sf1 = extract_scattered(model1, grid1);
lc1 = lightcone_project(grid1, sf1, p1);
J_obs1 = lc1.J_obs_perp;
dOmega1 = lc1.dOmega;
F_obs1 = sum(dOmega1 .* sum(abs(J_obs1).^2, 2));
if F_obs1 < 1e-60, F_obs1 = 1.0; end
fprintf('|J_obs| mean=%.6e, F_obs=%.6e\n', mean(vecnorm(J_obs1,2,2)), F_obs1);

% 初值正演 (eps=3)
voxel1.epsilon_r(inner1) = 3.0;
[E_eval1, ~, E_gauss1] = solve_forward(model1, voxel1, p1);
sf1_eval = extract_scattered(model1, grid1);
lc1_eval = lightcone_project(grid1, sf1_eval, p1);
J_hyp1 = lc1_eval.J_obs_perp;
Delta_J1 = J_obs1 - J_hyp1;
fprintf('|Delta_J| mean=%.6e\n', mean(vecnorm(Delta_J1,2,2)));

% 伴随
lc1_adj = lc1_eval;
lc1_adj.k_dir = fibonacci_sphere(p1.N_k);
lc1_adj.k_vec = p1.k0 * lc1_adj.k_dir;
lc1_adj.J_obs_perp = J_obs1;
lc1_adj.Delta_J_perp = Delta_J1;

[Js1, Ms1, sp1, ~] = build_adjoint_source_fullmaxwell(grid1, lc1_adj, p1);
[lambda1, ok1, lambda_gauss1] = solve_adjoint(model1, voxel1, p1, Js1, sp1, Ms1);
fprintf('|lambda| mean=%.6e\n', mean(vecnorm(lambda1,2,2)));

% 梯度
k0_sq1 = p1.k0^2;
g1 = zeros(N_inner1, 1);
gw1 = voxel1.gauss_w;
for vi = 1:N_inner1
    gp = (4*(vi-1)+1):(4*vi);
    gs = 0;
    for gpi = 1:4
        gs = gs + gw1(gpi) * real(sum(E_gauss1(gp(gpi),:) .* lambda_gauss1(gp(gpi),:)));
    end
    g1(vi) = -k0_sq1 * voxel1.dV(inner_idx1(vi)) * gs;
end
g1 = g1 / F_obs1;
fprintf('g_adj: min=%.6e max=%.6e mean=%.6e\n', min(g1), max(g1), mean(g1));

try ModelUtil.remove('Model'); catch, end

%% ====== 管线 2 ======
fprintf('\n========== 管线 2 (pipline_adjoint, 2layer.mph) ==========\n');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint');
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint','experiment');

p2 = config();
fprintf('R_inner=%.2f, R_sphere=%.2f, freq=%.0e\n', p2.R_inner, p2.R_sphere, p2.freq);

try mphstart(2036); catch ME; if ~contains(ME.message, 'Already connected'), rethrow(ME); end, end
model2 = mphload(p2.comsol_model_path);
try model2.geom('geom1').run; catch, end
try model2.mesh('mesh1').run; catch, end

% vec1
try model2.physics('emw').feature('vec1'); catch
    model2.physics('emw').feature().create('vec1', 'ExternalCurrentDensity', 3);
    model2.physics('emw').feature('vec1').set('Je', {'0','0','0'});
    try model2.physics('emw').feature('vec1').selection().all(); catch, end
end
try model2.param.set('adjoint_mode', '1'); catch, end

voxel2 = fem_mesh_utils(model2, p2, p2.R_inner);
inner2 = voxel2.mask_interior;
inner_idx2 = find(inner2);
N_inner2 = sum(inner2);
fprintf('N_total=%d, N_inner=%d\n', length(voxel2.epsilon_r), N_inner2);

grid2 = build_measurement_grid(p2);

% 真值正演 → J_obs
voxel2.epsilon_r(inner2) = 5.0;
update_epsilon(model2, voxel2, p2);
model2.param.set('freq', num2str(p2.freq));
try model2.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p2.freq)); catch, end
try model2.sol('sol1').clearSolutionData(); catch, end
try model2.sol('sol1').clearSolution(); catch, end
model2.sol('sol1').runAll();

sf2 = extract_scattered(model2, grid2);
lc2 = lightcone_project(grid2, sf2, p2);
J_obs2 = lc2.J_obs_perp;
dOmega2 = lc2.dOmega;
F_obs2 = sum(dOmega2 .* sum(abs(J_obs2).^2, 2));
if F_obs2 < 1e-60, F_obs2 = 1.0; end
fprintf('|J_obs| mean=%.6e, F_obs=%.6e\n', mean(vecnorm(J_obs2,2,2)), F_obs2);

% 初值正演 (eps=3)
voxel2.epsilon_r(inner2) = 3.0;
update_epsilon(model2, voxel2, p2);
[E_eval2, ~, E_gauss2] = solve_forward(model2, voxel2, p2);
sf2_eval = extract_scattered(model2, grid2);
lc2_eval = lightcone_project(grid2, sf2_eval, p2);
J_hyp2 = lc2_eval.J_obs_perp;
Delta_J2 = J_obs2 - J_hyp2;
fprintf('|Delta_J| mean=%.6e\n', mean(vecnorm(Delta_J2,2,2)));

% 伴随
lc2_adj = lc2_eval;
lc2_adj.k_dir = fibonacci_sphere(p2.N_k);
lc2_adj.k_vec = p2.k0 * lc2_adj.k_dir;
lc2_adj.J_obs_perp = J_obs2;
lc2_adj.Delta_J_perp = Delta_J2;

[Js2, Ms2, sp2, ~] = build_adjoint_source_fullmaxwell(grid2, lc2_adj, p2);
[lambda2, ok2, lambda_gauss2] = solve_adjoint(model2, voxel2, p2, Js2, sp2, Ms2);
fprintf('|lambda| mean=%.6e\n', mean(vecnorm(lambda2,2,2)));

% 梯度
k0_sq2 = p2.k0^2;
g2 = zeros(N_inner2, 1);
gw2 = voxel2.gauss_w;
for vi = 1:N_inner2
    gp = (4*(vi-1)+1):(4*vi);
    gs = 0;
    for gpi = 1:4
        gs = gs + gw2(gpi) * real(sum(E_gauss2(gp(gpi),:) .* lambda_gauss2(gp(gpi),:)));
    end
    g2(vi) = -k0_sq2 * voxel2.dV(inner_idx2(vi)) * gs;
end
g2 = g2 / F_obs2;
fprintf('g_adj: min=%.6e max=%.6e mean=%.6e\n', min(g2), max(g2), mean(g2));

try ModelUtil.remove('Model'); catch, end

%% ====== 对比 ======
fprintf('\n############################################################\n');
fprintf('#  对比汇总\n');
fprintf('############################################################\n');
fprintf('             管线1              管线2              比值\n');
fprintf('|J_obs|   %.6e      %.6e      %.4f\n', mean(vecnorm(J_obs1,2,2)), mean(vecnorm(J_obs2,2,2)), ...
    mean(vecnorm(J_obs1,2,2))/mean(vecnorm(J_obs2,2,2)));
fprintf('|Delta_J| %.6e      %.6e      %.4f\n', mean(vecnorm(Delta_J1,2,2)), mean(vecnorm(Delta_J2,2,2)), ...
    mean(vecnorm(Delta_J1,2,2))/mean(vecnorm(Delta_J2,2,2)));
fprintf('|lambda|  %.6e      %.6e      %.4f\n', mean(vecnorm(lambda1,2,2)), mean(vecnorm(lambda2,2,2)), ...
    mean(vecnorm(lambda1,2,2))/mean(vecnorm(lambda2,2,2)));
fprintf('g_mean    %.6e      %.6e      %.4f\n', mean(g1), mean(g2), mean(g1)/mean(g2));
fprintf('g_max     %.6e      %.6e      %.4f\n', max(abs(g1)), max(abs(g2)), max(abs(g1))/max(abs(g2)));
fprintf('N_inner   %d                %d\n', N_inner1, N_inner2);
fprintf('F_obs     %.6e      %.6e      %.4f\n', F_obs1, F_obs2, F_obs1/F_obs2);
fprintf('############################################################\n');

cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
