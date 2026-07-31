function result = plot_gradient_scattered()
%PLOT_GRADIENT_SCATTERED Re/Im 交换 + 散射场梯度可视化
%
%   真值: ε_r = 5 - 2j（均匀）
%   初值: ε_re = 5+sin(2πx/L) ∈ [4,6], ε_im = -2+sin(2πy/L) ∈ [-3,-1]
%
%   梯度公式（FD 标定 ratio≈1）:
%     dF/dε'  = +k₀²·Im(∫ Es·λ dV)
%     dF/dε'' = +k₀²·Re(∫ Es·λ dV)
%   其中 Es = E_total - E_b（散射场，FEM DOF）

fprintf('\n========== Re/Im 交换 + 散射场梯度可视化 ==========\n');
fprintf('  真值: ε_r = 5.0 - 2.0j\n');
fprintf('  初值: ε_re ∈ [4,6] (x方向正弦), ε_im ∈ [-3,-1] (y方向正弦)\n');
fprintf('  公式: g_re=+k₀²·Im(Zs), g_im=+k₀²·Re(Zs), Es=E_total-E_b\n\n');

p = config();
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

%% 网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos_inner = voxel.pos(inner_idx, :);
L = 2 * p.R_inner;

%% 正弦初值（损耗版）
eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);   % [4, 6]
eps_im_init = -2.0 + sin(2*pi*pos_inner(:,2) / L);  % [-3, -1]
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;
fprintf('  初值 ε_re: [%.2f, %.2f]\n', min(eps_re_init), max(eps_re_init));
fprintf('  初值 ε_im: [%.2f, %.2f]\n', min(eps_im_init), max(eps_im_init));

%% 真值正演
fprintf('\n--- 真值正演 (ε=5-2j) ---\n');
voxel_truth = voxel;
voxel_truth.epsilon_r(inner_idx) = 5.0 + 1j * (-2.0);
[~, ~, E_truth_gp] = solve_forward(model, voxel_truth, p);

%% 初值正演
fprintf('\n--- 初值正演 (正弦损耗) ---\n');
[~, ~, E_hyp_gp] = solve_forward(model, voxel, p);

