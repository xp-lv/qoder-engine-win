function analyze_gradient_direction()
%ANALYZE_GRADIENT_DIRECTION 分析梯度朝向/背离真值的统计
%
%   读取 plot_gradient_scattered 保存的数据，统计每个体素的梯度方向

p = config();
data = load(fullfile(p.dir_result, 'gradient_scattered.mat'));
r = data.result;

eps_re_true = 5.0;
eps_im_true = -2.0;

% 初值与真值的差
diff_re = r.eps_re_init - eps_re_true;  % 正: ε_re偏高(需降低); 负: ε_re偏低(需升高)
diff_im = r.eps_im_init - eps_im_true;  % 正: ε_im偏高(需降低); 负: ε_im偏低(需升高)

N = length(diff_re);

%% 判断方向（梯度下降步 ε ← ε - α·∇F）
% 朝向真值: sign(grad) == sign(diff)，即梯度下降会缩小 |ε_init - ε_true|
% 背离真值: sign(grad) != sign(diff)，即梯度下降会增大 |ε_init - ε_true|

% ε' 方向
toward_re = sign(r.grad_re) == sign(diff_re);
away_re = ~toward_re;

% ε'' 方向
toward_im = sign(r.grad_im) == sign(diff_im);
away_im = ~toward_im;

%% 综合判断（实部和虚部都朝向才算"朝向"）
both_toward = toward_re & toward_im;
both_away = away_re & away_im;
mixed = ~(both_toward | both_away);

fprintf('\n========== 梯度方向统计 (共 %d 体素) ==========\n', N);
fprintf('  真值: ε_re=%.1f, ε_im=%.1f\n', eps_re_true, eps_im_true);
fprintf('  初值: ε_re∈[%.1f,%.1f], ε_im∈[%.1f,%.1f]\n\n', ...
    min(r.eps_re_init), max(r.eps_re_init), min(r.eps_im_init), max(r.eps_im_init));

fprintf('  ┌─────────────────────────────────────────────────────────┐\n');
fprintf('  │ ε'' (实部) 梯度方向:                                    │\n');
fprintf('  │   朝向真值: %4d / %4d  (%5.1f%%)                    │\n', ...
    sum(toward_re), N, 100*sum(toward_re)/N);
fprintf('  │   背离真值: %4d / %4d  (%5.1f%%)                    │\n', ...
    sum(away_re), N, 100*sum(away_re)/N);
fprintf('  │                                                          │\n');
fprintf('  │ ε'''' (虚部) 梯度方向:                                   │\n');
fprintf('  │   朝向真值: %4d / %4d  (%5.1f%%)                    │\n', ...
    sum(toward_im), N, 100*sum(toward_im)/N);
fprintf('  │   背离真值: %4d / %4d  (%5.1f%%)                    │\n', ...
    sum(away_im), N, 100*sum(away_im)/N);
fprintf('  │                                                          │\n');
fprintf('  │ 综合判断 (ε'' 和 ε'''' 同时):                           │\n');
fprintf('  │   两个分量都朝向: %4d / %4d  (%5.1f%%)              │\n', ...
    sum(both_toward), N, 100*sum(both_toward)/N);
fprintf('  │   两个分量都背离: %4d / %4d  (%5.1f%%)              │\n', ...
    sum(both_away), N, 100*sum(both_away)/N);
fprintf('  │   混合 (一朝一背):  %4d / %4d  (%5.1f%%)              │\n', ...
    sum(mixed), N, 100*sum(mixed)/N);
fprintf('  └─────────────────────────────────────────────────────────┘\n');

%% 可视化：4 张图
figure('Name', '梯度方向', 'Position', [50 50 1400 900], 'Color', 'w');

x = r.pos(:,1); y = r.pos(:,2); ms = 20;

% ε' 朝向/背离
subplot(2,2,1);
dir_re = toward_re;
scatter(x(dir_re), y(dir_re), ms, 'g', 'filled'); hold on;
scatter(x(~dir_re), y(~dir_re), ms, 'r', 'filled');
axis equal tight;
title(sprintf('ε'' 梯度方向: 绿=朝向真值(%d), 红=背离(%d)', sum(toward_re), sum(away_re)), 'FontSize', 12);
xlabel('x [m]'); ylabel('y [m]');
legend({'朝向真值', '背离真值'}, 'Location', 'best');

% ε'' 朝向/背离
subplot(2,2,2);
dir_im = toward_im;
scatter(x(dir_im), y(dir_im), ms, 'g', 'filled'); hold on;
scatter(x(~dir_im), y(~dir_im), ms, 'r', 'filled');
axis equal tight;
title(sprintf('ε'''' 梯度方向: 绿=朝向真值(%d), 红=背离(%d)', sum(toward_im), sum(away_im)), 'FontSize', 12);
xlabel('x [m]'); ylabel('y [m]');
legend({'朝向真值', '背离真值'}, 'Location', 'best');

% 综合（3 色分类）
subplot(2,2,[3 4]);
hold on;
scatter(x(both_toward), y(both_toward), ms, [0 0.7 0], 'filled');  % 深绿
scatter(x(both_away), y(both_away), ms, [0.8 0 0], 'filled');      % 深红
scatter(x(mixed), y(mixed), ms, [1 0.8 0], 'filled');              % 橙色
axis equal tight;
title(sprintf('综合: 全朝向=%d(绿), 全背离=%d(红), 混合=%d(橙)', ...
    sum(both_toward), sum(both_away), sum(mixed)), 'FontSize', 12);
xlabel('x [m]'); ylabel('y [m]');
legend({'ε''和ε'''' 都朝向', 'ε''和ε'''' 都背离', '混合'}, 'Location', 'best');

sgtitle('Re/Im交换+散射场梯度方向分析 (真值 ε=5-2j)', 'FontSize', 14, 'FontWeight', 'bold');

fig_path = fullfile(p.dir_result, 'gradient_direction_analysis.png');
saveas(gcf, fig_path);
fprintf('\n  图已保存: %s\n', fig_path);

end
