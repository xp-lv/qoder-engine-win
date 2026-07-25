function [c_new, mu_next, accepted] = C01_linesearch(c, g_c, F_data_old, J_obs_perp_multi, lc, freqs, p, model, mu, B_op, voxel, inner, grid, eps_im_min, eps_im_max)
%C01_LINESEARCH Complex c-space simple descent with max-norm normalization
%   Identical algorithm to B03_linesearch (proven correct in B03).
%   c and g_c are complex. Step: c_new = c - mu * g_norm_dir
%   Normalization: g_norm_dir = g_c / max|g_c| (max-norm, mu = per-component step)
%   Acceptance: F_data_try < F_data_old (simple descent)

N_freq = length(freqs);
inner_mask = voxel.mask_interior;

% Gradient normalization: max-norm
g_max = max(abs(g_c));
if g_max > 0
    g_norm_dir = g_c / g_max;
else
    g_norm_dir = g_c;
end

c_old = c(:);
accepted = false;

for trial = 1:p.ls_max_trials
    c_try = c_old - mu * g_norm_dir;

    voxel_try = voxel;
    voxel_try.epsilon_r = B_op * c_try;
    eps_re = real(voxel_try.epsilon_r);
    eps_im = imag(voxel_try.epsilon_r);
    eps_re = max(p.eps_r_min, min(p.eps_r_max, eps_re));
    eps_im = max(eps_im_min, min(eps_im_max, eps_im));
    voxel_try.epsilon_r = eps_re + 1i * eps_im;
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

    fprintf('    [LS trial=%d] mu=%.6f, F_data=%.4e (old=%.4e), dF=%.4e', ...
        trial, mu, F_data_try, F_data_old, F_data_try - F_data_old);

    if F_data_try < F_data_old
        fprintf('  accept\n');
        c_new = c_try;
        accepted = true;
        break;
    else
        fprintf('  reject\n');
        mu = mu * p.ls_decay;
    end
end

if ~accepted
    mu_next = max(p.mu_init * 0.5, p.mu_min);
    c_new = c_old;
    fprintf('    [LS] all %d trials failed, mu_next=%.6f\n', p.ls_max_trials, mu_next);
else
    mu_next = min(mu * 1.5, p.mu_max);
end

end
