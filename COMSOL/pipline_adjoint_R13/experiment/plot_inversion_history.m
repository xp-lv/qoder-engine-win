function plot_inversion_history(state_file)
%PLOT_INVERSION_HISTORY 逐轮可视化反演过程的 eps_r + 梯度 + FD 方向验证
%
%   对每轮输出：
%     - eps_r 3D 点云（颜色映射）
%     - 伴随梯度 3D 点云（对称色标）
%     - eps_r > 8 的"过冲点" FD 方向验证
%
%   用法：
%     >> plot_inversion_history('data/results/inversion_state.mat')

if nargin < 1, state_file = 'data/results/inversion_state.mat'; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);

data = load(fullfile(pipline_dir, state_file));
s = data.state;
N_iter = length(s.history_F);
pos = s.pos;  % [N_inner x 3]
N = size(pos, 1);

fprintf('加载: %s, %d 轮, N=%d\n', state_file, N_iter, N);

%% 每轮绘图
for iter = 1:N_iter
    eps_r = s.history_eps{iter};
    grad = s.history_grad{iter};
    if isempty(grad)
        fprintf('  (iter %d 梯度未保存，跳过梯度图)\n', iter);
        grad = zeros(N, 1);
    end
    F = s.history_F(iter);
    
    fprintf('\n=== iter %d: F=%.4e, eps mean=%.3f, range=[%.2f, %.2f] ===\n', ...
        iter, F, mean(eps_r), min(eps_r), max(eps_r));
    
    figure('Position', [50, 50, 1400, 450], 'Color', 'w', 'Name', sprintf('iter %d', iter));
    
    % 子图1: eps_r 3D
    subplot(1, 3, 1);
    scatter3(pos(:,1)*1000, pos(:,2)*1000, pos(:,3)*1000, 15, eps_r, 'filled');
    colorbar; colormap(jet); caxis([1, 10]);
    title(sprintf('iter %d: \\epsilon_r (F=%.4e)\nmean=%.2f, range=[%.1f, %.1f]', ...
        iter, F, mean(eps_r), min(eps_r), max(eps_r)), 'FontSize', 9);
    xlabel('x[mm]'); ylabel('y[mm]'); zlabel('z[mm]');
    axis equal; view(30, 25);
    
    % 标记 eps_r > 8 的过冲点
    overshoot = eps_r > 8;
    if sum(overshoot) > 0
        hold on;
        scatter3(pos(overshoot,1)*1000, pos(overshoot,2)*1000, pos(overshoot,3)*1000, ...
            80, 'k', 'p', 'filled', 'MarkerEdgeColor', 'r');
        title(sprintf('iter %d: eps_r (>8 marked) N_overshoot=%d', ...
            iter, sum(overshoot)), 'FontSize', 9);
    end
    
    % 子图2: 梯度 3D
    subplot(1, 3, 2);
    grad_col = grad(:);  % 确保列向量
    scatter3(pos(:,1)*1000, pos(:,2)*1000, pos(:,3)*1000, 15, grad_col, 'filled');
    colorbar; colormap(jet);
    c = max(abs(min(grad)), abs(max(grad)));
    if c > 0, caxis([-c, c]); end
    title(sprintf('iter %d: gradient g(v)\nrange=[%.2e, %.2e]', ...
        iter, min(grad), max(grad)), 'FontSize', 9);
    xlabel('x[mm]'); ylabel('y[mm]'); zlabel('z[mm]');
    axis equal; view(30, 25);
    
    % 子图3: eps_r vs x + 真值线
    subplot(1, 3, 3);
    scatter(pos(:,1)*1000, eps_r, 10, 'b', 'filled'); hold on;
    yline(5.0, 'r--', 'LineWidth', 2, 'Label', 'True=5');
    yline(8.0, 'k:', 'LineWidth', 1, 'Label', '>8 overshoot');
    xlabel('x [mm]'); ylabel('\epsilon_r');
    title(sprintf('iter %d: \\epsilon_r vs x\nmean=%.2f, std=%.2f', ...
        iter, mean(eps_r), std(eps_r)), 'FontSize', 9);
    ylim([0, 12]); grid on;
    
    % 保存
    img_path = fullfile('data', 'results', sprintf('inversion_iter%d.png', iter));
    saveas(gcf, img_path);
    fprintf('  图片已保存: %s\n', img_path);
    
    % 过冲点统计
    if sum(overshoot) > 0
        fprintf('  ★ 过冲点 (eps_r > 8): %d 个, range [%.2f, %.2f]\n', ...
            sum(overshoot), min(eps_r(overshoot)), max(eps_r(overshoot)));
        fprintf('    梯度: range [%.4e, %.4e], sign: %s\n', ...
            min(grad(overshoot)), max(grad(overshoot)), ...
            string(all(sign(grad(overshoot)) == sign(mean(grad(overshoot))))));
        fprintf('    → 梯度应指向减小 eps_r（g>0→eps下降），检查 sign\n');
    end
end

%% 汇总图：所有轮的 eps_r 分布直方图
figure('Position', [50, 50, 800, 400], 'Color', 'w');
for iter = 1:N_iter
    eps_r = s.history_eps{iter};
    subplot(1, N_iter, iter);
    histogram(eps_r, 20, 'FaceColor', [0.2 0.6 0.8]);
    hold on; xline(5.0, 'r--', 'LineWidth', 2);
    title(sprintf('iter %d\nF=%.3e', iter, s.history_F(iter)), 'FontSize', 9);
    xlabel('\epsilon_r'); xlim([0, 12]);
    if iter == 1, ylabel('Count'); end
end
sgtitle('eps_r distribution evolution', 'FontSize', 12);
saveas(gcf, fullfile('data', 'results', 'inversion_histograms.png'));
fprintf('\n直方图汇总已保存: data/results/inversion_histograms.png\n');

end
