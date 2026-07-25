function state = A12_inversion_loop(voxel, lc, J_obs_perp_multi, freqs, grid, model, p, B_op, c_init)
%A12_INVERSION_LOOP c-space multi-freq inversion (H004: Zhang-Hager nonmonotone)
%   H004: Armijo monotone → Zhang-Hager nonmonotone line search
%
%   H003 问题：Armijo 单调线搜索 iter=3 起全 8 trial reject，残差冻结。
%   H004 修复：维护非单调参考值 R_k = η_ls·R_{k-1}+(1-η_ls)·f(x_k)，
%   传递给 A12_linesearch 作为接受准则参考值（替代单调 f(x_k)）。

N_freq = length(freqs);
N_k = size(J_obs_perp_multi{1}, 1);
N_c = size(B_op, 2);
inner = voxel.mask_interior;
N_inner = sum(inner);
N_v = length(voxel.epsilon_r);

fprintf('\n[A12_inversion_loop] start, max_iter=%d, N_freq=%d, N_c=%d, N_inner=%d, lambda_TV=%.4f\n', ...
    p.max_iter, N_freq, N_c, N_inner, p.lambda_tv);
% H005-fix: 动态读取 config 参数，避免硬编码显示字符串误导（H005 c1=0.01/eta_ls=0.7 与 H004 不同）
ls_disp_eta = 0.85;
if isfield(p, 'ls_nonmonotone_eta'), ls_disp_eta = p.ls_nonmonotone_eta; end
ls_disp_c1 = 0.0001;
if isfield(p, 'ls_armijo_c1'), ls_disp_c1 = p.ls_armijo_c1; end
fprintf('[A12_inversion_loop] Line search: Zhang-Hager nonmonotone (eta_ls=%.2f, c1=%.4f)\n', ls_disp_eta, ls_disp_c1);

%% Initialize history
state.history_F_k          = zeros(N_k, p.max_iter);
state.history_F_k_per_d    = zeros(N_k, 3, p.max_iter);
state.history_residual     = zeros(p.max_iter, 1);
state.history_eps_inner    = zeros(N_inner, p.max_iter);
state.history_cos_theta    = zeros(N_k, p.max_iter);
state.history_worst_F_k    = zeros(p.max_iter, 1);
state.history_worst_k      = zeros(p.max_iter, 1);
state.history_J_hyp        = zeros(N_k, 3, p.max_iter);
state.history_inner_mean   = zeros(p.max_iter, 1);
state.history_inner_std    = zeros(p.max_iter, 1);
state.history_eps_r_max    = zeros(p.max_iter, 1);
state.history_eps_r_min    = zeros(p.max_iter, 1);
state.history_worst_F_k_over_mean = zeros(p.max_iter, 1);
state.history_F_k_per_freq = zeros(N_freq, p.max_iter);
state.history_R_tv         = zeros(p.max_iter, 1);
state.history_g_data_norm  = zeros(p.max_iter, 1);
state.history_g_tv_norm    = zeros(p.max_iter, 1);
state.history_c            = zeros(N_c, p.max_iter);

state.converged = false;
state.iteration = 0;
state.algorithm = 'A12_multi_freq_v3_bspline_zhang_hager_nonmonotone_h004';
state.N_c = N_c;
mu = p.mu_init;
R_ref = 0;  % H004: Zhang-Hager nonmonotone reference R_k (initialized at iter=1 to f(x_0))

%% CSV log
log_path = fullfile(p.dir_result_A12, 'A12_inversion_log.csv');
log_fid = fopen(log_path, 'w');
if log_fid == -1
    error('[A12] Cannot open log: %s', log_path);
end
fprintf(log_fid, 'iter,F_cheb,mean_F_k,worst_F_k,worst_k,worst_over_mean,mean_cos_theta,inner_mean,inner_std,eps_r_min,eps_r_max,mu,time_s,accepted,F_k_f1,F_k_f2,F_k_f3,R_tv,g_data_norm,g_tv_norm\n');
fclose(log_fid);

