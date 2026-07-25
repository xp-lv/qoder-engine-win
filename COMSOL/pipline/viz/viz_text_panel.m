function viz_text_panel(h_fig, state, voxel, iter, p)
%VIZ_TEXT_PANEL 更新文本信息面板
    h_text = getappdata(h_fig, 'h_text');
    if isempty(h_text) || ~isvalid(h_text), return; end
    
    eps_inner = voxel.epsilon_r(voxel.mask_interior);
    
    lines = {
        sprintf('Iteration: %d / %d', iter, p.max_iter);
        sprintf('epsilon_r mean: %.3f', mean(real(eps_inner)));
        sprintf('epsilon_r std:  %.3f', std(real(eps_inner)));
        sprintf('epsilon_r range: [%.2f, %.2f]', min(real(eps_inner)), max(real(eps_inner)));
        sprintf('Residual: %.4e', state.residual);
        sprintf('Step mu: %.4f', state.history_mu(iter));
    };
    
    if iter > 1
        prev_res = state.history_residual(iter-1);
        delta = state.residual - prev_res;
        if delta < 0
            lines{end+1} = sprintf('Delta residual: %.2e (down)', delta);
        else
            lines{end+1} = sprintf('Delta residual: +%.2e (UP)', delta);
        end
        lines{end+1} = sprintf('Delta eps_r: %.3f', ...
            mean(real(state.history_epsilon(voxel.mask_interior, iter))) - ...
            mean(real(state.history_epsilon(voxel.mask_interior, iter-1))));
    end
    
    set(h_text, 'String', lines);
end
