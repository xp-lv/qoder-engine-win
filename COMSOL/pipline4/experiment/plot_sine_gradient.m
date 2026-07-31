function result = plot_sine_gradient()
%PLOT_SINE_GRADIENT 非均匀正弦初值的伴随梯度可视化
%
%   真值: ε_r = 5 - 2j（均匀）
%   初值: ε_re = 5 + sin(2πx/L), ε_im = 2 + sin(2πy/L)（正弦分布）
%
%   输出 4 张图: 初值实部、初值虚部、梯度实部、梯度虚部

fprintf('\n========== pipline4 正弦初值伴随梯度可视化 ==========\n');
fprintf('  真值: ε_r = 5.0 - 2.0j (均匀)\n');
fprintf('  初值: ε_re = 5 + sin(2πx/L), ε_im = 2 + sin(2πy/L)\n\n');

p = config();

%% 1. COMSOL 连接
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

%% 2. FEM 网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('  内部体素: %d\n', N_inner);

%% 3. 设置非均匀正弦初值
pos_inner = voxel.pos(inner_idx, :);
L = 2 * p.R_inner;  % 空间周期长度

% 实部: 5 + sin(2πx/L) → 范围 [4, 6]
eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);

% 虚部: 2 + sin(2πy/L) → 范围 [1, 3] (正值)
eps_im_init = 2.0 + sin(2*pi*pos_inner(:,2) / L);

voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;

fprintf('  初值实部范围: [%.3f, %.3f]\n', min(eps_re_init), max(eps_re_init));
fprintf('  初值虚部范围: [%.3f, %.3f]\n', min(eps_im_init), max(eps_im_init));

%% 4. 真值正演 → E_truth
fprintf('\n--- 真值正演 (ε_r = 5.0-2.0j) ---\n');
voxel_truth = voxel;
voxel_truth.epsilon_r(inner_idx) = p.eps_r_true_re + 1j * (-2.0);  % 5-2j
[~, ~, E_truth_gp] = solve_forward(model, voxel_truth, p);

%% 5. 初值正演 → E_hyp
fprintf('\n--- 初值正演 (正弦分布) ---\n');
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

%% 7. 逐体素梯度计算
fprintf('\n--- 逐体素伴随梯度 ---\n');
k0_sq = p.k0^2;

grad_re_per_voxel = zeros(N_inner, 1);
grad_im_per_voxel = zeros(N_inner, 1);

for vi = 1:N_inner
    gr = (4*(vi-1)+1):(4*vi);
    Ev = E_hyp_gp(gr, :);
    Lv = lambda_gauss(gr, :);
    gw = voxel.gauss_weights(gr);

    EL_dot = 0;
    for gp = 1:4
        EL_dot = EL_dot + gw(gp) * sum(Ev(gp,:) .* Lv(gp,:));
    end

    % dF/dε' = -k₀²·Re(E·λ)
    grad_re_per_voxel(vi) = -k0_sq * real(EL_dot);
    % dF/dε'' = -k₀²·Im(E·λ)
    grad_im_per_voxel(vi) = -k0_sq * imag(EL_dot);
end

fprintf('  梯度实部范围: [%+.4e, %+.4e]\n', min(grad_re_per_voxel), max(grad_re_per_voxel));
fprintf('  梯度虚部范围: [%+.4e, %+.4e]\n', min(grad_im_per_voxel), max(grad_im_per_voxel));

%% 8. 画图（4 张子图）
fprintf('\n--- 绘图 ---\n');
figure('Name', '正弦初值伴随梯度', 'Position', [100 100 1400 1000], 'Color', 'w');

% 颜色映射用统一的 x,y 坐标
x = pos_inner(:,1);
y = pos_inner(:,2);
z = pos_inner(:,3);
marker_size = 15;

% --- 子图1: 初值 ε' (实部) ---
subplot(2, 2, 1);
scatter(x, y, marker_size, eps_re_init, 'filled');
axis equal tight;
colorbar;
title('初值 \epsilon_r''（实部）', 'FontSize', 14);
xlabel('x [m]'); ylabel('y [m]');
colormap(gca, 'jet');
caxis([4 6]);

% --- 子图2: 初值 ε'' (虚部) ---
subplot(2, 2, 2);
scatter(x, y, marker_size, eps_im_init, 'filled');
axis equal tight;
colorbar;
title('初值 \epsilon_r''''（虚部）', 'FontSize', 14);
xlabel('x [m]'); ylabel('y [m]');
colormap(gca, 'jet');
caxis([1 3]);

% --- 子图3: 梯度 dF/dε' ---
subplot(2, 2, 3);
scatter(x, y, marker_size, grad_re_per_voxel, 'filled');
axis equal tight;
colorbar;
title('伴随梯度 dF/d\epsilon''（实部）', 'FontSize', 14);
xlabel('x [m]'); ylabel('y [m]');
colormap(gca, 'parula');

% --- 子图4: 梯度 dF/dε'' ---
subplot(2, 2, 4);
scatter(x, y, marker_size, grad_im_per_voxel, 'filled');
axis equal tight;
colorbar;
title('伴随梯度 dF/d\epsilon''''（虚部）', 'FontSize', 14);
xlabel('x [m]'); ylabel('y [m]');
colormap(gca, 'parula');

sgtitle('正弦初值伴随梯度 (真值 \epsilon_r = 5-2j)', 'FontSize', 16, 'FontWeight', 'bold');

% 保存图片
fig_path = fullfile(p.dir_result, 'sine_gradient.png');
saveas(gcf, fig_path);
fprintf('  图已保存: %s\n', fig_path);

%% 9. 保存数据
result = struct();
result.eps_re_init = eps_re_init;
result.eps_im_init = eps_im_init;
result.grad_re = grad_re_per_voxel;
result.grad_im = grad_im_per_voxel;
result.pos = pos_inner;

save(fullfile(p.dir_result, 'sine_gradient.mat'), 'result', '-v7.3');
fprintf('  数据已保存\n');

end
