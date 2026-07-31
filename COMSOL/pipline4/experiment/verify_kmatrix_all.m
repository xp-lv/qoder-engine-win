function result = verify_kmatrix_all()
%VERIFY_KMATRIX_ALL K 矩阵精确梯度全场景验证
%
%   用 K 矩阵差分法计算梯度，对比 FD，验证 ratio≈1

fprintf('\n========== K 矩阵精确梯度全场景验证 ==========\n');

p = config();
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos_inner = voxel.pos(inner_idx, :);
L = 2 * p.R_inner;
delta_km = 0.01;  % K 矩阵差分步长
delta_fd = 0.001; % FD 验证步长
results = struct();

for scenario = 1:3
    switch scenario
        case 1
            name = '均匀 (3-0.5j→5-1j)';
            eps_re_init = repmat(3.0, N_inner, 1);
            eps_im_init = repmat(-0.5, N_inner, 1);
            eps_re_true = 5.0; eps_im_true = -1.0;
        case 2
            name = '正弦-损耗 ([4,6]×[-3,-1]→5-2j)';
            eps_re_init = 5.0 + sin(2*pi*pos_inner(:,1) / L);
            eps_im_init = -2.0 + sin(2*pi*pos_inner(:,2) / L);
            eps_re_true = 5.0; eps_im_true = -2.0;
        case 3
            name = '正弦-增益 ([4,6]×[1,3]→5-2j)';
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
    solve_forward(model, voxel, p);

    % 提取前解 DOF
    u_dof = model.sol('sol1').getU();

    % 伴随求解
    [E_hyp_gp, ~] = read_field(model, voxel.gauss_pos);
    [Je, ~, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);
    [lambda, adj_ok, ~, lambda_gauss] = solve_adjoint(model, voxel, p, Je);
    if ~adj_ok, continue; end

    % 重新求解伴随以获取 DOF（solve_adjoint 恢复了模型）
    % 需要重新设置伴随态
    phys = model.physics('emw');
    func_names = {'int_adj_x_re','int_adj_x_im','int_adj_y_re','int_adj_y_im','int_adj_z_re','int_adj_z_im'};
    for d = 1:3
        for part = 1:2
            idx = (d-1)*2 + part; fn = func_names{idx};
            try model.component('comp1').func(fn); catch
                model.component('comp1').func.create(fn, 'Interpolation');
                model.component('comp1').func(fn).set('nargs', '3');
                model.component('comp1').func(fn).set('source', 'table');
            end
            if part == 1, vals = real(Je(:, d)); else, vals = imag(Je(:, d)); end
            tmp = [tempname, '.csv'];
            dlmwrite(tmp, [voxel.gauss_pos, vals(:)]);
            model.component('comp1').func(fn).importData(tmp);
            delete(tmp);
        end
    end
    try phys.feature('vec1'); catch
        phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    end
    try phys.feature('vec1').selection().all(); catch, end
    phys.feature('vec1').set('Je', { ...
        '(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))', ...
        '(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))', ...
        '(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))'});
    model.param.set('adjoint_mode', '0');
    try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch, end
    model.sol('sol1').clearSolution();
    model.sol('sol1').runAll();

    lambda_dof = model.sol('sol1').getU();

    % 恢复模型
    model.param.set('adjoint_mode', '1');
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end

    % K 矩阵梯度
    [km_re, km_im] = compute_gradient_kmatrix(model, voxel, p, lambda_dof, u_dof, delta_km);

    % FD 验证
    eps_re_base = eps_re_init; eps_im_base = eps_im_init;

    % ε' FD
    voxel.epsilon_r(inner_idx) = (eps_re_base + delta_fd) + 1j * eps_im_base;
    solve_forward(model, voxel, p);
    [E_p, ~] = read_field(model, voxel.gauss_pos);
    F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    voxel.epsilon_r(inner_idx) = (eps_re_base - delta_fd) + 1j * eps_im_base;
    solve_forward(model, voxel, p);
    [E_m, ~] = read_field(model, voxel.gauss_pos);
    F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    fd_re = (F_p - F_m) / (2 * delta_fd);

    % ε'' FD
    voxel.epsilon_r(inner_idx) = eps_re_base + 1j * (eps_im_base + delta_fd);
    solve_forward(model, voxel, p);
    [E_p, ~] = read_field(model, voxel.gauss_pos);
    F_p = sum(voxel.gauss_weights .* sum(abs(E_p - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    voxel.epsilon_r(inner_idx) = eps_re_base + 1j * (eps_im_base - delta_fd);
    solve_forward(model, voxel, p);
    [E_m, ~] = read_field(model, voxel.gauss_pos);
    F_m = sum(voxel.gauss_weights .* sum(abs(E_m - E_truth_gp).^2, 2)) / ...
          sum(voxel.gauss_weights .* sum(abs(E_truth_gp).^2, 2));
    fd_im = (F_p - F_m) / (2 * delta_fd);

    ratio_re = km_re / fd_re;
    ratio_im = km_im / fd_im;
    sign_re = sign(fd_re) == sign(km_re);
    sign_im = sign(fd_im) == sign(km_im);

    fprintf('  ε''  KM=%+.6e  FD=%+.6e  ratio=%+.4f  sign=%s\n', km_re, fd_re, ratio_re, t2(sign_re));
    fprintf('  ε'''' KM=%+.6e  FD=%+.6e  ratio=%+.4f  sign=%s\n', km_im, fd_im, ratio_im, t2(sign_im));

    results(scenario).name = name;
    results(scenario).km_re = km_re; results(scenario).km_im = km_im;
    results(scenario).fd_re = fd_re; results(scenario).fd_im = fd_im;
    results(scenario).ratio_re = ratio_re; results(scenario).ratio_im = ratio_im;
    results(scenario).sign_re = sign_re; results(scenario).sign_im = sign_im;
end

%% 总结
fprintf('\n========== K 矩阵法全场景总结 ==========\n');
fprintf('  场景                              ε'' ratio  sign | ε'''' ratio  sign\n');
fprintf('  ----------------------------------------------------------------\n');
for s = 1:3
    fprintf('  %-34s  %+7.4f   %s   |  %+7.4f   %s\n', ...
        results(s).name, results(s).ratio_re, t2(results(s).sign_re), ...
        results(s).ratio_im, t2(results(s).sign_im));
end

all_sign = all([results.sign_re]) && all([results.sign_im]);
all_ratio = all(abs([results.ratio_re] - 1) < 0.15) && all(abs([results.ratio_im] - 1) < 0.15);
if all_sign && all_ratio
    fprintf('\n  ★★★ ALL PASS ★★★ ratio ≈ 1 全场景通过！\n');
elseif all_sign
    fprintf('\n  ✓ sign 全部正确\n');
else
    fprintf('\n  部分失败\n');
end

result = results;
save(fullfile(p.dir_result, 'verify_kmatrix_all.mat'), 'result', '-v7.3');
end

function s = t2(c), if c, s='✓'; else, s='✗'; end, end