%% c-space initialization (A12: c = 4.0 * ones, PoU fix guarantees eps_r=4.0)
c = c_init(:);

%% H007-pm: Forward result cache (pipeline maintenance — performance optimization)
%  当上一轮线搜索全 reject (c 未更新) 时，本轮正演/伴随结果与上一轮完全相同。
%  跳过冗余 COMSOL forward+adjoint 求解，复用缓存值。
%  来源: 管线优化建议.md §1 (H007 needs_optimization)
cache_g_voxel_total   = [];
cache_F_k_total       = [];
cache_F_k_per_d_total = [];
cache_cos_theta_sum   = [];
cache_J_hyp_primary   = [];
cache_F_k_per_freq    = [];
last_accepted = true;  % iter=1 总是正常计算

%% Main loop
for iter = 1:p.max_iter
    tic;
    fprintf('\n--- A12 iter %d/%d (mu=%.4f, N_freq=%d, N_c=%d) ---\n', iter, p.max_iter, mu, N_freq, N_c);

    %% 1. Reconstruct voxel eps_r from c
    voxel.epsilon_r = B_op * c;
    eps_re = real(voxel.epsilon_r);
    eps_re = max(p.eps_r_min, min(p.eps_r_max, eps_re));
    voxel.epsilon_r = eps_re;
    voxel.epsilon_r(~inner) = 1.0;

    %% 2. Multi-freq forward + F_k + adjoint gradient (voxel space)
    %  H007-pm: Forward cache — 当上一轮 LS 全 reject (c 未更新) 时跳过冗余正演
    if iter > 1 && ~last_accepted
        fprintf('  [iter %d] FORWARD CACHE HIT: c unchanged (prev LS all-reject), skipping %d forward+adjoint solves\n', ...
            iter, N_freq);
        g_voxel_total   = cache_g_voxel_total;
        F_k_total       = cache_F_k_total;
        F_k_per_d_total = cache_F_k_per_d_total;
        cos_theta_sum   = cache_cos_theta_sum;
        J_hyp_primary   = cache_J_hyp_primary;
        F_k_per_freq    = cache_F_k_per_freq;
    else
    g_voxel_total = zeros(N_v, 1);
    F_k_total = zeros(N_k, 1);
    F_k_per_d_total = zeros(N_k, 3);
    cos_theta_sum = zeros(N_k, 1);
    J_hyp_primary = [];
    F_k_per_freq = zeros(N_freq, 1);

    for fi = 1:N_freq
        p.freq = freqs(fi);
        p.omega = 2*pi*p.freq;
        p.k0 = p.omega / p.c;
        p.lambda = p.c / p.freq;

        fprintf('  [iter %d freq=%d (%.0f GHz)] forward solve...\n', iter, fi, freqs(fi)/1e9);

        [E_total, ~, E_gauss] = solve_forward(model, voxel, p);

        sf = extract_scattered(model, grid);
        lc_new = lightcone_project(grid, sf, p);
        J_hyp = lc_new.J_obs_perp;

        J_obs_fi = J_obs_perp_multi{fi};
        Delta_J = J_obs_fi - J_hyp;
        J_obs_per_d_norm_sq = sum(abs(J_obs_fi).^2, 2);
        Delta_J_per_d_norm_sq = sum(abs(Delta_J).^2, 2);
        J_obs_safe = max(J_obs_per_d_norm_sq, p.rel_err_floor);
        F_k_fi = Delta_J_per_d_norm_sq ./ J_obs_safe / 6;

        F_k_total = F_k_total + F_k_fi / N_freq;
        F_k_per_freq(fi) = mean(F_k_fi);

        for d = 1:3
            F_k_per_d_total(:, d) = F_k_per_d_total(:, d) + ...
                abs(Delta_J(:, d)).^2 ./ max(abs(J_obs_fi(:, d)).^2, p.rel_err_floor) / N_freq;
        end

        J_obs_norm = sqrt(sum(abs(J_obs_fi).^2, 2)) + p.rel_err_floor;
        J_hyp_norm = sqrt(sum(abs(J_hyp).^2, 2)) + p.rel_err_floor;
        cos_theta_fi = real(sum(conj(J_obs_fi) .* J_hyp, 2)) ./ (J_obs_norm .* J_hyp_norm);
        cos_theta_sum = cos_theta_sum + cos_theta_fi / N_freq;

        if fi == 1
            J_hyp_primary = J_hyp;
        end

        fprintf('  [iter %d freq=%d] F_k mean=%.4e, max=%.4e, cos=%.3f\n', ...
            iter, fi, mean(F_k_fi), max(F_k_fi), mean(cos_theta_fi));

        fprintf('  [iter %d freq=%d] adjoint solve...\n', iter, fi);
        lc.k_vec = p.k0 * lc.k_dir;
        lc.J_obs_perp = J_obs_fi;
        lc.Delta_J_perp = Delta_J;
        [f_adj, source_pos, F_obs_lc] = build_adjoint_source_fullmaxwell(grid, lc, p);
        [lambda_fi, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos);

        if ~adj_ok
            fprintf('  [iter %d freq=%d] [WARN] adjoint failed, skipping\n', iter, fi);
            continue;
        end

        S_raw_zero = zeros(N_v, 3);
        g_fi = compute_gradient(voxel, E_total, S_raw_zero, lambda_fi, p, F_obs_lc, true, E_gauss, lambda_gauss);
        g_fi(~inner) = 0;
        g_voxel_total = g_voxel_total + real(g_fi) / N_freq;

        fprintf('  [iter %d freq=%d] |g_voxel| mean=%.4e, max=%.4e\n', ...
            iter, fi, mean(abs(g_fi(inner))), max(abs(g_fi(inner))));
    end

    % H007-pm: Cache forward+adjoint results for potential reuse next iteration
    cache_g_voxel_total   = g_voxel_total;
    cache_F_k_total       = F_k_total;
    cache_F_k_per_d_total = F_k_per_d_total;
    cache_cos_theta_sum   = cos_theta_sum;
    cache_J_hyp_primary   = J_hyp_primary;
    cache_F_k_per_freq    = F_k_per_freq;
    end  % H007-pm: end forward cache else-block

    %% 3. Chain rule: voxel gradient -> c gradient
    g_data_c = B_op' * g_voxel_total;

    %% 4. TV regularization (voxel space)
    [g_tv_voxel, R_tv, diag_tv] = exp07a_tv_reg(voxel, c, p, B_op);
    g_tv_c = B_op' * g_tv_voxel;

    g_c = g_data_c + p.lambda_tv * g_tv_c;
    g_data_norm = norm(g_data_c);
    g_tv_norm = norm(g_tv_c);
    g_c_norm = norm(g_c);

    fprintf('  [TV] R_TV=%.4e, ||g_data_c||=%.3e, ||g_tv_c||=%.3e, lambda*||g_tv||/||g_data||=%.3f, ||g_c||=%.3e\n', ...
        R_tv, g_data_norm, g_tv_norm, p.lambda_tv * g_tv_norm / max(g_data_norm, 1e-15), g_c_norm);

    %% 5. Aggregate statistics
    F_cheb = mean(F_k_total);
    mean_F_k = F_cheb;
    [F_max_k, worst_idx] = max(F_k_total);
    worst_over_mean = F_max_k / max(mean_F_k, p.rel_err_floor);
    mean_cos_theta = mean(cos_theta_sum);

    state.history_residual(iter) = F_cheb;
    state.history_F_k(:, iter) = F_k_total;
    state.history_F_k_per_d(:, :, iter) = F_k_per_d_total;
    state.history_J_hyp(:, :, iter) = J_hyp_primary;
    state.history_eps_inner(:, iter) = real(voxel.epsilon_r(inner));
    state.history_eps_r_max(iter) = max(real(voxel.epsilon_r(inner)));
    state.history_eps_r_min(iter) = min(real(voxel.epsilon_r(inner)));
    state.history_inner_mean(iter) = mean(real(voxel.epsilon_r(inner)));
    state.history_inner_std(iter) = std(real(voxel.epsilon_r(inner)));
    state.history_worst_F_k(iter) = F_max_k;
    state.history_worst_k(iter) = worst_idx;
    state.history_worst_F_k_over_mean(iter) = worst_over_mean;
    state.history_cos_theta(:, iter) = cos_theta_sum;
    state.history_F_k_per_freq(:, iter) = F_k_per_freq;
    state.history_R_tv(iter) = R_tv;
    state.history_g_data_norm(iter) = g_data_norm;
    state.history_g_tv_norm(iter) = g_tv_norm;
    state.history_c(:, iter) = c;

    fprintf('  [iter %d] AGG: F_cheb=%.4e, F_max=%.4e (k=%d), worst/mean=%.2f, cos=%.3f, inner=[%.3f, %.3f] std=%.3f, t=%.1fs\n', ...
        iter, F_cheb, F_max_k, worst_idx, worst_over_mean, mean_cos_theta, ...
        state.history_eps_r_min(iter), state.history_eps_r_max(iter), ...
        state.history_inner_std(iter), toc);

    % CSV log
    log_fid = fopen(log_path, 'a');
    fprintf(log_fid, '%d,%.6e,%.6e,%.6e,%d,%.4f,%.6f,%.4f,%.4f,%.4f,%.4f,%.6f,%.1f,%d', ...
        iter, F_cheb, mean_F_k, F_max_k, worst_idx, worst_over_mean, ...
        mean_cos_theta, state.history_inner_mean(iter), state.history_inner_std(iter), ...
        state.history_eps_r_min(iter), state.history_eps_r_max(iter), mu, toc, 0);
    for fi = 1:N_freq
        fprintf(log_fid, ',%.6e', F_k_per_freq(fi));
    end
    fprintf(log_fid, ',%.6e,%.6e,%.6e', R_tv, g_data_norm, g_tv_norm);
    fprintf(log_fid, '\n');
    fclose(log_fid);

    if F_cheb < p.eps_tol
        fprintf('  [iter %d] Converged: F_cheb = %.4e < %.4e\n', iter, F_cheb, p.eps_tol);
        state.converged = true;
        state.iteration = iter;
        state.stop_reason = 'eps_tol_reached';
        update_log_accepted(log_path, iter);
        break;
    end

    %% H002: Adaptive early stopping (soft gate)
    %  监控滑动窗口 W 内连续 W 个相对残差改善率 |Δr|/r，
    %  当全部低于停滞阈值 δ 时判定收敛停滞，自动终止迭代。
    %  max_iter 仍作为硬上界安全网兜底（循环上界不变）。
    %  state.iteration 反映实际终止轮数，state.stop_reason 区分终止原因。
    state.stop_reason = '';
    if isfield(p, 'early_stop_enabled') && p.early_stop_enabled && iter >= 2
        r_curr = state.history_residual(iter);
        r_prev = state.history_residual(iter - 1);
        rel_imp_curr = abs(r_prev - r_curr) / max(abs(r_prev), p.rel_err_floor);
        % 需要至少 W 个改善率 => iter >= W+1 才能填满窗口（W 个改善率需 W+1 个残差点）
        W = p.early_stop_window;
        if iter >= W + 1
            all_stagnant = true;
            for w = 0:(W - 1)
                r_a = state.history_residual(iter - 1 - w);
                r_b = state.history_residual(iter - w);
                rel_imp_w = abs(r_a - r_b) / max(abs(r_a), p.rel_err_floor);
                if rel_imp_w >= p.early_stop_rel_improvement
                    all_stagnant = false;
                    break;
                end
            end
            if all_stagnant
                fprintf('  [iter %d] EARLY STOP (H002): %d consecutive relative improvements < %.4f, stagnation detected (rel_imp_curr=%.6f)\n', ...
                    iter, W, p.early_stop_rel_improvement, rel_imp_curr);
                state.converged = true;
                state.iteration = iter;
                state.stop_reason = 'adaptive_early_stopping';
                update_log_accepted(log_path, iter);
                break;
            end
        end
    end

    %% 6. c-space Zhang-Hager nonmonotone linesearch (H004)
    % R_k 生命周期管理：
    %   iter==1: R_ref = F_cheb (= f(x_0)，参考值初始化)
    %   iter>1:  R_ref = η_ls·R_ref + (1-η_ls)·F_cheb (衰减加权平均更新)
    % R_ref 传递给 A12_linesearch 作为非单调接受准则参考值。
    eta_ls = 0.85;
    if isfield(p, 'ls_nonmonotone_eta'), eta_ls = p.ls_nonmonotone_eta; end
    if iter == 1
        R_ref = F_cheb;  % R_0 = f(x_0)
    else
        R_ref = eta_ls * R_ref + (1 - eta_ls) * F_cheb;
    end

    F_total = F_cheb + p.lambda_tv * R_tv;  % for reporting only
    fprintf('  [iter %d] A12_linesearch ZH-nonmonotone (F_data=%.4e, R_ref=%.4e, F_total=%.4e (reporting), ||g_c||^2=%.4e)...\n', ...
        iter, F_cheb, R_ref, F_total, g_c_norm^2);
    [c, mu, accepted] = A12_linesearch(c, g_c, R_ref, J_obs_perp_multi, ...
        lc, freqs, p, model, mu, B_op, voxel, inner, grid);

    if ~accepted
        fprintf('  [iter %d] [WARN] Zhang-Hager rejected (nonmonotone criterion), keeping c\n', iter);
    else
        update_log_accepted(log_path, iter);
        fprintf('  [iter %d] Zhang-Hager ACCEPTED (nonmonotone criterion)\n', iter);
    end
    last_accepted = accepted;  % H007-pm: track for forward cache
