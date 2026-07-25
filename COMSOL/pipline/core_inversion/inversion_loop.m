function state = inversion_loop(voxel, lc, model, p)
%INVERSION_LOOP 伴随法梯度下降反演主循环
%   state = inversion_loop(voxel, lc, model, p)
%
%   每轮迭代:
%     ① COMSOL 正演 → E_total
%     ② COMSOL 全波 J_hyp → 计算 ΔJ (H001: born -> full_maxwell)
%     ③ 收敛判断
%     ④ 构建伴随源 f_adj
%     ⑤ COMSOL 伴随求解 → λ
%     ⑥ 计算精确梯度 g = dF/dε_r
%     ⑦ Armijo 线搜索 → 更新 ε_r
%     ⑧ 更新可视化 + 检查终止按钮
%
%   输入:
%       voxel   初始体素网格
%       lc      LightConeData（含 J_obs）
%       model   COMSOL 模型
%       p       config
%   输出:
%       state   反演状态（迭代历史、最终 ε_r 等）

fprintf('========== 伴随法梯度下降反演 ==========\n');

N_v = length(voxel.epsilon_r);
inner = voxel.mask_interior;
max_iter = p.max_iter;

% 初始化状态
state.iteration = 0;
state.epsilon_r = voxel.epsilon_r;
state.residual = 1.0;
state.converged = false;
state.history_residual = zeros(max_iter, 1);
state.history_epsilon = zeros(N_v, max_iter);
state.history_mu = zeros(max_iter, 1);

% ---- exp69 v1 per-k 加权(2026-06-10 集成，默认关闭保 50 个老 exp 零影响)----
% weight_strategy='adaptive' 时，加载并行模块并分配 history 字段
if isfield(p, 'weight_strategy') && strcmp(p.weight_strategy, 'adaptive')
    exp69_scripts = '';
    for sub = {'active', 'partial', 'success'}
        cand = fullfile(p.base_path, '.research', 'experiments', sub{1}, 'exp69', 'scripts');
        if exist(cand, 'dir')
            exp69_scripts = cand;
            break;
        end
    end
    if isempty(exp69_scripts)
        error('inversion_loop:exp69_module_not_found', ...
              'weight_strategy=adaptive 但 exp69 scripts 目录不存在(.research/experiments/{active,partial,success}/exp69/scripts)');
    end
    addpath(exp69_scripts);
    fprintf('[inversion_loop] exp69 per-k 加权模块加载: %s\n', exp69_scripts);
    N_k_state = size(lc.J_obs_perp, 1);
    state.history_F_k       = zeros(N_k_state, max_iter);
    state.history_w_k       = zeros(N_k_state, max_iter);
    state.history_worst_F_k = zeros(max_iter, 1);
    state.history_worst_k   = zeros(max_iter, 1);
    state.weight_strategy   = 'adaptive';
end

N_k = size(lc.J_obs_perp, 1);
state.history_Delta_J = zeros(N_k, 3, max_iter);
state.history_J_hyp = zeros(N_k, 3, max_iter);
state.history_J_obs = lc.J_obs_perp;

% 切片索引（中心 z）
inner_pos = voxel.pos(inner, :);
center_z = mean(inner_pos(:, 3));
z_tol = diff([min(voxel.pos(:,3)), max(voxel.pos(:,3))]) / size(voxel.pos,1)^(1/3);
slice_idx = find(abs(voxel.pos(:,3) - center_z) < z_tol & inner);
state.slice_pos = voxel.pos(slice_idx, 1:2);
state.slice_data = zeros(length(slice_idx), max_iter);

mu = p.mu_init;
t_total = tic;

%% 主循环
h_fig = [];

