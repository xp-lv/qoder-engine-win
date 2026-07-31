function result = verify_away_voxels()
%VERIFY_AWAY_VOXELS 对背离真值的体素做 FD vs 伴随梯度对比
%
%   从 gradient_scattered.mat 中找出背离/混合体素，
%   对每个体素做 FD（全局代价，单体素扰动），对比伴随梯度

fprintf('\n========== 背离体素 FD 对比 ==========\n');

p = config();
data = load(fullfile(p.dir_result, 'gradient_scattered.mat'));
r = data.result;

eps_re_true = 5.0; eps_im_true = -2.0;

diff_re = r.eps_re_init - eps_re_true;
diff_im = r.eps_im_init - eps_im_true;
N = length(diff_re);

% 朝向/背离判断
toward_re = sign(r.grad_re) == sign(diff_re);
toward_im = sign(r.grad_im) == sign(diff_im);

% 背离: 至少一个分量背离
away_mask = ~toward_re | ~toward_im;
away_idx = find(away_mask);
N_away = length(away_idx);

fprintf('  总体素: %d, 背离(至少一个分量): %d (%.1f%%)\n', N, N_away, 100*N_away/N);

%% COMSOL 连接
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

%% 重建网格和场（因为 .mat 只存了梯度，没存完整状态）
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
pos_inner = voxel.pos(inner_idx, :);
L = 2 * p.R_inner;

eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
eps_im_init = -2.0 + sin(2*pi*pos_inner(:,2) / L);

% 真值正演
voxel.epsilon_r(inner_idx) = eps_re_true + 1j * eps_im_true;
[~, ~, E_truth_gp] = solve_forward(model, voxel, p);

% 初值正演
voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;
[~, ~, E_hyp_gp] = solve_forward(model, voxel, p);

%% 选 10 个背离体素（随机）
rng(77);
if N_away > 10
    sel = away_idx(randperm(N_away, 10));
else
    sel = away_idx;
end
N_sel = length(sel);
fprintf('  随机选 %d 个背离体素做 FD\n\n', N_sel);

delta = 0.01;
k0_sq = p.k0^2;
E_b = p.background.amplitude * p.background.polarization(:)';
eps_re_base = eps_re_init; eps_im_base = eps_im_init;

