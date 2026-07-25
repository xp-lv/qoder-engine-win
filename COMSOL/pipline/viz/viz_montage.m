function viz_montage(state)
%VIZ_MONTAGE 反演迭代结果拼图（pipline 自包含 stub 版）
%   viz_montage(state)
%
%   改造说明（2026-07-20 自包含适配）:
%     - 原 viz_montage 依赖原项目可视化工具链，pipline 内未提供
%     - 本 stub 实现最小功能：保存迭代历史到 MAT 文件 + 控制台摘要
%     - 这样 inversion_loop.m 末尾调用 viz_montage(state) 不会中断
%     - 后续若需图形拼图，可在此函数内补充 figure/subplot/image 逻辑

    fprintf('\n[viz_montage] (stub) 反演迭代历史摘要:\n');
    fprintf('  Total iterations: %d\n', state.iteration);
    fprintf('  Final residual:   %.6e\n', state.residual);
    fprintf('  Converged:        %d\n', state.converged);

    if isfield(state, 'history_residual') && ~isempty(state.history_residual)
        residuals = state.history_residual(:);
        fprintf('\n  Residual trace:\n');
        for i = 1:numel(residuals)
            marker = '';
            if i > 1
                if residuals(i) < residuals(i-1) * 0.99, marker = ' ↓';
                elseif residuals(i) > residuals(i-1) * 1.01, marker = ' ↑';
                else, marker = ' →'; end
            end
            fprintf('    iter %2d: %.6e%s\n', i, residuals(i), marker);
        end
    end

    % 保存完整 state 到 results（便于离线分析）
    try
        p = config();
        save_path = fullfile(p.dir_result, ...
            sprintf('inversion_state_%s.mat', datestr(now, 'yyyymmdd_HHMMSS')));
        save(save_path, 'state', '-v7.3');
        fprintf('\n  [viz_montage] state saved: %s\n', save_path);
    catch ME
        fprintf('\n  [viz_montage] save failed: %s\n', ME.message);
    end
end
