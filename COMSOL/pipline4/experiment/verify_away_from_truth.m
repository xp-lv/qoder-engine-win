function result = verify_away_from_truth()
%VERIFY_AWAY_FROM_TRUTH 找梯度方向"背离真值"的体素，做 FD 对比
%
%   "背离真值"定义：梯度下降步 ε ← ε - α·∇F 会把 ε 推离真值
%   即 sign(grad) == sign(ε_init - ε_true)
%
%   真值: ε_r = 5 - 2j（均匀）
%   初值: ε_re = 5 + sin(2πx/L), ε_im = 2 + sin(2πy/L)

fprintf('\n========== 背离真值体素的 FD 对比 ==========\n');
fprintf('  真值: ε_r = 5.0 - 2.0j\n');
fprintf('  初值: ε_re = 5 + sin(2πx/L) ∈ [4,6]\n');
fprintf('         ε_im = 2 + sin(2πy/L) ∈ [1,3]\n\n');

p = config();

%% 1. COMSOL 连接
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

%% 2. FEM 网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos_inner = voxel.pos(inner_idx, :);

%% 3. 正弦初值
L = 2 * p.R_inner;
eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
eps_im_init = 2.0 + sin(2*pi*pos_inner(:,2) / L);
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;

eps_re_true = 5.0;
eps_im_true = -2.0;

%% 4. 真值正演 + 初值正演 + 伴随梯度
fprintf('--- 真值正演 ---\n');
voxel_truth = voxel;
voxel_truth.epsilon_r(inner_idx) = eps_re_true + 1j * eps_im_true;
[~, ~, E_truth_gp] = solve_forward(model, voxel_truth, p);

fprintf('\n--- 初值正演 ---\n');
[~, ~, E_hyp_gp] = solve_forward(model, voxel, p);

