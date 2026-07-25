function h_fig = viz_manager(state, voxel, slice_idx, iter, p, h_fig)
%VIZ_MANAGER 实时反演可视化总控
%   h_fig = viz_manager(state, voxel, slice_idx, iter, p, h_fig)
%
%   首次调用 (h_fig=[]): 创建图窗，布局所有子图区域
%   后续调用: 仅更新数据，不重建图形对象
%
%   图窗布局:
%   ┌──────────────────┬──────────────────┐
%   │  3D ε_r Slice    │  Convergence      │
%   │  (三正交切面)    │  (残差曲线)       │
%   ├──────────────────┼──────────────────┤
%   │  Δε_r Change     │  Text Panel       │
%   │  (体素变化热力图) │  (迭代/残差/步长) │
%   ├──────────────────┴──────────────────┤
%   │            [终止反演]                │
%   └─────────────────────────────────────┘

if ~p.viz_enabled
    h_fig = [];
    return;
end

is_batch = ~usejava('desktop');

% 推断规则 3D 网格
xs = unique(voxel.pos(:,1));
ys = unique(voxel.pos(:,2));
zs = unique(voxel.pos(:,3));
Nx = length(xs); Ny = length(ys); Nz = length(zs);

if numel(voxel.epsilon_r) ~= Nx*Ny*Nz
    warning('viz_manager: 体素不规则，跳过 3D 可视化');
    if ~is_batch
        h_fig = [];
    end
    return;
end

[Xg, Yg, Zg] = meshgrid(xs, ys, zs);
V = reshape(real(voxel.epsilon_r), [Ny, Nx, Nz]);
eps_inner = real(voxel.epsilon_r(voxel.mask_interior));
c_min = 1; c_max = max(6, ceil(max(eps_inner)));

%% 首次调用：创建图窗
if isempty(h_fig) || ~isvalid(h_fig)
    fig_vis = 'on'; if is_batch, fig_vis = 'off'; end
    h_fig = figure('Name', '逆散射反演实时监控', 'NumberTitle', 'off', ...
        'Tag', 'InversionLive', 'Visible', fig_vis, ...
        'Position', [50, 50, 1400, 800]);
    
    % -- 终止按钮 --
    uicontrol('Parent', h_fig, 'Style', 'pushbutton', ...
        'String', '终止反演', 'FontSize', 13, 'FontWeight', 'bold', ...
        'ForegroundColor', [1 1 1], 'BackgroundColor', [0.85 0.2 0.2], ...
        'Position', [1250, 15, 120, 40], ...
        'Callback', @(s,e) setappdata(h_fig, 'stop', true));
    setappdata(h_fig, 'stop', false);
    
    % -- 3D Slice 图 --
    ax_3d = axes('Parent', h_fig, 'Position', [0.04, 0.35, 0.50, 0.60]);
    view(ax_3d, 3); axis(ax_3d, 'equal');
    xlim(ax_3d, [xs(1), xs(end)]); ylim(ax_3d, [ys(1), ys(end)]); zlim(ax_3d, [zs(1), zs(end)]);
    xlabel(ax_3d, 'x (m)'); ylabel(ax_3d, 'y (m)'); zlabel(ax_3d, 'z (m)');
    grid(ax_3d, 'on'); box(ax_3d, 'on');
    colormap(ax_3d, jet); colorbar(ax_3d);
    title(ax_3d, '\epsilon_r 3D 分布', 'FontSize', 13);
    rotate3d(ax_3d, 'on'); hold(ax_3d, 'on');
    
    % -- 收敛曲线 --
    ax_conv = axes('Parent', h_fig, 'Position', [0.60, 0.60, 0.36, 0.32]);
    semilogy(ax_conv, 1, 1, 'b-o', 'LineWidth', 2, 'MarkerSize', 7, 'MarkerFaceColor', 'b');
    xlabel(ax_conv, 'Iteration'); ylabel(ax_conv, 'Residual');
    title(ax_conv, 'Convergence', 'FontSize', 12);
    grid(ax_conv, 'on'); hold(ax_conv, 'on');
    
    % -- Δε_r 变化图 --
    ax_delta = axes('Parent', h_fig, 'Position', [0.04, 0.12, 0.50, 0.18]);
    xlabel(ax_delta, 'x (m)'); ylabel(ax_delta, 'y (m)');
    title(ax_delta, '\Delta\epsilon_r Change (iter>=2)', 'FontSize', 11);
    axis(ax_delta, 'equal'); grid(ax_delta, 'on'); box(ax_delta, 'on');
    colormap(ax_delta, [linspace(0,1,128)' linspace(0,1,128)' ones(128,1); ...
                         ones(128,1) linspace(1,0,128)' linspace(1,0,128)']);
    colorbar(ax_delta); hold(ax_delta, 'on');
    
    % -- 文本面板 --
    ax_text = axes('Parent', h_fig, 'Position', [0.60, 0.20, 0.36, 0.32]);
    axis(ax_text, 'off');
    h_text = text(ax_text, 0.05, 0.5, '', 'FontSize', 11, 'VerticalAlignment', 'middle');
    
    % 存储句柄
    setappdata(h_fig, 'ax_3d', ax_3d);
    setappdata(h_fig, 'ax_conv', ax_conv);
    setappdata(h_fig, 'ax_delta', ax_delta);
    setappdata(h_fig, 'h_text', h_text);
    setappdata(h_fig, 'h_slices', []);
    setappdata(h_fig, 'h_delta_scatter', []);
    setappdata(h_fig, 'Xg', Xg);
    setappdata(h_fig, 'Yg', Yg);
    setappdata(h_fig, 'Zg', Zg);
    
    % 默认切面位置
    sx0 = mean(xs); sy0 = mean(ys); sz0 = mean(zs);
    setappdata(h_fig, 'sx', sx0);
    setappdata(h_fig, 'sy', sy0);
    setappdata(h_fig, 'sz', sz0);
end

%% 更新数据
setappdata(h_fig, 'V', V);
setappdata(h_fig, 'voxel', voxel);
setappdata(h_fig, 'state', state);
setappdata(h_fig, 'slice_idx', slice_idx);
setappdata(h_fig, 'iter', iter);

figure(h_fig);

% 重绘 3D slice
viz_3d_slice(h_fig, c_min, c_max);

% 更新收敛曲线
viz_convergence(h_fig);

% 更新 Δε_r 变化图
viz_delta_eps(h_fig, state, slice_idx, iter);

% 更新文本面板
viz_text_panel(h_fig, state, voxel, iter, p);

drawnow;

% 保存截图
if is_batch && p.viz_save_screenshots
    if ~exist(p.dir_live, 'dir'), mkdir(p.dir_live); end
    fname = fullfile(p.dir_live, sprintf('iter_%03d.png', iter));
    try
        saveas(h_fig, fname);
    catch
    end
end

end
