function result = verify_adjoint(eps_r_test_list)
%VERIFY_ADJOINT 多测试点 FD vs 伴随验证 + coeff_base 自动标定
%
%   ★ 伴随法验证 Layer 2 完整版：多 eps_r 测试点 + CV 统计 ★
%
%   在多个 eps_r 值上分别做 FD vs 伴随对比，验证 ratio 一致性：
%     - ratio 全局常数（CV < 0.1）→ 算子结构正确
%     - coeff_base = mean(g_adj / g_FD) → 标量系数标定
%     - 凸区域方向：g·(eps_true - eps_init) > 0
%
%   用法：
%     >> verify_adjoint()                        % 默认 [2, 3, 4, 5, 6]
%     >> verify_adjoint([3, 4, 5])              % 指定测试点
%     >> result = verify_adjoint([2, 4, 6]);

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

if nargin < 1 || isempty(eps_r_test_list)
    eps_r_test_list = [3.0, 4.0, 5.0, 6.0];
end
N_test = length(eps_r_test_list);

fprintf('\n############################################################\n');
fprintf('#  多测试点 FD vs 伴随验证（%d 点）\n', N_test);
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid = build_measurement_grid(p);

fprintf('[VA] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[VA] [FAIL] mphstart: %s\n', ME.message); return;
    end
end

fprintf('[VA] 构建 2 层极简模型...\n');
model = build_lightweight_model(p);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);

%% 2. 预计算 J_obs（真值）
fprintf('[VA] 预计算 J_obs（真值 eps_r=%.1f）...\n', p.eps_r_true);
voxel_truth = voxel;
voxel_truth.epsilon_r(inner) = p.eps_r_true;
update_epsilon(model, voxel_truth, p);
solve_forward_quiet(model, voxel_truth, p);
sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
J_obs_safe = max(sum(abs(J_obs).^2, 2), 1e-12);

%% 3. 逐测试点 FD + 伴随
g_FD_all = zeros(N_test, 1);
g_adj_all = zeros(N_test, 1);

for ti = 1:N_test
    eps_r_test = eps_r_test_list(ti);
    fprintf('\n[VA] ===== 测试点 %d/%d: eps_r=%.2f =====\n', ti, N_test, eps_r_test);

    % --- 正演 ---
    voxel.epsilon_r(inner) = eps_r_test;
    update_epsilon(model, voxel, p);
    [E_total, ~, E_gauss] = solve_forward(model, voxel, p);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, p);
    Delta_J = J_obs - lc.J_obs_perp;

    % --- 伴随梯度 ---
    lc.k_vec = p.k0 * lc.k_dir;
    lc.J_obs_perp = J_obs;
    lc.Delta_J_perp = Delta_J ./ J_obs_safe;

    [Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);
    [lambda, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);

    if ~adj_ok
        fprintf('[VA] [FAIL] eps_r=%.2f 伴随求解失败，跳过\n', eps_r_test);
        continue;
    end

    % bilinear 体素梯度
    k0_sq = p.k0^2;
    g_voxel = zeros(N_inner, 1);
    for vi = 1:N_inner
        g_voxel(vi) = -k0_sq * voxel.dV(inner_idx(vi)) * real(sum(E_total(vi,:) .* lambda(vi,:)));
    end
    g_adj = sum(g_voxel);
    g_adj_all(ti) = g_adj;

    % --- FD 梯度 ---
    delta_fd = 0.001;
    % F+
    voxel.epsilon_r(inner) = eps_r_test + delta_fd;
    update_epsilon(model, voxel, p);
    solve_forward_quiet(model, voxel, p);
    sf_p = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf_p, p);
    F_plus = mean(sum(abs(J_obs - lc_p.J_obs_perp).^2, 2) ./ J_obs_safe / 6);

    % F-
    voxel.epsilon_r(inner) = eps_r_test - delta_fd;
    update_epsilon(model, voxel, p);
    solve_forward_quiet(model, voxel, p);
    sf_m = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf_m, p);
    F_minus = mean(sum(abs(J_obs - lc_m.J_obs_perp).^2, 2) ./ J_obs_safe / 6);

    g_FD = (F_plus - F_minus) / (2 * delta_fd);
    g_FD_all(ti) = g_FD;

    ratio_i = g_adj / g_FD;
    fprintf('  g_FD=%+.6e, g_adj=%+.6e, ratio=%.6f\n', g_FD, g_adj, real(ratio_i));