for iter = 1:max_iter
    % 检查终止
    if ~isempty(h_fig) && isvalid(h_fig)
        flag = getappdata(h_fig, 'stop');
        if ~isempty(flag) && flag
            fprintf('\n  [STOP] 反演已由用户终止\n');
            state.iteration = iter - 1;
            break;
        end
    end
    
    t_iter = tic;
    fprintf('\n--- 迭代 %d/%d ---\n', iter, max_iter);
    
    %% ① COMSOL 正演
    fprintf('[Step ①] 正演求解...\n');
    [E_total, ~, E_gauss] = solve_forward(model, voxel, p);
    
    if isempty(E_total)
        fprintf('  [ERROR] 正演失败\n');
        break;
    end
    
    %% ② J_hyp → ΔJ（H001: COMSOL 全波 Gauss 积分，替代 Born 近似）
    fprintf('[Step ②] 计算 J_hyp (H001: COMSOL 全波 compute_jhyp_comsol)...\n');
    lc.k_vec = p.k0 * lc.k_dir;
    J_hyp = compute_jhyp_comsol(model, lc, p);
    lc.J_hyp_perp = J_hyp;
    Delta_J = lc.J_obs_perp - J_hyp;
    lc.Delta_J_perp = Delta_J;
    
    %% ③ 收敛判断
    fprintf('[Step ③] 收敛判断...\n');
    [converged, residual] = check_convergence(lc, p);
    
    state.history_residual(iter) = residual;
    state.residual = residual;
    state.history_epsilon(:, iter) = voxel.epsilon_r;
    state.slice_data(:, iter) = real(voxel.epsilon_r(slice_idx));
    state.history_Delta_J(:, :, iter) = Delta_J;
    state.history_J_hyp(:, :, iter) = lc.J_hyp_perp;
    
    eps_inner = voxel.epsilon_r(inner);
    fprintf('  >>> 残差: %.6e (阈值: %.0e)\n', residual, p.eps_tol);
    fprintf('  [DIAG] ε_r μ=%.3f σ=%.3f [%.3f, %.3f]\n', ...
        mean(real(eps_inner)), std(real(eps_inner)), ...
        min(real(eps_inner)), max(real(eps_inner)));
    
    % 残差追踪表
    if iter == 1
        fprintf('  %s\n', repmat('=', 1, 60));
        fprintf('  %4s  %10s  %8s  %s\n', 'Iter', 'ε_r μ', 'Residual', 'Trend');
        fprintf('  %s\n', repmat('-', 1, 60));
    end
    trend = '  -';
    if iter > 1
        prev = state.history_residual(iter-1);
        if residual < prev * 0.99, trend = 'down';
        elseif residual > prev * 1.01, trend = 'UP';
        else, trend = 'flat'; end
    end
    fprintf('  %4d  %10.3f  %8.4f  %s\n', iter, mean(real(eps_inner)), residual, trend);
    
    if converged
        fprintf('  Converged!\n');
        state.converged = true;
        state.iteration = iter;
        h_fig = viz_manager(state, voxel, slice_idx, iter, p, h_fig);
        break;
    end
    
    %% ④ 构建伴随源
    fprintf('[Step ④] 构建伴随源...\n');
    % exp69 v1 集成：weight_strategy='adaptive' 走 per-k 加权；'uniform' 走老路径(50 个老 exp 零影响)
    if isfield(p, 'weight_strategy') && strcmp(p.weight_strategy, 'adaptive')
        [f_adj, S_raw, F_obs_lc, info_w] = per_k_weighted_adjoint_source(voxel, E_total, lc, p);
        if isfield(state, 'history_F_k')
            state.history_F_k(:, iter)    = info_w.F_k;
            state.history_w_k(:, iter)    = info_w.w_k;
            state.history_worst_F_k(iter) = info_w.worst_F_k;
            state.history_worst_k(iter)   = info_w.worst_k;
        end
    else
        [f_adj, S_raw, F_obs_lc] = build_adjoint_source(voxel, E_total, lc, p);
    end
    
    %% ⑤ COMSOL 伴随求解
    fprintf('[Step ⑤] 伴随求解...\n');
    [lambda, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj);
    
    if ~adj_ok || isempty(lambda)
        fprintf('  [WARN] 伴随求解失败，跳过本轮更新\n');
        h_fig = viz_manager(state, voxel, slice_idx, iter, p, h_fig);
        continue;
    end
    
    %% ⑥ 计算精确梯度
    fprintf('[Step ⑥] 计算梯度...\n');
    g = compute_gradient(voxel, E_total, S_raw, lambda, p, F_obs_lc, true, E_gauss, lambda_gauss);
    
    %% ⑦ 线搜索更新
    fprintf('[Step ⑦] 线搜索...\n');
    [voxel, mu, accepted] = linesearch(voxel, E_total, g, lc, p, model);
    state.history_mu(iter) = mu;
    state.epsilon_r = voxel.epsilon_r;
    state.iteration = iter;
    
    if ~accepted
        fprintf('  [WARN] 线搜索未找到可接受步长\n');
    end
    
    %% ⑧ 可视化
    h_fig = viz_manager(state, voxel, slice_idx, iter, p, h_fig);
    
    t_elapsed = toc(t_iter);
    fprintf('  迭代 %d 耗时: %.1f s (μ=%.4f)\n', iter, t_elapsed, mu);
end

t_total = toc(t_total);
fprintf('\n========== 反演完成 ==========\n');
fprintf('  总迭代: %d, 最终残差: %.6e, 总耗时: %.1f s\n', ...
    state.iteration, state.residual, t_total);

% 裁剪历史
if state.iteration < max_iter
    n = state.iteration;
    state.history_residual = state.history_residual(1:n);
    state.history_epsilon = state.history_epsilon(:, 1:n);
    state.history_Delta_J = state.history_Delta_J(:, :, 1:n);
    state.history_J_hyp = state.history_J_hyp(:, :, 1:n);
    state.slice_data = state.slice_data(:, 1:n);
    state.history_mu = state.history_mu(1:n);
    if isfield(state, 'history_F_k')
        state.history_F_k       = state.history_F_k(:, 1:n);
        state.history_w_k       = state.history_w_k(:, 1:n);
        state.history_worst_F_k = state.history_worst_F_k(1:n);
        state.history_worst_k   = state.history_worst_k(1:n);
    end
end

% 迭代拼图
viz_montage(state);

end
