function plot_eps_distribution(result_file, iter_num)
%PLOT_EPS_DISTRIBUTION 绘制反演中间结果的 eps_r 三维分布图
%
%   用法：
%     >> plot_eps_distribution('data/results/inversion_iter_result.mat', 10)

if nargin < 1, result_file = 'data/results/inversion_iter_result.mat'; end
if nargin < 2, iter_num = 'final'; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);

% 加载结果
data = load(fullfile(pipline_dir, result_file));
result = data.result;

fprintf('加载结果: %s\n', result_file);
fprintf('  max_iter = %d\n', result.max_iter);
fprintf('  N_voxels = %d\n', length(result.eps_final));

% 获取体素坐标
% 需要重新加载网格获取坐标（result 中没有保存坐标）
fprintf('重新提取网格坐标...\n');
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart: %s\n', ME.message); return;
    end
end

try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
pos = voxel.pos(inner_idx, :);  % [N_inner x 3]

% 清理模型
try ModelUtil.remove('Model'); catch, end

% 选择 eps 分布
if strcmp(iter_num, 'final') || iter_num > result.max_iter
    eps_r = result.eps_final;
    title_str = sprintf('Final (iter %d): F=%.4f, mean=%.3f, std=%.3f', ...
        result.max_iter, result.F_final, mean(eps_r), std(eps_r));
else
    % 从历史重建第 N 轮的 eps 分布
    % history_mean 和 history_std 提供统计信息，但没有完整的逐体素历史
    % 用最终分布 + 反推不精确，直接画最终分布
    eps_r = result.eps_final;
    title_str = sprintf('iter %d (approx): F=%.4f, mean=%.3f, std=%.3f', ...
        iter_num, result.history_F(min(iter_num, result.max_iter)), ...
        result.history_mean(min(iter_num, result.max_iter)), ...
        result.history_std(min(iter_num, result.max_iter)));
    fprintf('[WARN] 仅保存了最终 eps 分布，无法精确重建第 %d 轮。\n', iter_num);
    fprintf('       显示最终分布（统计指标取自第 %d 轮历史）。\n', iter_num);
end

fprintf('eps_r: N=%d, range=[%.3f, %.3f], mean=%.3f, std=%.3f\n', ...
    length(eps_r), min(eps_r), max(eps_r), mean(eps_r), std(eps_r));

%% 绘图
figure('Position', [100, 100, 1200, 500], 'Color', 'w');

% 子图 1: 3D 散点
subplot(1, 3, 1);
scatter3(pos(:,1), pos(:,2), pos(:,3), 15, eps_r, 'filled');
colorbar;
title(sprintf('eps_r 3D Distribution\n%s', title_str), 'FontSize', 9);
xlabel('x [m]'); ylabel('y [m]'); zlabel('z [m]');
axis equal;
view(30, 25);
colormap(jet);
caxis([1, 10]);  % 固定色标范围，便于跨迭代对比

% 子图 2: x 切片（按 x 坐标分 bin 看 eps_r 均值）
subplot(1, 3, 2);
x_vals = pos(:,1);
x_bins = linspace(min(x_vals), max(x_vals), 20);
x_centers = (x_bins(1:end-1) + x_bins(2:end)) / 2;
eps_mean_x = zeros(size(x_centers));
eps_std_x = zeros(size(x_centers));
for bi = 1:length(x_centers)
    mask = x_vals >= x_bins(bi) & x_vals < x_bins(bi+1);
    if sum(mask) > 0
        eps_mean_x(bi) = mean(eps_r(mask));
        eps_std_x(bi) = std(eps_r(mask));
    end
end
errorbar(x_centers*1000, eps_mean_x, eps_std_x, 'b-o', 'LineWidth', 1.5);
hold on;
yline(5.0, 'r--', 'LineWidth', 2, 'Label', 'True \epsilon_r=5');
xlabel('x [mm]'); ylabel('\epsilon_r');
title('\epsilon_r vs x (mean \pm std)', 'FontSize', 10);
grid on; ylim([0, 12]);
% (grid_meas unused but needed for build_measurement_grid side effects)

% 子图 3: 直方图
subplot(1, 3, 3);
histogram(eps_r, 30, 'FaceColor', [0.2 0.6 0.8], 'EdgeColor', 'none');
hold on;
xline(5.0, 'r--', 'LineWidth', 2, 'Label', 'True=5');
xlabel('\epsilon_r'); ylabel('Count');
title(sprintf('Histogram (N=%d)\nmean=%.3f, std=%.3f', length(eps_r), mean(eps_r), std(eps_r)), 'FontSize', 9);
grid on; xlim([0, 12]);

% 保存图片
img_path = fullfile(p.dir_result, sprintf('eps_distribution_%s.png', ...
    regexprep(num2str(iter_num), '\W', '_')));
saveas(gcf, img_path);
fprintf('\n图片已保存: %s\n', img_path);

end
