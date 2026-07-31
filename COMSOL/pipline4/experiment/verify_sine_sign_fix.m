function result = verify_sine_sign_fix()
%VERIFY_SINE_SIGN_FIX 统一虚部符号后的 ratio 对比
%
%   测试两种初值:
%     A) ε_im = +2 + sin(2πy/L) ∈ [1,3]（增益，与真值符号相反）
%     B) ε_im = -2 + sin(2πy/L) ∈ [-3,-1]（损耗，与真值符号一致）
%
%   真值: ε_r = 5 - 2j
%
%   对每种初值做全局 FD ratio 对比

fprintf('\n========== 正弦初值虚部符号对比 ==========\n');
fprintf('  真值: ε_r = 5.0 - 2.0j\n');

p = config();
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos_inner = voxel.pos(inner_idx, :);
L = 2 * p.R_inner;

eps_re_true = 5.0; eps_im_true = -2.0;

%% 真值正演
voxel.epsilon_r(inner_idx) = eps_re_true + 1j * eps_im_true;
[~, ~, E_truth_gp] = solve_forward(model, voxel, p);

%% 对两种初值做测试
configs = struct();
configs(1).name = 'A: 虚部+（增益）';
configs(1).eps_im = 2.0 + sin(2*pi*pos_inner(:,2) / L);      % [1, 3]

configs(2).name = 'B: 虚部-（损耗）';
configs(2).eps_im = -2.0 + sin(2*pi*pos_inner(:,2) / L);     % [-3, -1]

delta = 0.001;

for ci = 1:2
    fprintf('\n########## 配置 %s ##########\n', configs(ci).name);
    eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);  % [4, 6]
    eps_im_init = configs(ci).eps_im;
    voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;
    
    fprintf('  ε_re 范围: [%.2f, %.2f]\n', min(eps_re_init), max(eps_re_init));
    fprintf('  ε_im 范围: [%.2f, %.2f]\n', min(eps_im_init), max(eps_im_init));
    
    %% 初值正演
    [~, ~, E_hyp_gp] = solve_forward(model, voxel, p);
    
    %% 伴随梯度
    [Je, ~, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
    [lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
    if ~adj_ok, fprintf('  ✗ 伴随失败\n'); continue; end
    
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
    adj_re_sum = sum(grad_re);
    adj_im_sum = sum(grad_im);
    
    %% 全局 FD ε'
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
    
    %% 全局 FD ε''
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
    
    %% 报告
    ratio_re = adj_re_sum / fd_re;
    ratio_im = adj_im_sum / fd_im;
    sign_re = sign(fd_re) == sign(adj_re_sum);
    sign_im = sign(fd_im) == sign(adj_im_sum);
    
    fprintf('  ε''  伴随 = %+.6e, FD = %+.6e, ratio = %+.4f, sign = %s\n', ...
        adj_re_sum, fd_re, ratio_re, ternary(sign_re,'✓','✗'));
    fprintf('  ε'''' 伴随 = %+.6e, FD = %+.6e, ratio = %+.4f, sign = %s\n', ...
        adj_im_sum, fd_im, ratio_im, ternary(sign_im,'✓','✗'));
    
    configs(ci).adj_re = adj_re_sum;
    configs(ci).adj_im = adj_im_sum;
    configs(ci).fd_re = fd_re;
    configs(ci).fd_im = fd_im;
    configs(ci).ratio_re = ratio_re;
    configs(ci).ratio_im = ratio_im;
    configs(ci).sign_re = sign_re;
    configs(ci).sign_im = sign_im;
end

%% 总结
fprintf('\n========== 符号对比总结 ==========\n');
fprintf('  配置A (增益 ε''>0): ε'' ratio = %+.4f sign=%s | ε'''' ratio = %+.4f sign=%s\n', ...
    configs(1).ratio_re, ternary(configs(1).sign_re,'✓','✗'), ...
    configs(1).ratio_im, ternary(configs(1).sign_im,'✓','✗'));
fprintf('  配置B (损耗 ε''<0): ε'' ratio = %+.4f sign=%s | ε'''' ratio = %+.4f sign=%s\n', ...
    configs(2).ratio_re, ternary(configs(2).sign_re,'✓','✗'), ...
    configs(2).ratio_im, ternary(configs(2).sign_im,'✓','✗'));

result = configs;
save(fullfile(p.dir_result, 'verify_sine_sign_fix.mat'), 'result', '-v7.3');
fprintf('\n  结果已保存\n');
end

function s = ternary(c, v1, v2)
    if c, s = v1; else, s = v2; end
end
