function results = verify_fd_multi(n_runs)
%VERIFY_FD_MULTI 多轮 FD 验证，每轮使用不同的随机体素子集
%
%   用法:
%     >> setup(); verify_fd_multi(3);  % 运行 3 轮
%
%   每轮随机选择 60%-100% 的内部体素，验证 ratio≡1 的鲁棒性。

if nargin < 1, n_runs = 3; end

fprintf('\n========== pipline4 多轮 FD 验证 (%d 轮) ==========\n', n_runs);

p = config();
results = struct();

for run = 1:n_runs
    fprintf('\n########## 第 %d 轮 (随机种子=%d) ##########\n', run, run);
    rng(run);  % 可复现随机种子

    r = verify_fd_single_run(p, run);
    results(run).run = run;
    results(run).ratio_re = r.ratio_re;
    results(run).ratio_im = r.ratio_im;
    results(run).g_re = r.g_re;
    results(run).g_im = r.g_im;
    results(run).fd_re = r.fd_re;
    results(run).fd_im = r.fd_im;
    results(run).re_sign = r.re_sign_ok;
    results(run).im_sign = r.im_sign_ok;
    results(run).n_subset = r.n_subset;
    results(run).n_total = r.n_total;
end

%% 总结
fprintf('\n\n========== 多轮总结 ==========\n');
fprintf('轮次  体素子集   ε'' ratio   ε'''' ratio  ε'' sign  ε'''' sign\n');
fprintf('----  ---------  ---------  ----------  -------  -------\n');
for run = 1:n_runs
    r = results(run);
    fprintf('  %d   %4d/%4d  %8.4f   %8.4f    %s       %s\n', ...
        run, r.n_subset, r.n_total, ...
        r.ratio_re, r.ratio_im, ...
        ternary(r.re_sign, '✓', '✗'), ternary(r.im_sign, '✓', '✗'));
end

% 统计
all_re_sign = all([results.re_sign]);
all_im_sign = all([results.im_sign]);
re_ratios = [results.ratio_re];
im_ratios = [results.ratio_im];

fprintf('\n  ε'' ratio: mean=%.4f, std=%.4f, range=[%.4f, %.4f]\n', ...
    mean(re_ratios), std(re_ratios), min(re_ratios), max(re_ratios));
