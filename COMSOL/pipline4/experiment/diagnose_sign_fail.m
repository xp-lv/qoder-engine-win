function result = diagnose_sign_fail()
%DIAGNOSE_SIGN_FAIL 诊断非均匀场景下 sign 失败的根因
%
%   策略：
%   1. 正弦初值下，选 5 个 sign 失败的体素
%   2. 对每个体素，用多步长 FD (0.1→0.001) 看 sign 是否收敛
%   3. 同时做全局均匀扰动 FD（已知 sign PASS）作为基准

fprintf('\n========== 非均匀场景 sign 失败诊断 ==========\n');

p = config();
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

%% 网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos_inner = voxel.pos(inner_idx, :);

%% 正弦初值
L = 2 * p.R_inner;
eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
eps_im_init = 2.0 + sin(2*pi*pos_inner(:,2) / L);
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;

eps_re_true = 5.0; eps_im_true = -2.0;

%% 真值 + 初值正演
voxel_truth = voxel;
voxel_truth.epsilon_r(inner_idx) = eps_re_true + 1j * eps_im_true;
[~, ~, E_truth_gp] = solve_forward(model, voxel_truth, p);
[~, ~, E_hyp_gp] = solve_forward(model, voxel, p);

%% 伴随梯度
[Je, ~, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
if ~adj_ok, result = struct('status','fail'); return; end

k0_sq = p.k0^2;
grad_re = zeros(N_inner, 1);
grad_im = zeros(N_inner, 1);
for vi = 1:N_inner
    gr = (4*(vi-1)+1):(4*vi);
    Ev = E_hyp_gp(gr, :); Lv = lambda_gauss(gr, :); gw = voxel.gauss_weights(gr);
    EL = 0;
    for gp = 1:4, EL = EL + gw(gp) * sum(Ev(gp,:) .* Lv(gp,:)); end
    grad_re(vi) = -k0_sq * real(EL);
    grad_im(vi) = -k0_sq * imag(EL);
end

%% 保存基础 epsilon
eps_re_base = real(voxel.epsilon_r);
eps_im_base = imag(voxel.epsilon_r);

%% 选 5 个体素做多步长 FD
% 选梯度绝对值较大、且 diff 方向不同的体素
diff_re = eps_re_init - eps_re_true;
[~, sort_idx] = sort(abs(grad_re), 'descend');
sel = sort_idx(1:20);  % 取梯度最大的 20 个
sel = sel(randperm(length(sel), 5));  % 随机选 5 个

deltas = [0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001];

fprintf('\n--- ε'' 多步长 FD 诊断 ---\n');
fprintf('  #   ε''_init  diff    伴随grad     ');
for d = deltas, fprintf('  δ=%.3f   ', d); end
fprintf('\n');

for k = 1:5
    vi = sel(k);
    idx = inner_idx(vi);
    adj_val = grad_re(vi);
    
    fprintf('  %d  %+.3f  %+.3f  %+10.4e  ', k, eps_re_init(vi), diff_re(vi), adj_val);
    
    for di = 1:length(deltas)
        delta = deltas(di);
        
        % +δ
        voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
        voxel.epsilon_r(idx) = eps_re_base(idx) + delta;
        solve_forward(model, voxel, p);
        [E_p, ~] = read_field(model, voxel.gauss_pos);
        F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
              sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
        
        % -δ
        voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
        voxel.epsilon_r(idx) = eps_re_base(idx) - delta;
        solve_forward(model, voxel, p);
        [E_m, ~] = read_field(model, voxel.gauss_pos);
        F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
              sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
        
        fd_val = (F_p - F_m) / (2 * delta);
        fprintf('%+9.3e ', fd_val);
    end
    fprintf('\n');
end

%% ε'' 同样诊断
fprintf('\n--- ε'''' 多步长 FD 诊断 ---\n');
fprintf('  #   ε''''_init  diff    伴随grad     ');
for d = deltas, fprintf('  δ=%.3f   ', d); end
fprintf('\n');

diff_im = eps_im_init - eps_im_true;
[~, sort_idx_im] = sort(abs(grad_im), 'descend');
sel_im = sort_idx_im(1:20);
sel_im = sel_im(randperm(length(sel_im), 5));

for k = 1:5
    vi = sel_im(k);
    idx = inner_idx(vi);
    adj_val = grad_im(vi);
    
    fprintf('  %d  %+.3f  %+.3f  %+10.4e  ', k, eps_im_init(vi), diff_im(vi), adj_val);
    
    for di = 1:length(deltas)
        delta = deltas(di);
        
        voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
        voxel.epsilon_r(idx) = eps_re_base(idx) + 1j * (eps_im_base(idx) + delta);
        solve_forward(model, voxel, p);
        [E_p, ~] = read_field(model, voxel.gauss_pos);
        F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
              sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
        
        voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
        voxel.epsilon_r(idx) = eps_re_base(idx) + 1j * (eps_im_base(idx) - delta);
        solve_forward(model, voxel, p);
        [E_m, ~] = read_field(model, voxel.gauss_pos);
        F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
              sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
        
        fd_val = (F_p - F_m) / (2 * delta);
        fprintf('%+9.3e ', fd_val);
    end
    fprintf('\n');
end

%% 全局均匀扰动 FD 作为基准
fprintf('\n--- 全局均匀扰动 FD (基准) ---\n');
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;

% 全局 ε' FD
delta_g = 0.001;
voxel.epsilon_r(inner_idx) = (eps_re_init + delta_g) + 1j * eps_im_init;
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));

voxel.epsilon_r(inner_idx) = (eps_re_init - delta_g) + 1j * eps_im_init;
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));

fd_global_re = (F_p - F_m) / (2 * delta_g);
adj_global_re = sum(grad_re);

fprintf('  ε''  全局伴随 = %+.6e\n', adj_global_re);
fprintf('  ε''  全局 FD   = %+.6e (δ=%.4f)\n', fd_global_re, delta_g);
fprintf('  ε''  全局 ratio = %.4f, sign=%s\n\n', adj_global_re/fd_global_re, ...
    ternary(sign(fd_global_re)==sign(adj_global_re), '✓', '✗'));

% 全局 ε'' FD
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * (eps_im_init + delta_g);
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));

voxel.epsilon_r(inner_idx) = eps_re_init + 1j * (eps_im_init - delta_g);
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
      sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));

fd_global_im = (F_p - F_m) / (2 * delta_g);
adj_global_im = sum(grad_im);

fprintf('  ε'''' 全局伴随 = %+.6e\n', adj_global_im);
fprintf('  ε'''' 全局 FD   = %+.6e (δ=%.4f)\n', fd_global_im, delta_g);
fprintf('  ε'''' 全局 ratio = %.4f, sign=%s\n', adj_global_im/fd_global_im, ...
    ternary(sign(fd_global_im)==sign(adj_global_im), '✓', '✗'));

%% 总结
fprintf('\n========== 诊断结论 ==========\n');
fprintf('  如果全局 FD sign ✓ 而单体素 sign ✗：\n');
fprintf('  → 逐体素梯度**总和**正确，但**分配**到各体素的相对值有偏差\n');
fprintf('  → 这对应非均匀 ε_r 下 K 矩阵耦合使局部梯度与全局梯度方向不一致\n');

result = struct();
result.fd_global_re = fd_global_re;
result.fd_global_im = fd_global_im;
result.adj_global_re = adj_global_re;
result.adj_global_im = adj_global_im;

save(fullfile(p.dir_result, 'diagnose_sign_fail.mat'), 'result', '-v7.3');
end

function s = ternary(c, v1, v2)
    if c, s = v1; else, s = v2; end
end
