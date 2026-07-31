function result = verify_ratio_all()
%VERIFY_RATIO_ALL 全场景 ratio=1 验证
%
%   测试 3 种场景，每种做全局 FD ratio 对比:
%     1. 均匀初值 (ε=3-0.5j, 真值=5-1j)
%     2. 正弦初值-损耗 (ε_re∈[4,6], ε_im∈[-3,-1], 真值=5-2j)
%     3. 正弦初值-增益 (ε_re∈[4,6], ε_im∈[1,3], 真值=5-2j)

fprintf('\n========== 全场景 ratio 验证 (Re/Im 交换公式) ==========\n');

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

delta = 0.001;
results = struct();

for scenario = 1:3
    switch scenario
        case 1
            name = '均匀 (3-0.5j → 5-1j)';
            eps_re_init = repmat(3.0, N_inner, 1);
            eps_im_init = repmat(-0.5, N_inner, 1);
            eps_re_true = 5.0; eps_im_true = -1.0;
        case 2
            name = '正弦-损耗 ([4-6]×[-3,-1] → 5-2j)';
            eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
            eps_im_init = -2.0 + sin(2*pi*pos_inner(:,2) / L);
            eps_re_true = 5.0; eps_im_true = -2.0;
        case 3
            name = '正弦-增益 ([4-6]×[1,3] → 5-2j)';
            eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
            eps_im_init = 2.0 + sin(2*pi*pos_inner(:,2) / L);
            eps_re_true = 5.0; eps_im_true = -2.0;
    end
    
    fprintf('\n########## 场景 %d: %s ##########\n', scenario, name);
    
    % 真值正演
    voxel.epsilon_r(inner_idx) = eps_re_true + 1j * eps_im_true;
    [~, ~, E_truth_gp] = solve_forward(model, voxel, p);
    
    % 初值正演
    voxel.epsilon_r(inner_idx) = eps_re_init + 1j * eps_im_init;
    [~, ~, E_hyp_gp] = solve_forward(model, voxel, p);
    
    % 伴随梯度
    [Je, ~, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
    [lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
    if ~adj_ok, fprintf('  ✗ 伴随失败\n'); continue; end
    
    % 新公式梯度（Re/Im 交换 + 散射场 Es）
    % Es = E_total - E_b（FEM DOF 是散射场）
    E_b = p.background.amplitude * p.background.polarization(:)';
    E_hyp_s = E_hyp_gp - repmat(E_b, size(E_hyp_gp, 1), 1);
    
    Z = 0;
    for vi = 1:N_inner
        gr = (4*(vi-1)+1):(4*vi);
        Ev = E_hyp_s(gr, :); Lv = lambda_gauss(gr, :); gw = voxel.gauss_weights(gr);
        for gp = 1:4, Z = Z + gw(gp) * sum(Ev(gp,:) .* Lv(gp,:)); end
    end
    adj_re = +k0_sq * imag(Z);
    adj_im = +k0_sq * real(Z);
    
    % FD ε'
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
    
    % FD ε''
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
    
    ratio_re = adj_re / fd_re;
    ratio_im = adj_im / fd_im;
    sign_re = sign(fd_re) == sign(adj_re);
    sign_im = sign(fd_im) == sign(adj_im);
    
    fprintf('  ε''  adj=%+.6e  FD=%+.6e  ratio=%+.4f  sign=%s\n', ...
        adj_re, fd_re, ratio_re, t2(sign_re));
    fprintf('  ε'''' adj=%+.6e  FD=%+.6e  ratio=%+.4f  sign=%s\n', ...
        adj_im, fd_im, ratio_im, t2(sign_im));
    
    results(scenario).name = name;
    results(scenario).adj_re = adj_re;
    results(scenario).adj_im = adj_im;
    results(scenario).fd_re = fd_re;
    results(scenario).fd_im = fd_im;
    results(scenario).ratio_re = ratio_re;
    results(scenario).ratio_im = ratio_im;
    results(scenario).sign_re = sign_re;
    results(scenario).sign_im = sign_im;
end

%% 总结
fprintf('\n========== 全场景总结 ==========\n');
fprintf('  场景                        ε'' ratio   ε'' sign | ε'''' ratio  ε'''' sign\n');
fprintf('  -----------------------------------------------------------------------\n');
for s = 1:3
    fprintf('  %-28s  %+8.4f   %s     |  %+8.4f   %s\n', ...
        results(s).name, results(s).ratio_re, t2(results(s).sign_re), ...
        results(s).ratio_im, t2(results(s).sign_im));
end

all_sign = all([results.sign_re]) && all([results.sign_im]);
all_ratio = all(abs([results.ratio_re] - 1) < 0.2) && all(abs([results.ratio_im] - 1) < 0.2);
if all_sign && all_ratio
    fprintf('\n  ★★★ ALL PASS ★★★ ratio ≈ 1, sign 全正确！\n');
elseif all_sign
    fprintf('\n  ✓ sign 全部正确, ratio 部分偏差\n');
else
    fprintf('\n  部分失败 — 需进一步调试\n');
end

result = results;
save(fullfile(p.dir_result, 'verify_ratio_all.mat'), 'result', '-v7.3');
fprintf('  结果已保存\n');
end

function s = t2(c), if c, s='✓'; else, s='✗'; end, end
