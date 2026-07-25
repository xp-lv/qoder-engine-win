function [c_new, mu_next, accepted] = A12_linesearch(c, g_c, R_ref, J_obs_perp_multi, lc, freqs, p, model, mu, B_op, voxel, inner, grid)
%A12_LINESEARCH c-space Zhang-Hager nonmonotone line search (H004 upgrade)
%   H004: Armijo monotone → Zhang-Hager nonmonotone
%
%   H003 问题诊断：Armijo 单调条件 f(x_k+αd) ≤ f(x_k)+c₁α∇fᵀd 在 iter=3 起
%   全 8 trial reject（c₁=0.1 过严 + 单调参考值随残差下降而收紧），
%   致使残差精确冻结（连续 7 步 |Δr|=0）。
%
%   H004 修复：以近期残差衰减加权平均 R_k 替代当前 f(x_k) 作为步长接受参考值。
%   R_k = η_ls·R_{k-1} + (1-η_ls)·f(x_k)，η_ls=0.85（R_ref 由调用方维护并传入）。
%   接受准则：F_data_try ≤ R_ref + c₁·α·∇fᵀd ≈ R_ref - c₁·μ·||g_c||²
%   c₁=0.0001（远小于 H003 的 0.1），配合 R_k ≥ f(x_k) 使接受条件显著放宽。
%   理论收敛保证：Zhang & Hager 2004，η_ls=0.85 下 R_k 仍呈整体下降趋势。
%
%   Zhang-Hager: F_data_try <= R_ref - c1 * mu * ||g_c||^2  (nonmonotone, F_data-only)

N_freq = length(freqs);
inner_mask = voxel.mask_interior;

% Gradient normalization (step direction) - TV still in gradient
g_rms = sqrt(mean(g_c .* g_c));
if g_rms > 0
    g_norm_dir = g_c / g_rms;
else
    g_norm_dir = g_c;
end
g_norm_dir = max(-p.grad_clip, min(p.grad_clip, g_norm_dir));
g_norm_sq = sum(g_c .* g_c);

c_old = c(:);
accepted = false;

for trial = 1:p.ls_max_trials
    c_try = c_old - mu * g_norm_dir;

    voxel_try = voxel;
    voxel_try.epsilon_r = B_op * c_try;
    eps_re = real(voxel_try.epsilon_r);
    eps_re = max(p.eps_r_min, min(p.eps_r_max, eps_re));
    voxel_try.epsilon_r = eps_re;
    voxel_try.epsilon_r(~inner_mask) = 1.0;

    F_data_try = 0;
    all_forward_ok = true;

    for fi = 1:N_freq
        p_freq = p;
        p_freq.freq = freqs(fi);
        p_freq.omega = 2*pi*p_freq.freq;
        p_freq.k0 = p_freq.omega / p_freq.c;
        p_freq.lambda = p_freq.c / p_freq.freq;

        try
            [E_try, ~, ~] = solve_forward(model, voxel_try, p_freq);
        catch ME
            fprintf('    [LS trial=%d freq=%d] forward failed: %s\n', trial, fi, ME.message);
            all_forward_ok = false;
            break;
        end

        if isempty(E_try)
            all_forward_ok = false;
            break;
        end

        sf = extract_scattered(model, grid);
        lc_new = lightcone_project(grid, sf, p_freq);
        J_hyp = lc_new.J_obs_perp;

        J_obs_fi = J_obs_perp_multi{fi};
        Delta_J = J_obs_fi - J_hyp;
        J_obs_per_d_norm_sq = sum(abs(J_obs_fi).^2, 2);
        Delta_J_per_d_norm_sq = sum(abs(Delta_J).^2, 2);
        J_obs_safe = max(J_obs_per_d_norm_sq, p.rel_err_floor);
        F_k_fi = Delta_J_per_d_norm_sq ./ J_obs_safe / 6;

        F_data_try = F_data_try + mean(F_k_fi) / N_freq;
    end

    if ~all_forward_ok
        fprintf('    [LS trial=%d] forward failed, mu *= %.2f\n', trial, p.ls_decay);
        mu = mu * p.ls_decay;
        continue;
    end

    % TV cost (trial) - computed for reporting only, NOT used in acceptance
    [~, R_tv_try, ~] = exp07a_tv_reg(voxel_try, c_try, p, B_op);
    F_total_try = F_data_try + p.lambda_tv * R_tv_try;  % for reporting

    % H004 KEY CHANGE: Zhang-Hager nonmonotone acceptance
    % 接受准则: F_data_try <= R_ref - c1 * mu * ||g_c||^2
    % R_ref 为近期残差衰减加权平均（由 A12_inversion_loop 维护并传入）
    armijo_c1 = 0.0001;
    if isfield(p, 'ls_armijo_c1'), armijo_c1 = p.ls_armijo_c1; end
    zh_rhs = R_ref - armijo_c1 * mu * g_norm_sq;

    fprintf('    [LS trial=%d] mu=%.6f, F_data=%.4e, R_TV=%.4e, F_total=%.4e (R_ref=%.4e), ZH_rhs=%.4e', ...
        trial, mu, F_data_try, R_tv_try, F_total_try, R_ref, zh_rhs);

    if F_data_try <= zh_rhs
        fprintf('  accept (Zhang-Hager nonmonotone)\n');
        c_new = c_try;
        accepted = true;
        break;
    else
        fprintf('  reject\n');
        mu = mu * p.ls_decay;
        % H005-fix: micro-step early termination
        %   当 mu 衰减至 ls_mu_floor 以下时，步长变化已低于 mphinterp
        %   数值灵敏度阈值，F_data 将精确冻结（|ΔF|<1e-5），继续
        %   halving 纯属浪费正演求解（每次 3 freq × ~20s）。
        %   H005 iter 7/10 各 8 trial 全 reject 中后 4-5 次均属此类。
        ls_mu_floor = 1e-4;
        if isfield(p, 'ls_mu_floor'), ls_mu_floor = p.ls_mu_floor; end
        if mu < ls_mu_floor
            fprintf('  → micro-step early termination (mu=%.2e < floor=%.1e), skipping remaining trials\n', ...
                mu, ls_mu_floor);
            break;
        end
    end
end

if ~accepted
    mu_next = max(p.mu_init * 0.5, p.mu_min);
    c_new = c_old;
    fprintf('    [LS] all %d trials failed, mu_next=%.4f\n', p.ls_max_trials, mu_next);
else
    mu_next = min(mu * 2, p.mu_max);
end

end