%% 表头
fprintf('  ===============================================================================================\n');
fprintf('  #  vi   ε''_init ε''_true  ε''_dir  ε''_adj     ε''_FD      ratio  sign | ε''''_init ε''''_true ε''''_dir  ε''''_adj    ε''''_FD     ratio  sign\n');
fprintf('  ===============================================================================================\n');

results = struct();
for k = 1:N_sel
    vi = sel(k);
    idx = inner_idx(vi);
    pos_i = pos_inner(vi, :);
    
    % 伴随梯度（从 .mat 读取）
    adj_re = r.grad_re(vi);
    adj_im = r.grad_im(vi);
    
    % ε' 方向标签
    if sign(adj_re) == sign(diff_re(vi))
        dir_re_str = '背离';
    else
        dir_re_str = '朝向';
    end
    if sign(adj_im) == sign(diff_im(vi))
        dir_im_str = '背离';
    else
        dir_im_str = '朝向';
    end
    
    % --- ε' FD（全局代价，单体素扰动）---
    voxel.epsilon_r(inner_idx) = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = (eps_re_base(vi) + delta) + 1j * eps_im_base(vi);
    solve_forward(model, voxel, p);
    [E_p, ~] = read_field(model, voxel.gauss_pos);
    F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    
    voxel.epsilon_r(inner_idx) = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = (eps_re_base(vi) - delta) + 1j * eps_im_base(vi);
    solve_forward(model, voxel, p);
    [E_m, ~] = read_field(model, voxel.gauss_pos);
    F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    fd_re = (F_p - F_m) / (2 * delta);
    
    ratio_re = adj_re / fd_re;
    sign_re = sign(fd_re) == sign(adj_re);
    
    % --- ε'' FD ---
    voxel.epsilon_r(inner_idx) = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = eps_re_base(vi) + 1j * (eps_im_base(vi) + delta);
    solve_forward(model, voxel, p);
    [E_p, ~] = read_field(model, voxel.gauss_pos);
    F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    
    voxel.epsilon_r(inner_idx) = eps_re_base + 1j * eps_im_base;
    voxel.epsilon_r(idx) = eps_re_base(vi) + 1j * (eps_im_base(vi) - delta);
    solve_forward(model, voxel, p);
    [E_m, ~] = read_field(model, voxel.gauss_pos);
    F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    fd_im = (F_p - F_m) / (2 * delta);
    
    ratio_im = adj_im / fd_im;
    sign_im = sign(fd_im) == sign(adj_im);
    
    % FD 方向标签
    if sign(fd_re) == sign(diff_re(vi))
        fd_dir_re = '背离';
    else
        fd_dir_re = '朝向';
    end
    if sign(fd_im) == sign(diff_im(vi))
        fd_dir_im = '背离';
    else
        fd_dir_im = '朝向';
    end
    
    fprintf('  %2d %4d  %+.3f  %+.1f   %-4s  %+9.3e %+9.3e %6.2f   %s |  %+.3f   %+.1f    %-4s  %+9.3e %+9.3e %6.2f   %s\n', ...
        k, vi, eps_re_init(vi), eps_re_true, dir_re_str, ...
        adj_re, fd_re, ratio_re, t2(sign_re), ...
        eps_im_init(vi), eps_im_true, dir_im_str, ...
        adj_im, fd_im, ratio_im, t2(sign_im));
    
    results(k).vi = vi;
    results(k).pos = pos_i;
    results(k).adj_re = adj_re; results(k).adj_im = adj_im;
    results(k).fd_re = fd_re; results(k).fd_im = fd_im;
    results(k).ratio_re = ratio_re; results(k).ratio_im = ratio_im;
    results(k).sign_re = sign_re; results(k).sign_im = sign_im;
    results(k).dir_re = dir_re_str; results(k).dir_im = dir_im_str;
    results(k).fd_dir_re = fd_dir_re; results(k).fd_dir_im = fd_dir_im;
end
fprintf('  ===============================================================================================\n');

%% 总结
re_signs = [results.sign_re];
im_signs = [results.sign_im];
re_ratios = [results.ratio_re];
im_ratios = [results.ratio_im];

fprintf('\n========== 背离体素总结 (%d 个) ==========\n', N_sel);
fprintf('  伴随梯度 ε'' sign 匹配 FD: %d/%d\n', sum(re_signs), N_sel);
fprintf('  伴随梯度 ε'''' sign 匹配 FD: %d/%d\n', sum(im_signs), N_sel);
fprintf('  ε''  ratio: mean=%+.3f, range=[%+.3f, %+.3f]\n', mean(re_ratios), min(re_ratios), max(re_ratios));
fprintf('  ε'''' ratio: mean=%+.3f, range=[%+.3f, %+.3f]\n', mean(im_ratios), min(im_ratios), max(im_ratios));

% FD 也背离的体素数
fd_also_away_re = sum(strcmp([results.fd_dir_re], '背离'));
fd_also_away_im = sum(strcmp([results.fd_dir_im], '背离'));
fprintf('\n  FD 也确认背离的体素:\n');
fprintf('    ε''  FD 也背离: %d/%d\n', fd_also_away_re, N_sel);
fprintf('    ε'''' FD 也背离: %d/%d\n', fd_also_away_im, N_sel);

if all(re_signs) && all(im_signs)
    fprintf('\n  ★ sign 全部匹配 — 伴随梯度的"背离"方向也是 FD 确认的真实方向\n');
    fprintf('  → 梯度计算精确，"背离"来自代价函数的局部地形（非全局凸）\n');
else
    fprintf('\n  部分不匹配 — 需进一步分析\n');
end

result = struct();
result.results = results;
result.N_away_total = N_away;
result.N_total = N;
save(fullfile(p.dir_result, 'verify_away_voxels.mat'), 'result', '-v7.3');
fprintf('\n  结果已保存\n');
end

function s = t2(c), if c, s='✓'; else, s='✗'; end, end
