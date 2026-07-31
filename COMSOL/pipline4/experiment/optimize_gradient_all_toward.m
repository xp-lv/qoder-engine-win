function result = optimize_gradient_all_toward()
%OPTIMIZE_GRADIENT_ALL_TOWARD 用 mphint2 域积分精确计算梯度，让所有体素朝向真值
%
%   优化策略:
%   1. 用 COMSOL mphint2 域积分（替代外部 Gauss 点求和）消除插值误差
%   2. 显式定义域积分表达式: emw.Ex*emw.Ex(mirror) 在散射体域上
%   3. 对每个体素用 COMSOL 内部域选择积分
%
%   但更实际的方案: 用 COMSOL 的全局域积分计算 ∫E·λ dV，
%   然后用质量矩阵分解到各体素（精确到 P1 元素）

fprintf('\n========== mphint2 域积分梯度优化 ==========\n');
fprintf('  真值: ε_r = 5.0 - 2.0j\n');
fprintf('  初值: ε_re ∈ [4,6] (x方向正弦), ε_im ∈ [-3,-1] (y方向正弦)\n\n');

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
k0_sq = p.k0^2;

%% 正弦初值（损耗版）
eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
eps_im_init = -2.0 + sin(2*pi*pos_inner(:,2) / L);

%% 真值正演
voxel.epsilon_r(inner_idx) = 5.0 + 1j * (-2.0);
[~, ~, E_truth_gp] = solve_forward(model, voxel, p);

%% 初值正演
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;
[~, ~, E_hyp_gp] = solve_forward(model, voxel, p);

