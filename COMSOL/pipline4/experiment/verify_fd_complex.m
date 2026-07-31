function result = verify_fd_complex()
%VERIFY_FD_COMPLEX 主验证：复数 ε_r 伴随梯度 vs FD（pipline4，Gauss 积分版）
%
%   全 Gauss 积分管线:
%     F = Σ_gp w_gp |E(gp) - E*(gp)|² / Σ_gp w_gp |E*(gp)|²
%     伴随源 Je 天然体积分布，ExternalCurrentDensity FEM 组装正确匹配。
%     梯度积分使用 4-pt Gauss 规则（精确到 P1 元素二次量）。
%
%   验证流程:
%     1. 真值正演 → E_truth（Gauss 点）
%     2. 初值正演 → E_hyp（Gauss 点）
%     3. 体积伴随源 → 伴随求解 → 梯度 g_re, g_im
%     4. FD 中心差分 → FD_re, FD_im
%     5. sign 比对 + ratio 分析
%
%   用法:
%     >> setup(); verify_fd_complex();

fprintf('\n========== pipline4 FD 验证: 复数 ε_r (Gauss 积分) ==========\n');

p = config();

%% 1. COMSOL 连接 + 模型加载
fprintf('\n--- [1] COMSOL 连接 ---\n');
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);
fprintf('  模型加载: %s\n', p.comsol_model_path);

%% 2. 提取 FEM 网格
fprintf('\n--- [2] FEM 网格提取 ---\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_pos = voxel.pos(inner, :);
N_inner = sum(inner);
fprintf('  内部体素: %d\n', N_inner);
fprintf('  Gauss 点: %d\n', size(voxel.gauss_pos, 1));

%% 3. 真值正演 → E_truth (Gauss 点)
fprintf('\n--- [3] 真值正演 (ε_r = %.1f%+.1fj) ---\n', p.eps_r_true_re, p.eps_r_true_im);
voxel.epsilon_r(inner) = p.eps_r_true;
[~, ~, E_truth_gauss] = solve_forward(model, voxel, p);
fprintf('  |E_truth_gp| mean=%.4e\n', mean(vecnorm(E_truth_gauss, 2, 2)));

%% 4. 初值正演 → E_hyp (Gauss 点)
fprintf('\n--- [4] 初值正演 (ε_r = %.1f%+.1fj) ---\n', p.eps_r_init_re, p.eps_r_init_im);
voxel.epsilon_r(inner) = p.eps_r_init;
[~, ~, E_hyp_gauss] = solve_forward(model, voxel, p);
fprintf('  |E_hyp_gp| mean=%.4e\n', mean(vecnorm(E_hyp_gauss, 2, 2)));

%% 5. 体积伴随梯度（Gauss 积分，hermitian + 因子2）
fprintf('\n--- [5] 体积伴随梯度计算 (Gauss, hermitian) ---\n');
[Je, F_norm, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gauss, E_truth_gauss, p, true);
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);

if ~adj_ok
    fprintf('  ✗ 伴随求解失败！\n');
    result = struct('status', 'adjoint_failed');
    return;
end

[g, g_re, g_im] = compute_gradient(voxel, E_hyp_gauss, lambda, p, lambda_gauss);

%% 6. FD 验证（中心差分，Gauss 积分代价函数）
fprintf('\n--- [6] FD 中心差分验证 (Gauss 代价) ---\n');

% 6a. ε' FD
fd_re_results = struct('deltas', {}, 'fd_val', {}, 'sign_match', {});
for di = 1:length(p.fd_deltas_re)
    delta = p.fd_deltas_re(di);

    % ε_r = (eps_re + delta) + j*eps_im
    voxel.epsilon_r(inner) = (p.eps_r_init_re + delta) + 1j * p.eps_r_init_im;
    solve_forward(model, voxel, p);
    [E_plus_gp, ~] = read_field(model, voxel.gauss_pos);
    F_plus = compute_cost(voxel, E_plus_gp, E_truth_gauss, p, true);

    % ε_r = (eps_re - delta) + j*eps_im
    voxel.epsilon_r(inner) = (p.eps_r_init_re - delta) + 1j * p.eps_r_init_im;
    solve_forward(model, voxel, p);
    [E_minus_gp, ~] = read_field(model, voxel.gauss_pos);
    F_minus = compute_cost(voxel, E_minus_gp, E_truth_gauss, p, true);

    fd_re = (F_plus - F_minus) / (2 * delta);
    sign_match = (sign(fd_re) == sign(g_re));

    fprintf('  ε'' FD δ=%.4f: FD=%+.4e, adj=%+.4e, ratio=%.4f, sign=%s\n', ...
        delta, fd_re, g_re, g_re / fd_re, ternary(sign_match, '✓', '✗'));

    fd_re_results(di).deltas = delta;
    fd_re_results(di).fd_val = fd_re;
    fd_re_results(di).sign_match = sign_match;