%% 伴随求解
fprintf('\n--- 伴随求解 ---\n');
[Je, F_norm, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
if ~adj_ok
    fprintf('  ✗ 伴随失败\n'); result = struct('status','fail'); return;
end

%% 计算散射场 Es = E_total - E_b
E_b = p.background.amplitude * p.background.polarization(:)';  % [0, 0, 1]
E_hyp_s = E_hyp_gp - repmat(E_b, size(E_hyp_gp, 1), 1);
fprintf('  |E_total| mean=%.4e, |Es| mean=%.4e\n', ...
    mean(vecnorm(E_hyp_gp,2,2)), mean(vecnorm(E_hyp_s,2,2)));

%% 逐体素梯度（Re/Im 交换 + 散射场）
k0_sq = p.k0^2;
grad_re = zeros(N_inner, 1);
grad_im = zeros(N_inner, 1);

for vi = 1:N_inner
    gr = (4*(vi-1)+1):(4*vi);
    Ev = E_hyp_s(gr, :);     % 散射场 Es
    Lv = lambda_gauss(gr, :);
    gw = voxel.gauss_weights(gr);
    Zs = 0;
    for gp = 1:4
        Zs = Zs + gw(gp) * sum(Ev(gp,:) .* Lv(gp,:));
    end
    % Re/Im 交换公式
    grad_re(vi) = +k0_sq * imag(Zs);   % dF/dε'  = +k₀²·Im(Zs)
    grad_im(vi) = +k0_sq * real(Zs);   % dF/dε'' = +k₀²·Re(Zs)
end

fprintf('\n  梯度实部 dF/dε''  范围: [%+.4e, %+.4e]\n', min(grad_re), max(grad_re));
fprintf('  梯度虚部 dF/dε'''' 范围: [%+.4e, %+.4e]\n', min(grad_im), max(grad_im));

%% FD 验证（全局均匀扰动，确认 ratio）
delta = 0.001;
fprintf('\n--- FD 验证 (δ=%.4f) ---\n', delta);
eps_re_base = eps_re_init; eps_im_base = eps_im_init;

% ε' FD
voxel.epsilon_r(inner_idx) = (eps_re_base + delta) + 1j * eps_im_base;
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
voxel.epsilon_r(inner_idx) = (eps_re_base - delta) + 1j * eps_im_base;
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
fd_re = (F_p - F_m) / (2 * delta);

% ε'' FD
voxel.epsilon_r(inner_idx) = eps_re_base + 1j * (eps_im_base + delta);
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
voxel.epsilon_r(inner_idx) = eps_re_base + 1j * (eps_im_base - delta);
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
fd_im = (F_p - F_m) / (2 * delta);

adj_re = sum(grad_re);
adj_im = sum(grad_im);
fprintf('  ε''  伴随=%+.6e  FD=%+.6e  ratio=%+.4f  sign=%s\n', ...
    adj_re, fd_re, adj_re/fd_re, t2(sign(adj_re)==sign(fd_re)));
fprintf('  ε'''' 伴随=%+.6e  FD=%+.6e  ratio=%+.4f  sign=%s\n', ...
    adj_im, fd_im, adj_im/fd_im, t2(sign(adj_im)==sign(fd_im)));

%% 绘图（4 张子图）
fprintf('\n--- 绘图 ---\n');
figure('Name', 'Re/Im交换+散射场梯度', 'Position', [100 100 1400 1000], 'Color', 'w');

x = pos_inner(:,1);
y = pos_inner(:,2);
ms = 15;

% --- 子图1: 初值 ε' ---
subplot(2, 2, 1);
scatter(x, y, ms, eps_re_init, 'filled');
axis equal tight; colorbar;
title('初值 \epsilon_r''（实部）', 'FontSize', 14);
xlabel('x [m]'); ylabel('y [m]');
colormap(gca, 'jet'); caxis([4 6]);

% --- 子图2: 初值 ε'' ---
subplot(2, 2, 2);
scatter(x, y, ms, eps_im_init, 'filled');
axis equal tight; colorbar;
title('初值 \epsilon_r''''（虚部）', 'FontSize', 14);
xlabel('x [m]'); ylabel('y [m]');
colormap(gca, 'jet'); caxis([-3 -1]);

% --- 子图3: 梯度 dF/dε' ---
subplot(2, 2, 3);
scatter(x, y, ms, grad_re, 'filled');
axis equal tight; colorbar;
title('伴随梯度 dF/d\epsilon''（=+k_0^2 Im(\int E_s\cdot\lambda)）', 'FontSize', 13);
xlabel('x [m]'); ylabel('y [m]');
colormap(gca, 'parula');

% --- 子图4: 梯度 dF/dε'' ---
subplot(2, 2, 4);
scatter(x, y, ms, grad_im, 'filled');
axis equal tight; colorbar;
title('伴随梯度 dF/d\epsilon''''（=+k_0^2 Re(\int E_s\cdot\lambda)）', 'FontSize', 13);
xlabel('x [m]'); ylabel('y [m]');
colormap(gca, 'parula');

sgtitle(['Re/Im 交换+散射场 (真值 \epsilon_r=5-2j, ' ...
    'ε'' ratio=' num2str(adj_re/fd_re,'%.2f') ...
    ', ε'''' ratio=' num2str(adj_im/fd_im,'%.2f') ')'], ...
    'FontSize', 15, 'FontWeight', 'bold');

fig_path = fullfile(p.dir_result, 'gradient_scattered.png');
saveas(gcf, fig_path);
fprintf('  图已保存: %s\n', fig_path);

%% 保存数据
result = struct();
result.eps_re_init = eps_re_init;
result.eps_im_init = eps_im_init;
result.grad_re = grad_re;
result.grad_im = grad_im;
result.fd_re = fd_re; result.fd_im = fd_im;
result.ratio_re = adj_re / fd_re;
result.ratio_im = adj_im / fd_im;
result.pos = pos_inner;

save(fullfile(p.dir_result, 'gradient_scattered.mat'), 'result', '-v7.3');
fprintf('  数据已保存\n');
end

function s = t2(c), if c, s='✓'; else, s='✗'; end, end
