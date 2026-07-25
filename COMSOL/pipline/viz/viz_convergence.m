function viz_convergence(h_fig)
%VIZ_CONVERGENCE 更新收敛曲线
    state = getappdata(h_fig, 'state');
    ax_conv = getappdata(h_fig, 'ax_conv');
    
    n_hist = find(state.history_residual > 0, 1, 'last');
    if isempty(n_hist), n_hist = 0; end
    
    if n_hist == 0, return; end
    
    % 找到已有的线对象
    lines = findobj(ax_conv, 'Type', 'line');
    if ~isempty(lines)
        set(lines(1), 'XData', 1:n_hist, 'YData', state.history_residual(1:n_hist));
    else
        semilogy(ax_conv, 1:n_hist, state.history_residual(1:n_hist), ...
            'b-o', 'LineWidth', 2, 'MarkerSize', 7, 'MarkerFaceColor', 'b');
    end
    
    xlim(ax_conv, [0.5, max(2, n_hist) + 0.5]);
    title(ax_conv, sprintf('Convergence (residual=%.4f)', state.residual), 'FontSize', 12);
end