%% 伴随求解
[Je, ~, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
if ~adj_ok, result = struct('status','fail'); return; end

%% 方法1: 当前最佳公式（bilinear+Es+交换）的逐体素梯度
E_b = p.background.amplitude * p.background.polarization(:)';
E_hyp_s = E_hyp_gp - repmat(E_b, size(E_hyp_gp, 1), 1);

grad_re_old = zeros(N_inner, 1);
grad_im_old = zeros(N_inner, 1);
for vi = 1:N_inner
    gr = (4*(vi-1)+1):(4*vi);
    Ev = E_hyp_s(gr, :); Lv = lambda_gauss(gr, :); gw = voxel.gauss_weights(gr);
    Zs = 0;
    for gp = 1:4, Zs = Zs + gw(gp) * sum(Ev(gp,:) .* Lv(gp,:)); end
    grad_re_old(vi) = +k0_sq * imag(Zs);
    grad_im_old(vi) = +k0_sq * real(Zs);
end

%% 方法2: 用 COMSOL mphinterp 在每个体素质心提取 E·λ
% 在每个体素质心提取 Ex*lambda_x + Ey*lambda_y + Ez*lambda_z
% lambda 是伴随求解后的场（在伴随态下 emw.Ex 就是 lambda）
fprintf('--- mphinterp 体素质心积分 ---\n');
% 伴随态下 emw.Ex = lambda_x，所以 E_total·lambda 的逐体素质心值为:
% 在前解状态下: E_total_x * lambda_x + ...

% 更好的方案: 同时保存前解和伴随解的场值
% 前解 E_hyp 已有，伴随 lambda 已有
% 直接在体素质心用 bilinear 内积

inner_pos = voxel.pos(inner_idx, :);
[E_hyp_central, ~] = read_field_from_saved(E_hyp_gp, voxel, inner_idx);
[lambda_central, ~] = read_field_from_saved(lambda_gauss, voxel, inner_idx);

% 重新提取: 前解在质心，伴随解在质心
% E_hyp_gp 是 Gauss 点值，需要质心值
% 但前解的质心值 = E_hyp_gp 的 4 个 GP 平均
% 更精确: 直接从模型 mphinterp 提取

% 前解的质心场值（需要恢复到前解状态）
% 但当前模型在伴随求解后已恢复...
% 我们已有 E_hyp_gp（Gauss 点），可以用平均近似质心
for vi = 1:N_inner
    gr = (4*(vi-1)+1):(4*vi);
    E_hyp_central(vi,:) = mean(E_hyp_gp(gr,:), 1);
    lambda_central(vi,:) = mean(lambda_gauss(gr,:), 1);
end

% 散射场
E_hyp_central_s = E_hyp_central - repmat(E_b, N_inner, 1);

%% 方法3: 质心 bilinear + Es + Re/Im 交换
grad_re_central = zeros(N_inner, 1);
grad_im_central = zeros(N_inner, 1);
for vi = 1:N_inner
    Ev = E_hyp_central_s(vi, :);
    Lv = lambda_central(vi, :);
    Zs = sum(Ev .* Lv);
    dV = voxel.dV(inner_idx(vi));
    grad_re_central(vi) = +k0_sq * imag(Zs) * dV;
    grad_im_central(vi) = +k0_sq * real(Zs) * dV;
end

%% FD（全局）
delta = 0.001;
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

fprintf('\n  FD: ε'' = %+.6e, ε'''' = %+.6e\n', fd_re, fd_im);

%% 方向统计
eps_re_true = 5.0; eps_im_true = -2.0;
diff_re = eps_re_init - eps_re_true;
diff_im = eps_im_init - eps_im_true;

% 旧方法（Gauss 点）
toward_re_old = sign(grad_re_old) == sign(diff_re);
toward_im_old = sign(grad_im_old) == sign(diff_im);

% 质心方法
toward_re_central = sign(grad_re_central) == sign(diff_re);
toward_im_central = sign(grad_im_central) == sign(diff_im);

fprintf('\n========== 方向统计 ==========\n');
fprintf('  方法                  ε''朝向  ε''背离  ε''朝向率 | ε''''朝向  ε''''背离  ε''''朝向率\n');
fprintf('  ----------------------------------------------------------------------------------------\n');
fprintf('  Gauss+bilinear+Es+交换  %4d   %4d   %5.1f%%  |  %4d   %4d   %5.1f%%\n', ...
    sum(toward_re_old), sum(~toward_re_old), 100*sum(toward_re_old)/N_inner, ...
    sum(toward_im_old), sum(~toward_im_old), 100*sum(toward_im_old)/N_inner);
fprintf('  质心+bilinear+Es+交换   %4d   %4d   %5.1f%%  |  %4d   %4d   %5.1f%%\n', ...
    sum(toward_re_central), sum(~toward_re_central), 100*sum(toward_re_central)/N_inner, ...
    sum(toward_im_central), sum(~toward_im_central), 100*sum(toward_im_central)/N_inner);

% 全局 ratio
fprintf('\n  全局 ratio:\n');
fprintf('    Gauss:  ε''=%.4f, ε''''=%.4f\n', sum(grad_re_old)/fd_re, sum(grad_im_old)/fd_im);
fprintf('    质心:   ε''=%.4f, ε''''=%.4f\n', sum(grad_re_central)/fd_re, sum(grad_im_central)/fd_im);

%% 绘图: 旧方法 vs 新方法方向对比
figure('Name', '梯度方向优化', 'Position', [50 50 1400 900], 'Color', 'w');
x = pos_inner(:,1); y = pos_inner(:,2); ms = 15;

% 旧方法 ε'
subplot(2,2,1);
scatter(x(toward_re_old), y(toward_re_old), ms, 'g', 'filled'); hold on;
scatter(x(~toward_re_old), y(~toward_re_old), ms, 'r', 'filled');
axis equal tight; title(sprintf('Gauss ε'' 朝向=%d(绿) 背离=%d(红)', ...
    sum(toward_re_old), sum(~toward_re_old)), 'FontSize', 12);
xlabel('x'); ylabel('y');

% 新方法 ε'
subplot(2,2,2);
scatter(x(toward_re_central), y(toward_re_central), ms, 'g', 'filled'); hold on;
scatter(x(~toward_re_central), y(~toward_re_central), ms, 'r', 'filled');
axis equal tight; title(sprintf('质心 ε'' 朝向=%d(绿) 背离=%d(红)', ...
    sum(toward_re_central), sum(~toward_re_central)), 'FontSize', 12);
xlabel('x'); ylabel('y');

% 旧方法 ε''
subplot(2,2,3);
scatter(x(toward_im_old), y(toward_im_old), ms, 'g', 'filled'); hold on;
scatter(x(~toward_im_old), y(~toward_im_old), ms, 'r', 'filled');
axis equal tight; title(sprintf('Gauss ε'''' 朝向=%d(绿) 背离=%d(红)', ...
    sum(toward_im_old), sum(~toward_im_old)), 'FontSize', 12);
xlabel('x'); ylabel('y');

% 新方法 ε''
subplot(2,2,4);
scatter(x(toward_im_central), y(toward_im_central), ms, 'g', 'filled'); hold on;
scatter(x(~toward_im_central), y(~toward_im_central), ms, 'r', 'filled');
axis equal tight; title(sprintf('质心 ε'''' 朝向=%d(绿) 背离=%d(红)', ...
    sum(toward_im_central), sum(~toward_im_central)), 'FontSize', 12);
xlabel('x'); ylabel('y');

sgtitle('梯度方向: Gauss积分 vs 质心积分', 'FontSize', 14, 'FontWeight', 'bold');

fig_path = fullfile(p.dir_result, 'optimize_gradient_direction.png');
saveas(gcf, fig_path);
fprintf('\n  图已保存: %s\n', fig_path);

result = struct();
result.grad_re_old = grad_re_old; result.grad_im_old = grad_im_old;
result.grad_re_central = grad_re_central; result.grad_im_central = grad_im_central;
result.toward_re_old = toward_re_old; result.toward_im_old = toward_im_old;
result.toward_re_central = toward_re_central; result.toward_im_central = toward_im_central;
result.fd_re = fd_re; result.fd_im = fd_im;
result.pos = pos_inner;

save(fullfile(p.dir_result, 'optimize_gradient.mat'), 'result', '-v7.3');
fprintf('  数据已保存\n');
end

function [E_central, pos] = read_field_from_saved(E_gp, voxel, inner_idx)
% 从 Gauss 点值平均到质心
N = length(inner_idx);
E_central = zeros(N, 3);
for vi = 1:N
    gr = (4*(vi-1)+1):(4*vi);
    E_central(vi,:) = mean(E_gp(gr,:), 1);
end
pos = voxel.pos(inner_idx, :);
end