end

%% 4. 统计分析
fprintf('\n############################################################\n');
fprintf('#  多测试点统计\n');
fprintf('############################################################\n');
fprintf('#  %-8s  %14s  %14s  %10s\n', 'eps_r', 'g_FD', 'g_adjoint', 'ratio');
fprintf('#  %-8s  %14s  %14s  %10s\n', '--------', '--------------', '--------------', '----------');

ratios = zeros(N_test, 1);
for ti = 1:N_test
    if g_FD_all(ti) ~= 0
        ratios(ti) = g_adj_all(ti) / g_FD_all(ti);
        fprintf('#  %-8.2f  %+14.6e  %+14.6e  %10.6f\n', ...
            eps_r_test_list(ti), g_FD_all(ti), g_adj_all(ti), ratios(ti));
    end
end

% 排除零值
valid = ratios ~= 0;
ratios_valid = ratios(valid);

if length(ratios_valid) >= 2
    ratio_mean = mean(ratios_valid);
    ratio_std = std(ratios_valid);
    ratio_cv = ratio_std / abs(ratio_mean);

    fprintf('#\n#  ratio mean = %.6f\n', ratio_mean);
    fprintf('#  ratio std  = %.6f\n', ratio_std);
    fprintf('#  ratio CV   = %.6f\n', ratio_cv);
    fprintf('#  coeff_base_rec = %.6f（建议标定值）\n', ratio_mean);

    fprintf('#\n#  判定:\n');
    if ratio_cv < 0.1 && abs(ratio_mean - 1) < 0.05
        fprintf('#    ★★★ PASS: ratio 全局常数（CV=%.4f < 0.1），幅度精确 ★★★\n', ratio_cv);
    elseif ratio_cv < 0.1
        fprintf('#    方向正确（CV=%.4f），需标定 coeff_base = %.4f\n', ratio_cv, ratio_mean);
    else
        fprintf('#    ⚠ ratio 不一致（CV=%.4f ≥ 0.1）→ 存在结构性错误\n', ratio_cv);
    end
else
    fprintf('#\n#  有效测试点不足，无法统计\n');
end

% 凸区域方向
dp_true = p.eps_r_true - p.eps_r_init;
dot_val = dot(g_adj_all, ones(N_test,1) * dp_true);
fprintf('#\n#  凸区域方向: g·(eps_true - eps_init) = %+.6e', dot_val);
if dot_val > 0
    fprintf(' → ★ 正确（梯度指向真值方向）★\n');
else
    fprintf(' → ⚠ 反向\n');
end
fprintf('############################################################\n');

%% 5. 保存
result = struct();
result.eps_r_test = eps_r_test_list;
result.g_FD = g_FD_all;
result.g_adjoint = g_adj_all;
result.ratios = ratios;
result.ratio_mean = ratio_mean;
result.ratio_cv = ratio_cv;
result.coeff_base_rec = ratio_mean;

save(fullfile(p.dir_result, 'verify_adjoint_result.mat'), 'result');
fprintf('\n结果已保存: data/results/verify_adjoint_result.mat\n');

end

%% ====== 辅助函数 ======
function solve_forward_quiet(model, voxel, p)
try
    model.param.set('freq', num2str(p.freq));
    try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
catch
end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
try
    s1 = model.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch, s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso'); end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end
model.sol('sol1').runAll();
end
