function result = analyze_systematic_error()
%ANALYZE_SYSTEMATIC_ERROR 系统性误差根源分析
%
%   对同一场景（正弦-损耗），分别测试 6 种公式组合:
%     A) bilinear + E_total + 标准公式   g=-k₀²·[Re;Im](Z)
%     B) bilinear + E_total + Re/Im交换  g=+k₀²·[Im;Re](Z)
%     C) hermitian + E_total + 标准公式  g=-k₀²·[Re;Im](Z)
%     D) hermitian + E_total + Re/Im交换 g=+k₀²·[Im;Re](Z)
%     E) bilinear + Es + Re/Im交换       g=+k₀²·[Im;Re](Zs)
%     F) hermitian + Es + 标准公式        g=-k₀²·[Re;Im](Zs)
%
%   找出哪种组合的 ratio 最接近 1

fprintf('\n========== 系统性误差根源分析 ==========\n');
fprintf('  场景: 正弦-损耗 (ε_re∈[4,6], ε_im∈[-3,-1] → 5-2j)\n\n');

p = config();
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos_inner = voxel.pos(inner_idx, :);
L = 2 * p.R_inner;
k0_sq = p.k0^2;

eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
eps_im_init = -2.0 + sin(2*pi*pos_inner(:,2) / L);
eps_re_true = 5.0; eps_im_true = -2.0;

% 真值正演
voxel.epsilon_r(inner_idx) = eps_re_true + 1j * eps_im_true;
[~, ~, E_truth_gp] = solve_forward(model, voxel, p);

% 初值正演
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;
[~, ~, E_hyp_gp] = solve_forward(model, voxel, p);

% 伴随求解
[Je, ~, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
if ~adj_ok, result = struct('status','fail'); return; end

% 散射场
E_b = p.background.amplitude * p.background.polarization(:)';
E_hyp_s = E_hyp_gp - repmat(E_b, size(E_hyp_gp, 1), 1);

% 计算两种内积积分
Z_bilinear_total = 0;  % bilinear, E_total
Z_herm_total = 0;       % hermitian, E_total
Z_bilinear_scat = 0;    % bilinear, Es
Z_herm_scat = 0;         % hermitian, Es

for vi = 1:N_inner
    gr = (4*(vi-1)+1):(4*vi);
    Et = E_hyp_gp(gr, :);   % E_total
    Es = E_hyp_s(gr, :);    % E_scattered
    Lv = lambda_gauss(gr, :);
    gw = voxel.gauss_weights(gr);
    for gp = 1:4
        w = gw(gp);
        Z_bilinear_total = Z_bilinear_total + w * sum(Et(gp,:) .* Lv(gp,:));
        Z_herm_total     = Z_herm_total     + w * sum(conj(Et(gp,:)) .* Lv(gp,:));
        Z_bilinear_scat  = Z_bilinear_scat  + w * sum(Es(gp,:) .* Lv(gp,:));
        Z_herm_scat      = Z_herm_scat      + w * sum(conj(Es(gp,:)) .* Lv(gp,:));
    end
end

% FD
delta = 0.001;

% ε' FD
voxel.epsilon_r(inner_idx) = (eps_re_init + delta) + 1j * eps_im_init;
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
voxel.epsilon_r(inner_idx) = (eps_re_init - delta) + 1j * eps_im_init;
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
fd_re = (F_p - F_m) / (2 * delta);

% ε'' FD
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * (eps_im_init + delta);
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * (eps_im_init - delta);
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
fd_im = (F_p - F_m) / (2 * delta);

fprintf('  FD: ε'' = %+.6e, ε'''' = %+.6e\n\n', fd_re, fd_im);

%% 6 种公式对比
% 每种: [g_re, g_im]
formulas = {
    'A: bilinear+E_total+标准',  -k0_sq*real(Z_bilinear_total), -k0_sq*imag(Z_bilinear_total);
    'B: bilinear+E_total+交换',  +k0_sq*imag(Z_bilinear_total), +k0_sq*real(Z_bilinear_total);
    'C: hermitian+E_total+标准', -k0_sq*real(Z_herm_total),     -k0_sq*imag(Z_herm_total);
    'D: hermitian+E_total+交换', +k0_sq*imag(Z_herm_total),     +k0_sq*real(Z_herm_total);
    'E: bilinear+Es+交换',       +k0_sq*imag(Z_bilinear_scat),  +k0_sq*real(Z_bilinear_scat);
    'F: hermitian+Es+标准',      -k0_sq*real(Z_herm_scat),      -k0_sq*imag(Z_herm_scat);
    'G: hermitian+Es+交换',      +k0_sq*imag(Z_herm_scat),      +k0_sq*real(Z_herm_scat);
    'H: bilinear+Es+标准',       -k0_sq*real(Z_bilinear_scat),  -k0_sq*imag(Z_bilinear_scat);
};

fprintf('  公式                            ε'' ratio   ε'' sign | ε'''' ratio  ε'''' sign\n');
fprintf('  --------------------------------------------------------------------------\n');
best_ratio_sum = 1e10;
best_name = '';
for i = 1:size(formulas,1)
    name = formulas{i,1};
    g_re = formulas{i,2};
    g_im = formulas{i,3};
    rr = g_re / fd_re;
    ri = g_im / fd_im;
    sr = sign(g_re) == sign(fd_re);
    si = sign(g_im) == sign(fd_im);
    fprintf('  %-32s  %+8.4f   %s     |  %+8.4f   %s\n', name, rr, t2(sr), ri, t2(si));
    
    dist = abs(rr - 1) + abs(ri - 1);
    if dist < best_ratio_sum
        best_ratio_sum = dist;
        best_name = name;
    end
end
fprintf('\n  ★ 最佳: %s (|ratio-1| 之和 = %.4f)\n', best_name, best_ratio_sum);

%% Wirtinger 因子测试（对最佳公式乘 2）
fprintf('\n--- Wirtinger 因子 2x 测试 ---\n');
for i = 1:size(formulas,1)
    name = formulas{i,1};
    g_re = 2 * formulas{i,2};
    g_im = 2 * formulas{i,3};
    rr = g_re / fd_re;
    ri = g_im / fd_im;
    sr = sign(g_re) == sign(fd_re);
    si = sign(g_im) == sign(fd_im);
    fprintf('  2x%-30s  %+8.4f   %s     |  %+8.4f   %s\n', name, rr, t2(sr), ri, t2(si));
end

%% 积分值对比
fprintf('\n--- 积分值 Z 对比 ---\n');
fprintf('  Z(bilinear,E_total) = %+.6e %+.6ei\n', real(Z_bilinear_total), imag(Z_bilinear_total));
fprintf('  Z(hermitian,E_total)= %+.6e %+.6ei\n', real(Z_herm_total), imag(Z_herm_total));
fprintf('  Z(bilinear,Es)      = %+.6e %+.6ei\n', real(Z_bilinear_scat), imag(Z_bilinear_scat));
fprintf('  Z(hermitian,Es)     = %+.6e %+.6ei\n', real(Z_herm_scat), imag(Z_herm_scat));

result = struct();
result.fd_re = fd_re; result.fd_im = fd_im;
result.Z_bilinear_total = Z_bilinear_total;
result.Z_herm_total = Z_herm_total;
result.Z_bilinear_scat = Z_bilinear_scat;
result.Z_herm_scat = Z_herm_scat;
result.best_name = best_name;

save(fullfile(p.dir_result, 'analyze_systematic_error.mat'), 'result', '-v7.3');
fprintf('\n  结果已保存\n');
end

function s = t2(c), if c, s='✓'; else, s='✗'; end, end