fprintf('\n--- 伴随求解 ---\n');
[Je, F_norm, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
if ~adj_ok
    fprintf('  ✗ 伴随求解失败\n');
    result = struct('status', 'adjoint_failed');
    return;
end

%% 5. 逐体素梯度
k0_sq = p.k0^2;
grad_re = zeros(N_inner, 1);
grad_im = zeros(N_inner, 1);
for vi = 1:N_inner
    gr = (4*(vi-1)+1):(4*vi);
    Ev = E_hyp_gp(gr, :);
    Lv = lambda_gauss(gr, :);
    gw = voxel.gauss_weights(gr);
    EL_dot = 0;
    for gp = 1:4
        EL_dot = EL_dot + gw(gp) * sum(Ev(gp,:) .* Lv(gp,:));
    end
    grad_re(vi) = -k0_sq * real(EL_dot);
    grad_im(vi) = -k0_sq * imag(EL_dot);
end

%% 6. 筛选"背离真值"体素
% ε' 背离: sign(grad_re) == sign(eps_re_init - eps_re_true)
% ε'' 背离: sign(grad_im) == sign(eps_im_init - eps_im_true)
diff_re = eps_re_init - eps_re_true;  % ε_re_init - 5
diff_im = eps_im_init - eps_im_true;  % ε_im_init - (-2) = ε_im_init + 2

away_re = sign(grad_re) == sign(diff_re);  % 背离（实部）
away_im = sign(grad_im) == sign(diff_im);  % 背离（虚部）

N_away_re = sum(away_re);
N_away_im = sum(away_im);
fprintf('\n--- 背离真值体素统计 ---\n');
fprintf('  ε''  背离: %d/%d (%.1f%%)\n', N_away_re, N_inner, 100*N_away_re/N_inner);
fprintf('  ε'''' 背离: %d/%d (%.1f%%)\n', N_away_im, N_inner, 100*N_away_im/N_inner);

%% 7. 从背离体素中选 5 个做 FD 验证
rng(123);
delta = 0.01;

% ε' 背离体素
if N_away_re >= 5
    sel_re = find(away_re);
    sel_re = sel_re(randperm(length(sel_re), min(5, length(sel_re))));
else
    sel_re = find(away_re);
end

% ε'' 背离体素
if N_away_im >= 5
    sel_im = find(away_im);
    sel_im = sel_im(randperm(length(sel_im), min(5, length(sel_im))));
else
    sel_im = find(away_im);
end

fprintf('\n--- ε'' 背离体素 FD 对比 (δ=%.3f) ---\n', delta);
fprintf('  #    ε''_init  ε''_true  diff    伴随grad    FD_grad     ratio   sign  FD方向\n');
fprintf('  ------------------------------------------------------------------------------\n');

fd_re_results = struct();
for k = 1:length(sel_re)
    vi = sel_re(k);
    idx = inner_idx(vi);
    
    % 伴随梯度
    adj_val = grad_re(vi);
    
    % FD（全局代价，仅扰动该体素）
    eps_re_base = real(voxel.epsilon_r);
    eps_im_base = imag(voxel.epsilon_r);
    
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
    ratio = adj_val / fd_val;
    sign_ok = sign(fd_val) == sign(adj_val);
    
    % FD 方向是否也背离真值
    fd_away = sign(fd_val) == sign(diff_re(vi));
    
    fprintf('  %2d   %+.3f    %+.3f    %+.3f   %+10.3e  %+10.3e  %7.3f    %s    %s\n', ...
        k, eps_re_init(vi), eps_re_true, diff_re(vi), ...
        adj_val, fd_val, ratio, ...
        ternary(sign_ok,'✓','✗'), ternary(fd_away,'背离','朝向'));
    
    fd_re_results(k).vi = vi;
    fd_re_results(k).adj = adj_val;
    fd_re_results(k).fd = fd_val;
    fd_re_results(k).ratio = ratio;
    fd_re_results(k).sign_ok = sign_ok;
    fd_re_results(k).fd_away = fd_away;
end

fprintf('\n--- ε'''' 背离体素 FD 对比 (δ=%.3f) ---\n', delta);
fprintf('  #    ε''''_init  ε''''_true  diff    伴随grad    FD_grad     ratio   sign  FD方向\n');
fprintf('  ------------------------------------------------------------------------------\n');

fd_im_results = struct();
for k = 1:length(sel_im)
    vi = sel_im(k);
    idx = inner_idx(vi);
    
    adj_val = grad_im(vi);
    
    eps_re_base = real(voxel.epsilon_r);
    eps_im_base = imag(voxel.epsilon_r);
    
    % +δ (虚部)
    voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = eps_re_base(idx) + 1j * (eps_im_base(idx) + delta);
    solve_forward(model, voxel, p);
    [E_p, ~] = read_field(model, voxel.gauss_pos);
    F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    
    % -δ
    voxel.epsilon_r = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = eps_re_base(idx) + 1j * (eps_im_base(idx) - delta);
    solve_forward(model, voxel, p);
    [E_m, ~] = read_field(model, voxel.gauss_pos);
    F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    
    fd_val = (F_p - F_m) / (2 * delta);
    ratio = adj_val / fd_val;
    sign_ok = sign(fd_val) == sign(adj_val);
    fd_away = sign(fd_val) == sign(diff_im(vi));
    
    fprintf('  %2d   %+.3f    %+.3f    %+.3f   %+10.3e  %+10.3e  %7.3f    %s    %s\n', ...
        k, eps_im_init(vi), eps_im_true, diff_im(vi), ...
        adj_val, fd_val, ratio, ...
        ternary(sign_ok,'✓','✗'), ternary(fd_away,'背离','朝向'));
    
    fd_im_results(k).vi = vi;
    fd_im_results(k).adj = adj_val;
    fd_im_results(k).fd = fd_val;
    fd_im_results(k).ratio = ratio;
    fd_im_results(k).sign_ok = sign_ok;
    fd_im_results(k).fd_away = fd_away;
end

%% 8. 总结
re_signs = [fd_re_results.sign_ok];
im_signs = [fd_im_results.sign_ok];
re_fd_away = [fd_re_results.fd_away];
im_fd_away = [fd_im_results.fd_away];

fprintf('\n========== 总结 ==========\n');
fprintf('  伴随梯度 ε''  背离真值体素: %d/%d\n', N_away_re, N_inner);
fprintf('  伴随梯度 ε'''' 背离真值体素: %d/%d\n', N_away_im, N_inner);
fprintf('\n  FD 验证 (背离体素子集):\n');
fprintf('    ε''  sign match: %d/%d, FD 也背离: %d/%d\n', ...
    sum(re_signs), length(re_signs), sum(re_fd_away), length(re_fd_away));
fprintf('    ε'''' sign match: %d/%d, FD 也背离: %d/%d\n', ...
    sum(im_signs), length(im_signs), sum(im_fd_away), length(im_fd_away));

if all(re_signs) && all(im_signs)
    fprintf('\n  ★★★ sign ALL PASS ★★★ FD 与伴随梯度方向完全一致\n');
    fprintf('  → 即使梯度方向"背离真值"，FD 也确认了同样的方向\n');
    fprintf('  → 这说明梯度计算本身是正确的，"背离"来自代价函数的局部地形\n');
else
    fprintf('\n  sign 不完全匹配 — 需进一步分析\n');
end

result = struct();
result.N_away_re = N_away_re;
result.N_away_im = N_away_im;
result.fd_re_results = fd_re_results;
result.fd_im_results = fd_im_results;

save(fullfile(p.dir_result, 'verify_away_from_truth.mat'), 'result', '-v7.3');
fprintf('\n  结果已保存\n');

end

function s = ternary(cond, v1, v2)
    if cond, s = v1; else, s = v2; end
end
