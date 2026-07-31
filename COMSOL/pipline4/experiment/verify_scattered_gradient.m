function result = verify_scattered_gradient()
%VERIFY_SCATTERED_GRADIENT 用散射场 Es=E_total-E_b 计算梯度
%
%   假设: COMSOL FEM DOF 是散射场 Es，梯度 ∫Es·λ dV 应使用 Es
%   当前代码误用总场 E_total = emw.Ex
%
%   对比 3 种梯度公式:
%     1. E_total (当前): g = -k₀²·∫(E_total)·λ dV
%     2. E_scattered:    g = -k₀²·∫(E_total - E_b)·λ dV
%     3. E_scattered w/ adjoint λ from scattered solve

fprintf('\n========== 散射场梯度对比 ==========\n');

p = config();
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos_inner = voxel.pos(inner_idx, :);
L = 2 * p.R_inner;

% 正弦初值（损耗版，配置 B）
eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
eps_im_init = -2.0 + sin(2*pi*pos_inner(:,2) / L);
eps_re_true = 5.0; eps_im_true = -2.0;

%% 真值正演
voxel.epsilon_r(inner_idx) = eps_re_true + 1j * eps_im_true;
[~, ~, E_truth_gp] = solve_forward(model, voxel, p);

%% 初值正演
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;
[~, ~, E_hyp_gp] = solve_forward(model, voxel, p);

%% 伴随求解
[Je, ~, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
if ~adj_ok, result = struct('status','fail'); return; end

%% 计算散射场 Es = E_total - E_b
E_b = p.background.amplitude * p.background.polarization(:)';  % [0, 0, 1]
E_hyp_s = E_hyp_gp - repmat(E_b, size(E_hyp_gp, 1), 1);
fprintf('  |E_total| mean=%.4e, |E_s| mean=%.4e\n', ...
    mean(vecnorm(E_hyp_gp,2,2)), mean(vecnorm(E_hyp_s,2,2)));

%% 三种梯度
k0_sq = p.k0^2;
grad_re_total = zeros(N_inner, 1); grad_im_total = zeros(N_inner, 1);
grad_re_scat  = zeros(N_inner, 1); grad_im_scat  = zeros(N_inner, 1);

for vi = 1:N_inner
    gr = (4*(vi-1)+1):(4*vi);
    Lv = lambda_gauss(gr, :);
    gw = voxel.gauss_weights(gr);
    
    % 总场
    Ev_t = E_hyp_gp(gr, :);
    Z_t = 0;
    for gp = 1:4, Z_t = Z_t + gw(gp) * sum(Ev_t(gp,:) .* Lv(gp,:)); end
    grad_re_total(vi) = -k0_sq * real(Z_t);
    grad_im_total(vi) = -k0_sq * imag(Z_t);
    
    % 散射场
    Ev_s = E_hyp_s(gr, :);
    Z_s = 0;
    for gp = 1:4, Z_s = Z_s + gw(gp) * sum(Ev_s(gp,:) .* Lv(gp,:)); end
    grad_re_scat(vi) = -k0_sq * real(Z_s);
    grad_im_scat(vi) = -k0_sq * imag(Z_s);
end

%% 全局 FD
delta = 0.001;
eps_re_base = eps_re_init; eps_im_base = eps_im_init;

% ε' FD
voxel.epsilon_r(inner_idx) = (eps_re_base + delta) + 1j * eps_im_base;
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
voxel.epsilon_r(inner_idx) = (eps_re_base - delta) + 1j * eps_im_base;
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
fd_re = (F_p - F_m) / (2 * delta);

% ε'' FD
voxel.epsilon_r(inner_idx) = eps_re_base + 1j * (eps_im_base + delta);
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
voxel.epsilon_r(inner_idx) = eps_re_base + 1j * (eps_im_base - delta);
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
fd_im = (F_p - F_m) / (2 * delta);

%% 报告
fprintf('\n========== 梯度公式对比 (配置B, 损耗) ==========\n');
fprintf('  FD: ε'' = %+.6e, ε'''' = %+.6e\n\n', fd_re, fd_im);

% 总场
ar = sum(grad_re_total); ai = sum(grad_im_total);
fprintf('  [总场]   ε'' adj=%+.4e ratio=%+.4f sign=%s | ε'''' adj=%+.4e ratio=%+.4f sign=%s\n', ...
    ar, ar/fd_re, t2(sign(ar)==sign(fd_re)), ai, ai/fd_im, t2(sign(ai)==sign(fd_im)));

% 散射场
ar = sum(grad_re_scat); ai = sum(grad_im_scat);
fprintf('  [散射场] ε'' adj=%+.4e ratio=%+.4f sign=%s | ε'''' adj=%+.4e ratio=%+.4f sign=%s\n', ...
    ar, ar/fd_re, t2(sign(ar)==sign(fd_re)), ai, ai/fd_im, t2(sign(ai)==sign(fd_im)));

% 尝试 +k₀² (翻转符号)
ar2 = -sum(grad_re_scat); ai2 = -sum(grad_im_scat);
fprintf('  [散射场+] ε'' adj=%+.4e ratio=%+.4f sign=%s | ε'''' adj=%+.4e ratio=%+.4f sign=%s\n', ...
    ar2, ar2/fd_re, t2(sign(ar2)==sign(fd_re)), ai2, ai2/fd_im, t2(sign(ai2)==sign(fd_im)));

result = struct();
result.fd_re = fd_re; result.fd_im = fd_im;
result.grad_re_total = sum(grad_re_total);
result.grad_im_total = sum(grad_im_total);
result.grad_re_scat = sum(grad_re_scat);
result.grad_im_scat = sum(grad_im_scat);

save(fullfile(p.dir_result, 'verify_scattered_gradient.mat'), 'result', '-v7.3');
fprintf('\n  结果已保存\n');
end

function s = t2(c), if c, s='✓'; else, s='✗'; end, end
