function result = verify_fd_10voxels()
%VERIFY_FD_10VOXELS 10 个体素的逐体素 FD 验证
%
%   每个选中体素单独扰动其 ε_r（非均匀），对比伴随梯度贡献 vs FD。
%   10 体素 × 2 分量(ε', ε'') = 20 组对比。
%
%   用法:
%     >> setup(); verify_fd_10voxels();

fprintf('\n========== pipline4 逐体素 FD 验证 (10 体素) ==========\n');
fprintf('  真值: ε_r = 5.0 - 1.0j\n');
fprintf('  初值: ε_r = 3.0 - 0.5j\n\n');

p = config();

%% 1. COMSOL 连接
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

%% 2. FEM 网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('  内部体素总数: %d\n', N_inner);

%% 3. 随机选 10 个体素
rng(42);
select_idx = randperm(N_inner, 10);
fprintf('  选中体素索引: %s\n', num2str(select_idx));

%% 4. 真值正演 → E_truth
fprintf('\n--- 真值正演 (ε_r = 5.0-1.0j) ---\n');
voxel.epsilon_r(inner) = p.eps_r_true;
[~, ~, E_truth_gp] = solve_forward(model, voxel, p);

%% 5. 初值正演 → E_hyp + 提取 E_truth/E_hyp 在选中体素
fprintf('\n--- 初值正演 (ε_r = 3.0-0.5j) ---\n');
voxel.epsilon_r(inner) = p.eps_r_init;
[~, ~, E_hyp_gp] = solve_forward(model, voxel, p);

%% 6. 伴随梯度
fprintf('\n--- 伴随求解 ---\n');
[Je, F_norm, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
if ~adj_ok
    fprintf('  ✗ 伴随求解失败！\n');
    result = struct('status', 'adjoint_failed');
    return;
end

%% 7. 逐体素 FD 验证
fprintf('\n--- 逐体素 FD 中心差分 (δ=0.01) ---\n');
delta = 0.01;

% 结果存储
fd_results = struct();

fprintf('\n');
fprintf('  =========================================================================================\n');
fprintf('  #    ε'' 伴随       ε'' FD         ratio   sign |  ε'''' 伴随      ε'''' FD        ratio   sign\n');
fprintf('  =========================================================================================\n');

for i = 1:10
    vi = select_idx(i);
    idx = inner_idx(vi);
    pos_i = voxel.pos(idx, :);

    % --- 伴随梯度贡献（该体素的 4 个 Gauss 点之和）---
    gr = (4*(vi-1)+1):(4*vi);
    Ev = E_hyp_gp(gr, :);
    Lv = lambda_gauss(gr, :);
    gw = voxel.gauss_weights(gr);

    EL_dot = 0;
    for gp = 1:4
        EL_dot = EL_dot + gw(gp) * sum(Ev(gp,:) .* Lv(gp,:));
    end

    % dF/dε' = -k₀²·Re(E·λ),  dF/dε'' = -k₀²·Im(E·λ)
    adj_re = -p.k0^2 * real(EL_dot);
    adj_im = -p.k0^2 * imag(EL_dot);

    % --- ε' FD: 仅扰动该体素，但代价函数是全局的 ---
    eps_re_base = real(voxel.epsilon_r);
    eps_im_base = imag(voxel.epsilon_r);

    % ε' + δ
    voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = (p.eps_r_init_re + delta) + 1j * p.eps_r_init_im;
    solve_forward(model, voxel, p);
    [E_p_gp, ~] = read_field(model, voxel.gauss_pos);
    F_p_re = compute_global_cost(E_p_gp, E_truth_gp, voxel.gauss_weights);

    % ε' - δ
    voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = (p.eps_r_init_re - delta) + 1j * p.eps_r_init_im;
    solve_forward(model, voxel, p);
    [E_m_gp, ~] = read_field(model, voxel.gauss_pos);
    F_m_re = compute_global_cost(E_m_gp, E_truth_gp, voxel.gauss_weights);

    fd_re = (F_p_re - F_m_re) / (2 * delta);
    ratio_re = adj_re / fd_re;
    sign_re = sign(fd_re) == sign(adj_re);

    % --- ε'' FD: 仅扰动该体素 ---
    % ε'' + δ
    voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = p.eps_r_init_re + 1j * (p.eps_r_init_im + delta);
    solve_forward(model, voxel, p);
    [E_p_gp, ~] = read_field(model, voxel.gauss_pos);
    F_p_im = compute_global_cost(E_p_gp, E_truth_gp, voxel.gauss_weights);

    % ε'' - δ
    voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = p.eps_r_init_re + 1j * (p.eps_r_init_im - delta);
    solve_forward(model, voxel, p);
    [E_m_gp, ~] = read_field(model, voxel.gauss_pos);
    F_m_im = compute_global_cost(E_m_gp, E_truth_gp, voxel.gauss_weights);

    fd_im = (F_p_im - F_m_im) / (2 * delta);
    ratio_im = adj_im / fd_im;
    sign_im = sign(fd_im) == sign(adj_im);

    % 存储
    fd_results(i).vi = vi;
    fd_results(i).pos = pos_i;
    fd_results(i).adj_re = adj_re;
    fd_results(i).adj_im = adj_im;
    fd_results(i).fd_re = fd_re;
    fd_results(i).fd_im = fd_im;
    fd_results(i).ratio_re = ratio_re;
    fd_results(i).ratio_im = ratio_im;
    fd_results(i).sign_re = sign_re;
    fd_results(i).sign_im = sign_im;

    fprintf('  %2d  %+10.3e  %+10.3e  %7.3f  %s   |  %+10.3e  %+10.3e  %7.3f  %s\n', ...
        i, adj_re, fd_re, ratio_re, ternary(sign_re,'✓','✗'), ...
           adj_im, fd_im, ratio_im, ternary(sign_im,'✓','✗'));
end

fprintf('  =========================================================================================\n');

%% 8. 总结
re_signs = [fd_results.sign_re];
im_signs = [fd_results.sign_im];
re_ratios = [fd_results.ratio_re];
im_ratios = [fd_results.ratio_im];

fprintf('\n========== 逐体素总结 ==========\n');
fprintf('  真值 ε_r = %.1f %+.1fj\n', p.eps_r_true_re, p.eps_r_true_im);
fprintf('  初值 ε_r = %.1f %+.1fj\n', p.eps_r_init_re, p.eps_r_init_im);
fprintf('  FD 步长 δ = %.4f\n', delta);
fprintf('  体素数: 10 (种子=42)\n\n');

fprintf('  ε''  sign: %d/10 通过, ratio: mean=%.3f, std=%.3f, range=[%.3f, %.3f]\n', ...
    sum(re_signs), mean(re_ratios), std(re_ratios), min(re_ratios), max(re_ratios));
fprintf('  ε'''' sign: %d/10 通过, ratio: mean=%.3f, std=%.3f, range=[%.3f, %.3f]\n', ...
    sum(im_signs), mean(im_ratios), std(im_ratios), min(im_ratios), max(im_ratios));

if all(re_signs) && all(im_signs)
    fprintf('\n  ★★★ sign 20/20 PASS ★★★\n');
else
    fprintf('\n  sign FAIL: ε'' %d/10, ε'''' %d/10\n', sum(re_signs), sum(im_signs));
end

%% 9. 体素坐标
fprintf('\n--- 体素坐标 ---\n');
fprintf('  #   x(m)     y(m)     z(m)     dV(m³)\n');
for i = 1:10
    fprintf('  %2d  %+.4f  %+.4f  %+.4f  %.3e\n', ...
        i, fd_results(i).pos(1), fd_results(i).pos(2), fd_results(i).pos(3), ...
        voxel.dV(inner_idx(fd_results(i).vi)));
end

%% 10. 保存
result = struct();
result.delta = delta;
result.fd_results = fd_results;
result.re_sign_pass = sum(re_signs);
result.im_sign_pass = sum(im_signs);
result.re_ratios = re_ratios;
result.im_ratios = im_ratios;
result.eps_true = p.eps_r_true;
result.eps_init = p.eps_r_init;

save(fullfile(p.dir_result, 'verify_fd_10voxels.mat'), 'result', '-v7.3');
fprintf('\n  结果已保存\n');

end

%% --- 全局代价函数 ---
function F = compute_global_cost(E_hyp_gp, E_truth_gp, gw)
%compute_global_cost 全局 Gauss 积分代价函数
%   F = Σ_all w_i |E_i - E*_i|² / Σ_all w_i |E*_i|²
%
%   FD 使用全局代价（非局部），因为体素 i 的 ε_r 扰动会通过
%   电磁场全局耦合影响所有位置的 E 场。伴随梯度 dF/dε_i =
%   -k₀²·∫_{V_i} E·λ dV 对应的就是全局 F 对 ε_i 的偏导。
residual = E_hyp_gp - E_truth_gp;
F_norm = sum(gw .* sum(abs(E_truth_gp).^2, 2));
if F_norm < 1e-60, F_norm = 1; end
F = sum(gw .* sum(abs(residual).^2, 2)) / F_norm;
end

function s = ternary(cond, val_true, val_false)
    if cond, s = val_true; else, s = val_false; end
end
