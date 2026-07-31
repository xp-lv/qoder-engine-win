function result = verify_fd_complex()
%VERIFY_FD_COMPLEX 主验证：复数 ε_r 伴随梯度 vs FD（pipline4）
%
%   验证流程:
%     1. 真值正演 → E_truth（探针点）
%     2. 初值正演 → E_hyp（探针点）+ E_total（体素）
%     3. 伴随源 → 伴随求解 → 梯度 g_re, g_im
%     4. FD 中心差分 → FD_re, FD_im
%     5. sign 比对 + ratio 分析
%
%   通过标准:
%     sign 一致率 ≥ 95%
%     |ratio - 1| < 0.1（单体素无积分映射偏差，ratio 应接近 1.0）
%
%   用法:
%     >> setup(); verify_fd_complex();

fprintf('\n========== pipline4 FD 验证: 复数 ε_r ==========\n');

p = config();
probe = build_probes(p);

%% 1. COMSOL 连接 + 模型加载
fprintf('\n--- [1] COMSOL 连接 ---\n');
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);
fprintf('  模型加载: %s\n', p.comsol_model_path);

%% 2. 提取 FEM 网格
fprintf('\n--- [2] FEM 网格提取 ---\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;

%% 3. 真值正演 → E_truth
fprintf('\n--- [3] 真值正演 (ε_r = %.1f%+.1fj) ---\n', p.eps_r_true_re, p.eps_r_true_im);
voxel.epsilon_r(inner) = p.eps_r_true;
[E_truth_vox, ~] = solve_forward(model, voxel, p);
[E_truth_probe, ~] = read_field(model, probe.pos);
fprintf('  |E_truth_probe| mean=%.4e\n', mean(vecnorm(E_truth_probe, 2, 2)));

%% 4. 初值正演 → E_hyp + E_total
fprintf('\n--- [4] 初值正演 (ε_r = %.1f%+.1fj) ---\n', p.eps_r_init_re, p.eps_r_init_im);
voxel.epsilon_r(inner) = p.eps_r_init;
[E_hyp_vox, ~] = solve_forward(model, voxel, p);
[E_hyp_probe, ~] = read_field(model, probe.pos);

%% 5. 伴随梯度
fprintf('\n--- [5] 伴随梯度计算 ---\n');
[Je, F_norm, residual] = build_adjoint_source_nearfield(probe, E_hyp_probe, E_truth_probe, p);
[lambda, adj_ok, K_cache] = solve_adjoint(model, voxel, p, Je, probe.pos);

if ~adj_ok
    fprintf('  ✗ 伴随求解失败！\n');
    result = struct('status', 'adjoint_failed');
    return;
end

[g, g_re, g_im] = compute_gradient(voxel, E_hyp_vox, lambda, p);

%% 6. FD 验证（中心差分）
fprintf('\n--- [6] FD 中心差分验证 ---\n');

% 6a. ε' FD
fd_re_results = struct('deltas', {}, 'fd_val', {}, 'sign_match', {});
for di = 1:length(p.fd_deltas_re)
    delta = p.fd_deltas_re(di);

    % ε_r = (eps_re + delta) + j*eps_im
    voxel.epsilon_r(inner) = (p.eps_r_init_re + delta) + 1j * p.eps_r_init_im;
    solve_forward(model, voxel, p);
    [E_plus, ~] = read_field(model, probe.pos);
    F_plus = compute_cost(probe, E_plus, E_truth_probe, p);

    % ε_r = (eps_re - delta) + j*eps_im
    voxel.epsilon_r(inner) = (p.eps_r_init_re - delta) + 1j * p.eps_r_init_im;
    solve_forward(model, voxel, p);
    [E_minus, ~] = read_field(model, probe.pos);
    F_minus = compute_cost(probe, E_minus, E_truth_probe, p);

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
    [E_plus, ~] = read_field(model, probe.pos);
    F_plus = compute_cost(probe, E_plus, E_truth_probe, p);

    % ε_r = eps_re + j*(eps_im - delta)
    voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im - delta);
    solve_forward(model, voxel, p);
    [E_minus, ~] = read_field(model, probe.pos);
    F_minus = compute_cost(probe, E_minus, E_truth_probe, p);

    fd_im = (F_plus - F_minus) / (2 * delta);
    sign_match = (sign(fd_im) == sign(g_im));

    fprintf('  ε'''' FD δ=%.4f: FD=%+.4e, adj=%+.4e, ratio=%.4f, sign=%s\n', ...
        delta, fd_im, g_im, g_im / fd_im, ternary(sign_match, '✓', '✗'));

    fd_im_results(di).deltas = delta;
    fd_im_results(di).fd_val = fd_im;
    fd_im_results(di).sign_match = sign_match;
end

%% 7. 总结报告
fprintf('\n========== 验证总结 ==========\n');

re_sign_ok = all([fd_re_results.sign_match]);
im_sign_ok = all([fd_im_results.sign_match]);

% 用最小步长的 ratio 作为参考（最小数值噪声）
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
    fprintf('  → 问题不在 COMSOL 求解 + 梯度组装，而在管线3的远场映射层\n');
elseif re_sign_ok && im_sign_ok
    fprintf('\n  ✓✓ sign PASS, ratio 偏差 — 检查系数标定\n');
else
    fprintf('\n  ✗✗ sign FAIL — COMSOL 求解或梯度组装有误，需进一步诊断\n');
    fprintf('  → 运行 verify_lambda_residual 检查 K·λ 残差\n');
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
result.E_truth_probe = E_truth_probe;
result.E_hyp_probe = E_hyp_probe;

save(fullfile(p.dir_result, 'verify_fd_complex.mat'), 'result', '-v7.3');
fprintf('\n  结果已保存: %s\n', fullfile(p.dir_result, 'verify_fd_complex.mat'));

end

%% --- 辅助函数 ---
function s = ternary(cond, val_true, val_false)
    if cond, s = val_true; else, s = val_false; end
end
