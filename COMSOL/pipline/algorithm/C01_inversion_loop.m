function state = C01_inversion_loop(voxel, lc, J_obs_perp_multi, freqs, grid, model, p, B_op, c_init)
%C01_INVERSION_LOOP Complex eps_r inversion for uniform sphere
%   Based on B03_inversion_loop, with hollow/flesh statistics removed.
%   Tracks: inner_mean_re, inner_mean_im, inner_std_re, inner_std_im
%
%   Key: c is complex, gradient is complex
%   g_complex = -k0^2 * dV * dot(E, lambda) (complex-valued)
%   Re(g) = dF/d(eps'),  Im(g) = dF/d(eps_imag)

N_freq = length(freqs);
N_k = size(J_obs_perp_multi{1}, 1);
N_c = size(B_op, 2);
inner = voxel.mask_interior;
N_v = length(voxel.epsilon_r);
N_inner = sum(inner);

eps_im_min = -p.eps_r_imag_max;
eps_im_max = 0.0;

fprintf('\n[C01_loop] start, max_iter=%d, N_freq=%d, N_c=%d\n', p.max_iter, N_freq, N_c);
fprintf('[C01_loop] N_inner=%d (all uniform target=%.1f%+.1fj)\n', ...
    N_inner, p.eps_r_true_re, p.eps_r_true_im);
fprintf('[C01_loop] Complex c: Re clip [%.1f, %.1f], Im clip [%.1f, %.1f]\n', ...
    p.eps_r_min, p.eps_r_max, eps_im_min, eps_im_max);
fprintf('[C01_loop] Simple descent (lambda_tv=%.4f)\n', p.lambda_tv);

%% Initialize history
state.history_F_k          = zeros(N_k, p.max_iter);
state.history_residual     = zeros(p.max_iter, 1);
state.history_inner_mean_re = zeros(p.max_iter, 1);
state.history_inner_mean_im = zeros(p.max_iter, 1);
state.history_inner_std_re  = zeros(p.max_iter, 1);
state.history_inner_std_im  = zeros(p.max_iter, 1);
state.history_cos_theta    = zeros(p.max_iter, 1);
state.history_worst_F_k    = zeros(p.max_iter, 1);
state.history_c_re         = zeros(N_c, p.max_iter);
state.history_c_im         = zeros(N_c, p.max_iter);
state.history_eps_r_max    = zeros(p.max_iter, 1);
state.history_eps_r_min    = zeros(p.max_iter, 1);
state.history_eps_i_max    = zeros(p.max_iter, 1);
state.history_eps_i_min    = zeros(p.max_iter, 1);
state.history_F_k_per_freq = zeros(N_freq, p.max_iter);
state.history_g_data_norm  = zeros(p.max_iter, 1);

state.converged = false;
state.iteration = 0;
state.algorithm = 'C01_uniform_complex_inversion';
state.N_c = N_c;
mu = p.mu_init;

%% CSV log
log_path = fullfile(p.dir_result_C01, 'C01_inversion_log.csv');
log_fid = fopen(log_path, 'w');
if log_fid == -1
    error('[C01] Cannot open log: %s', log_path);
end
fprintf(log_fid, 'iter,F_cheb,mean_F_k,worst_F_k,worst_k,mean_cos_theta,inner_re_mean,inner_re_std,inner_im_mean,inner_im_std,eps_re_min,eps_re_max,eps_im_min,eps_im_max,mu,time_s,accepted,c_re_mean,c_im_mean,g_data_norm\n');
fclose(log_fid);

%% c-space initialization (complex)
c = c_init(:);

%% Precompute inner indices and Gauss info
inner_idx = find(inner);
use_gauss = ~isempty(voxel.gauss_pos) && size(voxel.gauss_pos, 1) == 4 * N_inner;
gauss_w = voxel.gauss_w;

%% Main loop
for iter = 1:p.max_iter
    tic;
    fprintf('\n--- C01 iter %d/%d (mu=%.4f, N_freq=%d, N_c=%d) ---\n', iter, p.max_iter, mu, N_freq, N_c);

    %% 1. Reconstruct voxel eps_r from complex c
    voxel.epsilon_r = B_op * c;
    eps_re = real(voxel.epsilon_r);
    eps_im = imag(voxel.epsilon_r);
    eps_re = max(p.eps_r_min, min(p.eps_r_max, eps_re));
    eps_im = max(eps_im_min, min(eps_im_max, eps_im));
    voxel.epsilon_r = eps_re + 1i * eps_im;
    voxel.epsilon_r(~inner) = 1.0;

    %% 2. Multi-freq forward + F_k + complex adjoint gradient
    g_voxel_complex = complex(zeros(N_v, 1));
    F_k_total = zeros(N_k, 1);
    cos_theta_sum = 0;
    J_hyp_primary = [];
    F_k_per_freq = zeros(N_freq, 1);

    for fi = 1:N_freq
        p.freq = freqs(fi);
        p.omega = 2*pi*p.freq;
        p.k0 = p.omega / p.c;
        p.lambda = p.c / p.freq;

        fprintf('  [iter %d freq=%d (%.0f GHz)] forward solve (complex eps_r)...\n', iter, fi, freqs(fi)/1e9);

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

        J_obs_norm = sqrt(sum(abs(J_obs_fi).^2, 2)) + p.rel_err_floor;
        J_hyp_norm = sqrt(sum(abs(J_hyp).^2, 2)) + p.rel_err_floor;
        cos_theta_fi = real(sum(conj(J_obs_fi) .* J_hyp, 2)) ./ (J_obs_norm .* J_hyp_norm);
        cos_theta_sum = cos_theta_sum + mean(cos_theta_fi) / N_freq;

        if fi == 1
            J_hyp_primary = J_hyp;
        end

        fprintf('  [iter %d freq=%d] F_k mean=%.4e, max=%.4e, cos=%.3f\n', ...
            iter, fi, mean(F_k_fi), max(F_k_fi), mean(cos_theta_fi));

        %% Adjoint solve
        fprintf('  [iter %d freq=%d] adjoint solve...\n', iter, fi);
        lc.k_vec = p.k0 * lc.k_dir;
        lc.J_obs_perp = J_obs_fi;
        lc.Delta_J_perp = Delta_J ./ J_obs_safe;
        [f_adj, source_pos, F_obs_lc] = build_adjoint_source_fullmaxwell(grid, lc, p);
        [lambda_fi, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos);

        if ~adj_ok
            fprintf('  [iter %d freq=%d] [WARN] adjoint failed, skipping\n', iter, fi);
            continue;
        end

        %% Complex gradient: g = -k0^2 * dV * dot(E, lambda)
        k0_sq = p.k0^2;
        dV_vec = voxel.dV;

        E_vox = zeros(N_v, 3);
        E_vox(inner, :) = E_total;
        lambda_vox = zeros(N_v, 3);
        lambda_vox(inner, :) = lambda_fi;

        if use_gauss && ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
                && size(E_gauss, 1) == size(voxel.gauss_pos, 1)
            % Gauss quadrature (complex)
            for vi = 1:N_inner
                v_idx = inner_idx(vi);
                gp_range = (4*(vi-1)+1):(4*vi);
                gs_complex = 0;
                for gpi = 1:4
                    Eg = E_gauss(gp_range(gpi), :);
                    Lg = lambda_gauss(gp_range(gpi), :);
                    gs_complex = gs_complex + gauss_w(gpi) * dot(Eg, Lg);
                end
                g_voxel_complex(v_idx) = g_voxel_complex(v_idx) - k0_sq * dV_vec(v_idx) * gs_complex / N_freq;
            end
        else
            % Centroid approximation (complex)
            for vi = 1:N_inner
                v_idx = inner_idx(vi);
                Ev = E_vox(v_idx, :);
                Lv = lambda_vox(v_idx, :);
                g_voxel_complex(v_idx) = g_voxel_complex(v_idx) - k0_sq * dV_vec(v_idx) * dot(Ev, Lv) / N_freq;
            end
        end

        fprintf('  [iter %d freq=%d] |g_complex| mean=%.4e, max=%.4e\n', ...
            iter, fi, mean(abs(g_voxel_complex(inner))), max(abs(g_voxel_complex(inner))));
    end

    %% 3. Chain rule: complex voxel gradient -> complex c gradient
    g_data_c = B_op' * g_voxel_complex;
    g_data_norm = norm(g_data_c);
    g_c = g_data_c;

    fprintf('  [TV] lambda_tv=%.4f (disabled), ||g_data_c||=%.3e\n', p.lambda_tv, g_data_norm);

    %% 4. Aggregate statistics
    F_cheb = mean(F_k_total);
    [F_max_k, worst_idx] = max(F_k_total);
    mean_cos_theta = cos_theta_sum;

    % Inner statistics (uniform target, no hollow/flesh split)
    eps_inner_re = real(voxel.epsilon_r(inner));
    eps_inner_im = imag(voxel.epsilon_r(inner));
    inner_mean_re = mean(eps_inner_re);
    inner_mean_im = mean(eps_inner_im);
    inner_std_re = std(eps_inner_re);
    inner_std_im = std(eps_inner_im);

    % Store history
    state.history_residual(iter) = F_cheb;
    state.history_F_k(:, iter) = F_k_total;
    state.history_J_hyp = J_hyp_primary;
    state.history_eps_inner_re(:, iter) = eps_inner_re;
    state.history_eps_inner_im(:, iter) = eps_inner_im;
    state.history_eps_r_max(iter) = max(eps_inner_re);
    state.history_eps_r_min(iter) = min(eps_inner_re);
    state.history_eps_i_max(iter) = max(eps_inner_im);
    state.history_eps_i_min(iter) = min(eps_inner_im);
    state.history_inner_mean_re(iter) = inner_mean_re;
    state.history_inner_mean_im(iter) = inner_mean_im;
    state.history_inner_std_re(iter) = inner_std_re;
    state.history_inner_std_im(iter) = inner_std_im;
    state.history_worst_F_k(iter) = F_max_k;
    state.history_cos_theta(iter) = mean_cos_theta;
    state.history_F_k_per_freq(:, iter) = F_k_per_freq;
    state.history_c_re(:, iter) = real(c);
    state.history_c_im(:, iter) = imag(c);
    state.history_g_data_norm(iter) = g_data_norm;

    fprintf('  [iter %d] AGG: F=%.4e, cos=%.3f, inner_re=[%.3f+/-%.3f], inner_im=[%.3f+/-%.3f], c_re=%.3f, c_im=%.3f, t=%.1fs\n', ...
        iter, F_cheb, mean_cos_theta, ...
        inner_mean_re, inner_std_re, inner_mean_im, inner_std_im, ...
        mean(real(c)), mean(imag(c)), toc);

    % CSV log
    log_fid = fopen(log_path, 'a');
    fprintf(log_fid, '%d,%.6e,%.6e,%.6e,%d,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.6f,%.1f,%d,%.4f,%.4f,%.6e', ...
        iter, F_cheb, F_cheb, F_max_k, worst_idx, mean_cos_theta, ...
        inner_mean_re, inner_std_re, inner_mean_im, inner_std_im, ...
        state.history_eps_r_min(iter), state.history_eps_r_max(iter), ...
        state.history_eps_i_min(iter), state.history_eps_i_max(iter), ...
        mu, toc, 0, mean(real(c)), mean(imag(c)), g_data_norm);
    fprintf(log_fid, '\n');
    fclose(log_fid);

    if F_cheb < p.eps_tol && iter >= 3
        fprintf('  [iter %d] Converged: F_cheb = %.4e < %.4e (min_iter=3 satisfied)\n', iter, F_cheb, p.eps_tol);
        state.converged = true;
        state.iteration = iter;
        update_log_accepted(log_path, iter);
        break;
    end

    %% 5. Complex c-space linesearch (simple descent)
    fprintf('  [iter %d] C01_linesearch (F_data=%.4e, ||g_c||^2=%.4e)...\n', ...
        iter, F_cheb, g_data_norm^2);
    [c, mu, accepted] = C01_linesearch(c, g_c, F_cheb, J_obs_perp_multi, ...
        lc, freqs, p, model, mu, B_op, voxel, inner, grid, eps_im_min, eps_im_max);

    if ~accepted
        fprintf('  [iter %d] [WARN] linesearch rejected, keeping c\n', iter);
    else
        update_log_accepted(log_path, iter);
        fprintf('  [iter %d] linesearch ACCEPTED\n', iter);
    end
end

if ~state.converged
    state.iteration = p.max_iter;
    fprintf('\n[C01] Not converged in %d iters, F_cheb final = %.4e\n', ...
        p.max_iter, state.history_residual(state.iteration));
end

% Final reconstruction
voxel.epsilon_r = B_op * c;
eps_re = real(voxel.epsilon_r);
eps_im = imag(voxel.epsilon_r);
eps_re = max(p.eps_r_min, min(p.eps_r_max, eps_re));
eps_im = max(eps_im_min, min(eps_im_max, eps_im));
voxel.epsilon_r = eps_re + 1i * eps_im;
voxel.epsilon_r(~inner) = 1.0;

state.epsilon_r = voxel.epsilon_r;
state.c = c;
state.mu_init = p.mu_init;
state.p_max_iter = p.max_iter;
state.p_eps_tol = p.eps_tol;
state.freqs = freqs;
state.N_freq = N_freq;
state.lc_k_dir = lc.k_dir;
state.lc_dOmega = lc.dOmega;
state.eps_im_min = eps_im_min;
state.eps_im_max = eps_im_max;

fprintf('\n[C01_inversion_loop] done, iter=%d, converged=%d\n', state.iteration, state.converged);
end

%% Helper
function update_log_accepted(log_path, iter)
    lines = readlines(log_path);
    if iter + 1 <= length(lines)
        line = lines{iter + 1};
        tokens = regexp(line, ',', 'split');
        if length(tokens) >= 17
            tokens{17} = '1';
            lines{iter + 1} = strjoin(tokens, ',');
            log_fid = fopen(log_path, 'w');
            for i = 1:length(lines)
                fprintf(log_fid, '%s\n', lines{i});
            end
            fclose(log_fid);
        end
    end
end
