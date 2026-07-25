function C01_postprocess(state, lc, J_obs_perp_multi, freqs, p)
%C01_POSTPROCESS Uniform complex sphere inversion post-processing
%   6 judges: P1 Re_mean, P2 Im_mean, P3 F_cheb, P4 cos_theta, P5 Re_std, P6 Im_std

dir_out = p.dir_result_C01;
N_iter = state.iteration;

fprintf('\n=== C01 Post-process ===\n');

%% 1. Convergence plot (F_cheb + cos_theta)
fig1 = figure('Name','C01 Convergence','NumberTitle','off','Visible','off');

subplot(2,1,1);
semilogy(1:N_iter, state.history_residual(1:N_iter), 'o-', 'LineWidth', 2);
xlabel('Iteration'); ylabel('F_{cheb} (data residual)');
title('C01 F_{cheb} Convergence (Uniform Complex)');
grid on; set(gca, 'FontSize', 12);

subplot(2,1,2);
plot(1:N_iter, state.history_cos_theta(1:N_iter), 's-', 'LineWidth', 2, 'Color', [0.85 0.33 0.1]);
xlabel('Iteration'); ylabel('cos \theta');
title('Gradient Alignment');
grid on; set(gca, 'FontSize', 12);

saveas(fig1, fullfile(dir_out, 'C01_fig1_convergence.png'));
close(fig1);
fprintf('  Saved: C01_fig1_convergence.png\n');

%% 2. Re/Im mean evolution (with true lines)
fig2 = figure('Name','C01 Re/Im Mean','NumberTitle','off','Visible','off');

subplot(2,1,1);
plot(1:N_iter, state.history_inner_mean_re(1:N_iter), 'o-', 'LineWidth', 2, 'Color', [0.00 0.45 0.74]);
yline(p.eps_r_true_re, '--', 'true', 'Color', [0.00 0.45 0.74], 'Alpha', 0.7);
xlabel('Iteration'); ylabel('Re(\epsilon_r) mean');
title('C01 Re(\epsilon_r) Inner Mean');
grid on; set(gca, 'FontSize', 12);

subplot(2,1,2);
plot(1:N_iter, state.history_inner_mean_im(1:N_iter), 's-', 'LineWidth', 2, 'Color', [0.85 0.33 0.1]);
yline(p.eps_r_true_im, '--', 'true', 'Color', [0.85 0.33 0.1], 'Alpha', 0.7);
xlabel('Iteration'); ylabel('Im(\epsilon_r) mean');
title('C01 Im(\epsilon_r) Inner Mean (Loss)');
grid on; set(gca, 'FontSize', 12);

saveas(fig2, fullfile(dir_out, 'C01_fig2_re_im_mean.png'));
close(fig2);
fprintf('  Saved: C01_fig2_re_im_mean.png\n');

%% 3. Re/Im std evolution (uniformity check)
fig3 = figure('Name','C01 Re/Im Std','NumberTitle','off','Visible','off');

subplot(2,1,1);
plot(1:N_iter, state.history_inner_std_re(1:N_iter), 'o-', 'LineWidth', 2, 'Color', [0.00 0.45 0.74]);
yline(0.10, '--', 'threshold', 'Color', [0.5 0.5 0.5], 'Alpha', 0.7);
xlabel('Iteration'); ylabel('Re(\epsilon_r) std');
title('C01 Re(\epsilon_r) Inner Std (uniformity)');
grid on; set(gca, 'FontSize', 12);

subplot(2,1,2);
plot(1:N_iter, state.history_inner_std_im(1:N_iter), 's-', 'LineWidth', 2, 'Color', [0.85 0.33 0.1]);
yline(0.10, '--', 'threshold', 'Color', [0.5 0.5 0.5], 'Alpha', 0.7);
xlabel('Iteration'); ylabel('Im(\epsilon_r) std');
title('C01 Im(\epsilon_r) Inner Std (uniformity)');
grid on; set(gca, 'FontSize', 12);

saveas(fig3, fullfile(dir_out, 'C01_fig3_re_im_std.png'));
close(fig3);
fprintf('  Saved: C01_fig3_re_im_std.png\n');

%% 4. 6 Judges
fprintf('\n=== C01 Judges ===\n');

best_iter = find(state.history_residual == min(state.history_residual(1:N_iter)), 1);
F_best = state.history_residual(best_iter);
inner_mean_re = state.history_inner_mean_re(best_iter);
inner_mean_im = state.history_inner_mean_im(best_iter);
inner_std_re = state.history_inner_std_re(best_iter);
inner_std_im = state.history_inner_std_im(best_iter);
cos_best = state.history_cos_theta(best_iter);