fprintf('  ε'''' ratio: mean=%.4f, std=%.4f, range=[%.4f, %.4f]\n', ...
    mean(im_ratios), std(im_ratios), min(im_ratios), max(im_ratios));

if all_re_sign && all_im_sign && all(abs(re_ratios - 1) < 0.2) && all(abs(im_ratios - 1) < 0.2)
    fprintf('\n  ★★★ ALL RUNS PASS ★★★ ratio ≡ 1 鲁棒性验证通过！\n');
else
    fprintf('\n  部分轮次 ratio 偏差较大 — 需进一步诊断\n');
end

save(fullfile(p.dir_result, 'verify_fd_multi.mat'), 'results', '-v7.3');
fprintf('  结果已保存\n');

end

%% ===== 单轮测试（使用随机体素子集） =====
function result = verify_fd_single_run(p, seed)
% 使用随机选择的体素子集进行 FD 验证

fprintf('\n--- COMSOL 连接 ---\n');
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

fprintf('--- FEM 网格提取 ---\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_pos = voxel.pos(inner, :);
N_inner = sum(inner);

%% 随机选择体素子集
% 每轮选择 60%-100% 的内部体素
select_frac = 0.6 + 0.4 * rand();
N_select = max(10, round(N_inner * select_frac));
select_idx = randperm(N_inner, N_select);

% 创建选择掩码（用于代价函数和梯度计算）
gp_select = false(size(voxel.gauss_pos, 1), 1);
for si = 1:N_select
    % 每个内部 tet 有 4 个 Gauss 点
    gr = (4*(select_idx(si)-1)+1):(4*select_idx(si));
    gp_select(gr) = true;
end

N_gp_total = sum(gp_select);
fprintf('  随机体素子集: %d/%d (%.0f%%), Gauss 点: %d/%d\n', ...
    N_select, N_inner, 100*N_select/N_inner, ...
    N_gp_total, size(voxel.gauss_pos, 1));

%% 真值正演 → E_truth (Gauss 点)
fprintf('--- 真值正演 ---\n');
voxel.epsilon_r(inner) = p.eps_r_true;
[~, ~, E_truth_gauss] = solve_forward(model, voxel, p);

%% 初值正演 → E_hyp (Gauss 点)
fprintf('--- 初值正演 ---\n');
voxel.epsilon_r(inner) = p.eps_r_init;
[~, ~, E_hyp_gauss] = solve_forward(model, voxel, p);

%% 伴随梯度（Gauss 积分，使用子集）
fprintf('--- 伴随梯度计算 ---\n');

% 构建子集 voxel 结构（仅用于 build_adjoint_source 和 compute_gradient）
voxel_sub = voxel;
voxel_sub.gauss_pos = voxel.gauss_pos(gp_select, :);
voxel_sub.gauss_weights = voxel.gauss_weights(gp_select);

[Je, F_norm, ~] = build_adjoint_source_nearfield(voxel_sub, ...
    E_hyp_gauss(gp_select, :), E_truth_gauss(gp_select, :), p, true);

% 伴随源仍使用全部体素中心（COMSOL 需要完整覆盖）
[lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);

if ~adj_ok
    result = struct('status', 'adjoint_failed');
    return;
end

[g, g_re, g_im] = compute_gradient(voxel_sub, ...
    E_hyp_gauss(gp_select, :), lambda, p, lambda_gauss(gp_select, :));

%% FD 验证
fprintf('--- FD 中心差分 ---\n');

% ε' FD (使用最小步长)
delta = p.fd_deltas_re(end);
voxel.epsilon_r(inner) = (p.eps_r_init_re + delta) + 1j * p.eps_r_init_im;
solve_forward(model, voxel, p);
[E_plus_gp, ~] = read_field(model, voxel.gauss_pos);
F_plus = compute_cost(voxel_sub, E_plus_gp(gp_select, :), E_truth_gauss(gp_select, :), p, true);

voxel.epsilon_r(inner) = (p.eps_r_init_re - delta) + 1j * p.eps_r_init_im;
solve_forward(model, voxel, p);
[E_minus_gp, ~] = read_field(model, voxel.gauss_pos);
F_minus = compute_cost(voxel_sub, E_minus_gp(gp_select, :), E_truth_gauss(gp_select, :), p, true);

fd_re = (F_plus - F_minus) / (2 * delta);

% ε'' FD
delta_im = p.fd_deltas_im(end);
voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im + delta_im);
solve_forward(model, voxel, p);
[E_plus_gp, ~] = read_field(model, voxel.gauss_pos);
F_plus = compute_cost(voxel_sub, E_plus_gp(gp_select, :), E_truth_gauss(gp_select, :), p, true);

voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im - delta_im);
solve_forward(model, voxel, p);
[E_minus_gp, ~] = read_field(model, voxel.gauss_pos);
F_minus = compute_cost(voxel_sub, E_minus_gp(gp_select, :), E_truth_gauss(gp_select, :), p, true);

fd_im = (F_plus - F_minus) / (2 * delta);

%% 报告
ratio_re = g_re / fd_re;
ratio_im = g_im / fd_im;
re_sign = (sign(fd_re) == sign(g_re));
im_sign = (sign(fd_im) == sign(g_im));

fprintf('  ε''  adj=%+.4e, FD=%+.4e, ratio=%.4f, sign=%s\n', ...
    g_re, fd_re, ratio_re, ternary(re_sign, '✓', '✗'));
fprintf('  ε'''' adj=%+.4e, FD=%+.4e, ratio=%.4f, sign=%s\n', ...
    g_im, fd_im, ratio_im, ternary(im_sign, '✓', '✗'));

result = struct();
result.g_re = g_re;
result.g_im = g_im;
result.fd_re = fd_re;
result.fd_im = fd_im;
result.ratio_re = ratio_re;
result.ratio_im = ratio_im;
result.re_sign_ok = re_sign;
result.im_sign_ok = im_sign;
result.n_subset = N_select;
result.n_total = N_inner;

end

function s = ternary(cond, val_true, val_false)
    if cond, s = val_true; else, s = val_false; end
end
