function diagnose_v2_fd()
%DIAGNOSE_V2_FD 两次求解法 FD 验证（setup_exact_adjoint_v2）
%
%   对比 v1（n_hat x 近似）和 v2（两次求解法）的 FD 对齐情况

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), ...
        fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), ...
        fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), ...
        fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), ...
        fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  V2 两次求解法 FD 验证\n');
fprintf('############################################################\n\n');

%% 初始化
p = config();
grid = build_measurement_grid(p);

fprintf('[V2] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[V2] [FAIL] mphstart: %s\n', ME.message); return;
    end
end
fprintf('[V2] 加载模型...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

R_scatter = p.a_scatter;
voxel = fem_mesh_utils(model, p, R_scatter);

%% 测试点 t=0.5
eps_r_test = 4.0;
hole_pos_test = [0.015; 0.010; 0.005];
R_hole = 0.03;
N_freq = 1; freqs = [1.0e9];
delta_sdf = 0.008;
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);
p_init = [3.0; 0; 0; 0];
p_true_vec = [5.0; 0.03; 0.02; 0.01];
dp_true = p_true_vec - p_init;

%% 预计算 J_obs
fprintf('[V2] 预计算 J_obs...\n');
voxel_truth = voxel;
eps_r_true_val = 5.0; hole_pos_true = [0.03; 0.02; 0.01];
d_true = sqrt(sum((inner_pos - hole_pos_true').^2, 2));
voxel_truth.epsilon_r(inner_mask) = eps_r_true_val + (1.0 - eps_r_true_val) * 0.5 * (1 - tanh(d_true / delta_sdf));
update_epsilon(model, voxel_truth, p);

J_obs_multi = cell(1, N_freq);
for fi = 1:N_freq
    pf = p; pf.freq=freqs(fi); pf.omega=2*pi*pf.freq;
    pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
    model.param.set('freq', num2str(pf.freq));
    try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', pf.freq)); catch, end
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end
    model.sol('sol1').runAll();
    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, pf);
    J_obs_multi{fi} = lc_obs.J_obs_perp;
end

%% FD 梯度
fprintf('\n[V2] 计算 central FD 梯度...\n');
delta_eps_r = 0.01; delta_hole = 1e-3;
params_0 = [eps_r_test; hole_pos_test]; N_param = 4;
g_FD = zeros(N_param, 1);

for i = 1:N_param
    dp = zeros(N_param,1);
    if i==1, dp(i)=delta_eps_r; else, dp(i)=delta_hole; end
    for sign = [+1, -1]
        pt = params_0 + sign*dp;
        er = pt(1); hp = pt(2:4);
        d_p = sqrt(sum((inner_pos - hp').^2, 2));
        voxel.epsilon_r(inner_mask) = er + (1.0-er)*0.5*(1-tanh(d_p/delta_sdf));
        update_epsilon(model, voxel, p);
        pf = p; pf.freq=freqs(1); pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
        solve_forward(model, voxel, pf);
        sf = extract_scattered(model, grid);
        lc_p = lightcone_project(grid, sf, pf);
        dJ = J_obs_multi{1} - lc_p.J_obs_perp;
        Jo = sum(abs(J_obs_multi{1}).^2,2); Jos = max(Jo,1e-12);
        F_val = mean(sum(abs(dJ).^2,2) ./ Jos / 6);
        if sign==+1, F_plus=F_val; else, F_minus=F_val; end
    end
    g_FD(i) = (F_plus - F_minus) / (2*dp(i));
    fprintf('[V2]   FD g_%d = %.6e\n', i, g_FD(i));
end

%% V2 伴随梯度
fprintf('\n[V2] 计算 V2 伴随梯度（两次求解法）...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0 - eps_r_test) * 0.5 * (1 - tanh(d_test / delta_sdf));
update_epsilon(model, voxel, p);

pf = p; pf.freq=freqs(1); pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);
sf = extract_scattered(model, grid);
lc_new = lightcone_project(grid, sf, pf);
J_hyp = lc_new.J_obs_perp;
J_obs_fi = J_obs_multi{1};
Delta_J = J_obs_fi - J_hyp;
J_obs_sq = sum(abs(J_obs_fi).^2, 2);
J_obs_safe = max(J_obs_sq, 1e-12);
lc_new.k_vec = pf.k0 * lc_new.k_dir;
lc_new.J_obs_perp = J_obs_fi;
lc_new.Delta_J_perp = Delta_J ./ J_obs_safe;

fprintf('[V2] 调用 setup_exact_adjoint_v2...\n');
[lambda_exact, adj_ok, lambda_gauss] = setup_exact_adjoint_v2(model, voxel, grid, lc_new, pf);

if ~adj_ok
    fprintf('[V2] [FAIL] V2 伴随求解失败\n');
    return;
end

fprintf('[V2] lambda_exact: %d voxels, |mean|=%.4e\n', ...
    size(lambda_exact,1), mean(vecnorm(lambda_exact,2,2)));

%% 链式法则 g_voxel → g_param
N_inner = sum(inner_mask);
inner_idx = find(inner_mask);
k0_sq = pf.k0^2; dV_vec = voxel.dV;
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && size(E_gauss,1)==size(voxel.gauss_pos,1) ...
    && size(lambda_gauss,1)==size(voxel.gauss_pos,1);
if ~use_gauss
    fprintf('[V2] Gauss dim mismatch (E=%d, lambda=%d, gauss_pos=%d), using centroid\n', ...
        size(E_gauss,1), size(lambda_gauss,1), size(voxel.gauss_pos,1));
end
gauss_w = voxel.gauss_w;

g_voxel = zeros(N_inner, 1);
if use_gauss
    for vi = 1:N_inner
        v_idx = inner_idx(vi);
        gp = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gauss_w(gpi) * dot(E_gauss(gp(gpi),:), lambda_gauss(gp(gpi),:));
        end
        g_voxel(vi) = -k0_sq * dV_vec(v_idx) * real(gs) / N_freq;
    end
else
    for vi = 1:N_inner
        v_idx = inner_idx(vi);
        g_voxel(vi) = -k0_sq * dV_vec(v_idx) * real(dot(E_total(vi,:), lambda_exact(vi,:))) / N_freq;
    end
end

g_adjoint = zeros(N_param, 1);
dE_deps = 0.5 * (1 + tanh(sqrt(sum((inner_pos - hole_pos_test').^2, 2)) / delta_sdf));
g_adjoint(1) = sum(g_voxel .* dE_deps);
for j = 1:3
    diff = inner_pos - hole_pos_test';
    d_v = sqrt(sum(diff.^2, 2));
    sech2 = 1 ./ cosh(d_v / delta_sdf).^2;
    deps_dd = -(1 - eps_r_test) * 0.5 * sech2 / delta_sdf;
    dd_dhole = -diff(:, j) ./ (d_v + 1e-30);
    dE_dhole_j = deps_dd .* dd_dhole;
    g_adjoint(1+j) = sum(g_voxel .* dE_dhole_j);
end

%% 对比输出
fprintf('\n========== V2 FD 对比结果 ==========\n');
fprintf('  g_FD size=%s, g_adjoint size=%s\n', mat2str(size(g_FD)), mat2str(size(g_adjoint)));
fprintf('| 参数      | g_FD         | g_adjoint    | ratio  | sign |\n');
fprintf('|-----------|--------------|--------------|--------|------|\n');
names = {'eps_r','hole_x','hole_y','hole_z'};
for i = 1:N_param
    if abs(g_FD(i)) > 1e-30
        ri = g_adjoint(i) / g_FD(i);
    else
        ri = NaN;
    end
    sg = sign(real(g_FD(i)) * real(g_adjoint(i)));
    fprintf('| %-9s | %.4e | %.4e | %8.4f | %+d |\n', ...
        names{i}, real(g_FD(i)), real(g_adjoint(i)), real(ri), sg);
end

cos_vec = dot(g_FD, g_adjoint) / (norm(g_FD) * norm(g_adjoint));
fprintf('\n向量 cos(g_FD, g_adjoint) = %.6f\n', cos_vec);

% 凸区域判据
gFD_dot_dp = dot(g_FD, dp_true);
gAdj_dot_dp = dot(g_adjoint, dp_true);
fprintf('g_FD·dp     = %+.4e %s\n', gFD_dot_dp, pass_str(gFD_dot_dp>0));
fprintf('g_adjoint·dp = %+.4e %s\n', gAdj_dot_dp, pass_str(gAdj_dot_dp>0));

% ratio 统计
ratios = g_adjoint ./ g_FD;
ratios_valid = ratios(isfinite(ratios) & abs(g_FD)>1e-20);
if ~isempty(ratios_valid)
    fprintf('\nratio mean=%.4f, std=%.4f, CV=%.4f\n', ...
        mean(ratios_valid), std(ratios_valid), std(ratios_valid)/abs(mean(ratios_valid)));
end

fprintf('\n========== V1 vs V2 对比 ==========\n');
fprintf('| 版本 | cos       | hole_x sign | ratio CV  |\n');
fprintf('|------|-----------|-------------|-----------|\n');
fprintf('| V1   |   0.983   |     -1      |    ~1.5   |\n');
fprintf('| V2   |  %.4f   |     %+d      |    %.3f   |\n', ...
    cos_vec, sign(g_FD(2)*g_adjoint(2)), ...
    ternary(~isempty(ratios_valid), std(ratios_valid)/abs(mean(ratios_valid)), 999));

fprintf('\n############################################################\n');
if cos_vec > 0.95
    fprintf('  ★★★ V2 验证通过 (cos=%.4f > 0.95) ★★★\n', cos_vec);
else
    fprintf('  [FAIL] V2 cos=%.4f < 0.95，仍需改进\n', cos_vec);
end
fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir, 'dir'), mkdir(results_dir); end
save(fullfile(results_dir, 'v2_fd_result.mat'), 'g_FD', 'g_adjoint', 'cos_vec');

end

function s = pass_str(cond)
    if cond, s='[PASS]'; else, s='[FAIL]'; end
end

function v = ternary(cond, a, b)
    if cond, v=a; else, v=b; end
end