fprintf('  Best iteration: %d\n', best_iter);
fprintf('  F_cheb:         %.4e (target < 0.05)\n', F_best);
fprintf('  Re(eps_r) mean: %.4f (true=%.1f, target 5.0 +/- 0.5)\n', inner_mean_re, p.eps_r_true_re);
fprintf('  Im(eps_r) mean: %.4f (true=%.1f, target -5.0 +/- 1.5)\n', inner_mean_im, p.eps_r_true_im);
fprintf('  Re(eps_r) std:  %.4f (target < 0.10)\n', inner_std_re);
fprintf('  Im(eps_r) std:  %.4f (target < 0.10)\n', inner_std_im);
fprintf('  cos_theta:      %.4f (target > 0.90)\n', cos_best);

% Judges table (6 criteria)
judges = struct();
judges.P1_re_mean  = abs(inner_mean_re - p.eps_r_true_re) < 0.5;
judges.P2_im_mean  = abs(inner_mean_im - p.eps_r_true_im) < 1.5;
judges.P3_F_cheb   = F_best < 0.05;
judges.P4_cos      = cos_best > 0.90;
judges.P5_re_std   = inner_std_re < 0.10;
judges.P6_im_std   = inner_std_im < 0.10;

n_pass = sum([judges.P1_re_mean, judges.P2_im_mean, judges.P3_F_cheb, ...
              judges.P4_cos, judges.P5_re_std, judges.P6_im_std]);

fprintf('\n  P1 Re mean 5.0+/-0.5:  %s\n', ternary(judges.P1_re_mean, 'PASS', 'FAIL'));
fprintf('  P2 Im mean -5.0+/-1.5: %s\n', ternary(judges.P2_im_mean, 'PASS', 'FAIL'));
fprintf('  P3 F_cheb < 0.05:      %s\n', ternary(judges.P3_F_cheb, 'PASS', 'FAIL'));
fprintf('  P4 cos > 0.90:         %s\n', ternary(judges.P4_cos, 'PASS', 'FAIL'));
fprintf('  P5 Re std < 0.10:      %s\n', ternary(judges.P5_re_std, 'PASS', 'FAIL'));
fprintf('  P6 Im std < 0.10:      %s\n', ternary(judges.P6_im_std, 'PASS', 'FAIL'));
fprintf('  Total: %d/6 PASS\n', n_pass);

state.judges = judges;
state.n_pass = n_pass;
state.best_iter = best_iter;

%% 5. Save summary
summary_path = fullfile(dir_out, 'C01_summary.txt');
fid = fopen(summary_path, 'w');
fprintf(fid, 'C01 Uniform Complex Sphere Inversion Summary\n');
fprintf(fid, '=============================================\n');
fprintf(fid, 'True model: eps_r = %.1f %+.1fj (uniform, all inner)\n', ...
    p.eps_r_true_re, p.eps_r_true_im);
fprintf(fid, 'B-spline: %dx%dx%d = %d control points\n', p.n_cx, p.n_cy, p.n_cz, p.n_cx*p.n_cy*p.n_cz);
fprintf(fid, 'Frequency: %.1f GHz (single)\n', freqs(1)/1e9);
fprintf(fid, 'Iterations: %d (max %d)\n', N_iter, p.max_iter);
fprintf(fid, 'Converged: %s\n', ternary(state.converged, 'YES', 'NO'));
fprintf(fid, 'Best iter: %d\n', best_iter);
fprintf(fid, 'F_cheb: %.4e\n', F_best);
fprintf(fid, 'Re(eps_r) mean: %.4f (true=%.1f)\n', inner_mean_re, p.eps_r_true_re);
fprintf(fid, 'Im(eps_r) mean: %.4f (true=%.1f)\n', inner_mean_im, p.eps_r_true_im);
fprintf(fid, 'Re(eps_r) std: %.4f\n', inner_std_re);
fprintf(fid, 'Im(eps_r) std: %.4f\n', inner_std_im);
fprintf(fid, 'cos_theta: %.4f\n', cos_best);
fprintf(fid, 'Pass: %d/6\n', n_pass);
fclose(fid);
fprintf('  Saved: C01_summary.txt\n');

fprintf('\n=== C01 Post-process DONE ===\n');

end

function s = ternary(cond, a, b)
    if cond, s = a; else, s = b; end
end
