function result = verify_lambda_residual()
%VERIFY_LAMBDA_RESIDUAL K·λ 残差检查（诊断 COMSOL 求解正确性）
%
%   当 verify_fd_complex 的 sign 验证失败时运行此脚本。
%
%   原理:
%     伴随方程: K·λ = q（q = iωμ₀·Je）
%     如果 ||K·λ - q|| / ||q|| 很大 → COMSOL 求解有误
%     如果残差极小 → 问题在梯度组装（compute_gradient 的内积约定）
%
%   验证步骤:
%     1. 正演 + 构建伴随源
%     2. 设置伴随态（归零背景场 + 注入 Je）
%     3. mphmatrix 导出 Kc, Lc
%     4. MATLAB 直接求解 λ_direct = Kc \ Lc
%     5. 写回 COMSOL，mphinterp 提取 λ_extracted
%     6. 比较 λ_direct vs λ_extracted（mphinterp 精度）
%     7. 计算 K·λ 残差
%
%   用法:
%     >> setup(); verify_lambda_residual();

fprintf('\n========== pipline4 λ 残差诊断 ==========\n');

p = config();
probe = build_probes(p);

%% 1. COMSOL 连接 + 正演
fprintf('\n--- [1] 正演求解 ---\n');
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;

% 真值正演
voxel.epsilon_r(inner) = p.eps_r_true;
solve_forward(model, voxel, p);
[E_truth_probe, ~] = read_field(model, probe.pos);

% 初值正演
voxel.epsilon_r(inner) = p.eps_r_init;
[E_hyp_vox, ~] = solve_forward(model, voxel, p);
[E_hyp_probe, ~] = read_field(model, probe.pos);

%% 2. 构建伴随源
fprintf('\n--- [2] 伴随源构建 ---\n');
[Je, F_norm, ~] = build_adjoint_source_nearfield(probe, E_hyp_probe, E_truth_probe, p);

%% 3. 设置伴随态（手动，不调 solve_adjoint，以便中间检查）
fprintf('\n--- [3] 设置伴随态 ---\n');
phys = model.physics('emw');

% 写入伴随源插值函数
func_names = {'int_adj_x_re','int_adj_x_im','int_adj_y_re','int_adj_y_im','int_adj_z_re','int_adj_z_im'};
for d = 1:3
    for part = 1:2
        idx = (d-1)*2 + part;
        fn = func_names{idx};
        try model.component('comp1').func(fn); catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        if part == 1, vals = real(Je(:, d)); else, vals = imag(Je(:, d)); end
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [probe.pos, vals(:)]);
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

% 归零背景场
model.param.set('adjoint_mode', '0');
try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch, end
fprintf('  伴随态设置完成\n');

%% 4. mphmatrix 导出
fprintf('\n--- [4] mphmatrix 导出 Kc, Lc ---\n');
tic;
sym_str = p.mphmatrix_symmetry;
MA = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', sym_str);
fprintf('  Kc: %dx%d, Lc: %dx1 (%.2fs)\n', ...
    size(MA.Kc,1), size(MA.Kc,2), size(MA.Lc,1), toc);

%% 5. MATLAB 直接求解 λ_direct
fprintf('\n--- [5] MATLAB 直接求解 λ ---\n');
Uc_raw = MA.Kc \ MA.Lc;
Uc = MA.Null * Uc_raw;
U0 = Uc + MA.ud;
U_full = U0 .* MA.uscale;

% K·λ 残差（在约束消除空间）
residual_vec = MA.Kc * Uc_raw - MA.Lc;
res_norm = norm(residual_vec) / norm(MA.Lc);
fprintf('  ||K·λ - q|| / ||q|| = %.4e\n', res_norm);

if res_norm < 1e-8
    fprintf('  ✓ 残差极小 — COMSOL 求解正确\n');
else
    fprintf('  ✗ 残差较大 — mphmatrix 回代或 Kc 有误\n');
end

%% 6. 写回 COMSOL，mphinterp 提取
fprintf('\n--- [6] mphinterp 提取精度检查 ---\n');
try mphsetu(model, 'sol1', U_full);
catch
    model.sol('sol1').setU(U_full);
    model.sol('sol1').createSolution();
end

[lambda_vox, ~] = read_field(model, voxel.pos(inner, :));

% 梯度计算（用直接求解的 λ）
[g, g_re, g_im] = compute_gradient(voxel, E_hyp_vox, lambda_vox, p);

%% 7. 恢复模型
model.param.set('adjoint_mode', '1');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end
fprintf('\n  模型已恢复\n');

%% 8. 报告
fprintf('\n========== λ 残差诊断总结 ==========\n');
fprintf('  K·λ 残差: %.4e\n', res_norm);
fprintf('  g_re = %+.4e, g_im = %+.4e\n', g_re, g_im);

if res_norm < 1e-8
    fprintf('\n  诊断: COMSOL 伴随求解正确\n');
    fprintf('  → 如果 FD sign 仍失败，问题在 compute_gradient 的内积约定\n');
    fprintf('  → 尝试切换 gradient_dot: bilinear ↔ hermitian\n');
else
    fprintf('\n  诊断: COMSOL 伴随求解有误\n');
    fprintf('  → 检查 mphmatrix 的 symmetry 设置\n');
    fprintf('  → 检查插值函数是否正确写入\n');
end

result = struct();
result.res_norm = res_norm;
result.g_re = g_re;
result.g_im = g_im;
result.Kc_size = size(MA.Kc);

save(fullfile(p.dir_result, 'verify_lambda_residual.mat'), 'result', '-v7.3');
fprintf('  结果已保存\n');

end