end

if ~state.converged
    state.iteration = p.max_iter;
    state.stop_reason = 'max_iter_reached';
    fprintf('\n[A12] Not converged in %d iters (hard upper bound), F_cheb final = %.4e\n', ...
        p.max_iter, state.history_residual(state.iteration));
end

% Final reconstruction
voxel.epsilon_r = B_op * c;
eps_re = real(voxel.epsilon_r);
eps_re = max(p.eps_r_min, min(p.eps_r_max, eps_re));
voxel.epsilon_r = eps_re;
voxel.epsilon_r(~inner) = 1.0;

state.epsilon_r = voxel.epsilon_r;
state.residual = state.history_residual(state.iteration);  % 暴露最终残差字段，供 run_inversion/run_experiment 诊断打印与 result_schema 使用
state.c = c;
state.mu_init = p.mu_init;
state.p_max_iter = p.max_iter;
state.p_eps_tol = p.eps_tol;
state.freqs = freqs;
state.N_freq = N_freq;
state.lc_k_dir = lc.k_dir;
state.lc_dOmega = lc.dOmega;

fprintf('\n[A12_inversion_loop] done, iter=%d, converged=%d\n', state.iteration, state.converged);
end

%% Helper
function update_log_accepted(log_path, iter)
    lines = readlines(log_path);
    if iter + 1 <= length(lines)
        line = lines{iter + 1};
        tokens = regexp(line, ',', 'split');
        if length(tokens) >= 14
            tokens{14} = '1';
            lines{iter + 1} = strjoin(tokens, ',');
            log_fid = fopen(log_path, 'w');
            for i = 1:length(lines)
                fprintf(log_fid, '%s\n', lines{i});
            end
            fclose(log_fid);
        end
    end
end