end

% 6b. ε'' FD
fd_im_results = struct('deltas', {}, 'fd_val', {}, 'sign_match', {});
for di = 1:length(p.fd_deltas_im)
    delta = p.fd_deltas_im(di);

    % ε_r = eps_re + j*(eps_im + delta)
    voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im + delta);
    solve_forward(model, voxel, p);
    [E_plus_gp, ~] = read_field(model, voxel.gauss_pos);
    F_plus = compute_cost(voxel, E_plus_gp, E_truth_gauss, p, true);

    % ε_r = eps_re + j*(eps_im - delta)
    voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im - delta);
    solve_forward(model, voxel, p);
    [E_minus_gp, ~] = read_field(model, voxel.gauss_pos);
    F_minus = compute_cost(voxel, E_minus_gp, E_truth_gauss, p, true);

    fd_im = (F_plus - F_minus) / (2 * delta);
    sign_match = (sign(fd_im) == sign(g_im));

    fprintf('  ε'''' FD δ=%.4f: FD=%+.4e, adj=%+.4e, ratio=%.4f, sign=%s\n', ...
        delta, fd_im, g_im, g_im / fd_im, ternary(sign_match, '✓', '✗'));

    fd_im_results(di).deltas = delta;
    fd_im_results(di).fd_val = fd_im;
    fd_im_results(di).sign_match = sign_match;
end

%% 7. 总结报告
fprintf('\n========== 验证总结 (Gauss 积分) ==========\n');

re_sign_ok = all([fd_re_results.sign_match]);
im_sign_ok = all([fd_im_results.sign_match]);

% 用最小步长的 ratio 作为参考
ref_re = g_re / fd_re_results(end).fd_val;
ref_im = g_im / fd_im_results(end).fd_val;

fprintf('  ε'' sign: %s (%d/%d 通过)\n', ...
    ternary(re_sign_ok, '✓ PASS', '✗ FAIL'), ...
    sum([fd_re_results.sign_match]), length(fd_re_results));
fprintf('  ε'''' sign: %s (%d/%d 通过)\n', ...
    ternary(im_sign_ok, '✓ PASS', '✗ FAIL'), ...
    sum([fd_im_results.sign_match]), length(fd_im_results));
fprintf('  ε'' ratio (δ=%.4f): %.4f\n', fd_re_results(end).deltas, ref_re);
fprintf('  ε'''' ratio (δ=%.4f): %.4f\n', fd_im_results(end).deltas, ref_im);

if re_sign_ok && im_sign_ok && abs(ref_re - 1) < 0.15 && abs(ref_im - 1) < 0.15
    fprintf('\n  ★★★ ALL PASS ★★★ 伴随梯度数学正确！\n');
elseif re_sign_ok && im_sign_ok
    fprintf('\n  ✓✓ sign PASS, ratio 偏差 — 检查系数标定\n');
else
    fprintf('\n  ✗✗ sign FAIL — 需进一步诊断\n');
end

%% 8. 保存结果
result = struct();
result.g_re = g_re;
result.g_im = g_im;
result.fd_re = [fd_re_results.fd_val];
result.fd_im = [fd_im_results.fd_val];
result.ratio_re = ref_re;
result.ratio_im = ref_im;
result.re_sign_ok = re_sign_ok;
result.im_sign_ok = im_sign_ok;
result.F_norm = F_norm;
result.N_inner = N_inner;
result.N_gauss = size(voxel.gauss_pos, 1);

save(fullfile(p.dir_result, 'verify_fd_complex.mat'), 'result', '-v7.3');
fprintf('\n  结果已保存: %s\n', fullfile(p.dir_result, 'verify_fd_complex.mat'));

end

%% --- 辅助函数 ---
function s = ternary(cond, val_true, val_false)
    if cond, s = val_true; else, s = val_false; end
end
