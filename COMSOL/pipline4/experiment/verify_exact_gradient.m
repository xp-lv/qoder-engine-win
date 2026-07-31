function result = verify_exact_gradient()
%VERIFY_EXACT_GRADIENT 精确 K 矩阵梯度（修正版）
%   使用 model.sol('sol1').getU() 直接提取解向量，绕过 mphmatrix initsol 问题

fprintf('\n========== pipline4 精确 K 矩阵梯度 (修正版) ==========\n');

p = config();

%% 1. COMSOL 连接
fprintf('\n--- [1] COMSOL 连接 ---\n');
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

%% 2. FEM 网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;

%% 3. 真值 + 初值正演
voxel.epsilon_r(inner) = p.eps_r_true;
solve_forward(model, voxel, p);
[E_truth_gp, ~] = read_field(model, voxel.gauss_pos);

voxel.epsilon_r(inner) = p.eps_r_init;
solve_forward(model, voxel, p);
[E_hyp_gp, ~] = read_field(model, voxel.gauss_pos);

% 提取前解 DOF 向量
u_fwd = model.sol('sol1').getU();
fprintf('  前解 u: %d DOFs, |u| mean=%.4e\n', length(u_fwd), mean(abs(u_fwd)));

%% 4. 提取 K(ε_init)
fprintf('\n--- [2] K(ε_init) 提取 ---\n');
MA = mphmatrix(model, 'sol1', ...
    'out', {'K', 'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
fprintf('  K: %dx%d (full), Kc: %dx%d (constrained)\n', ...
    size(MA.K,1), size(MA.K,2), size(MA.Kc,1), size(MA.Kc,2));

%% 5. 构建伴随源 + 求解
fprintf('\n--- [3] 伴随求解 ---\n');
[Je, F_norm, ~] = build_adjoint_source_nearfield(voxel, E_hyp_gp, E_truth_gp, p, true);

% 写入 Je
phys = model.physics('emw');
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
        try model.component('comp1').func(fn).set('extrap', 'specific'); catch, end
        try model.component('comp1').func(fn).set('constval', '0'); catch, end
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

% 提取伴随解 DOF 向量
lambda_adj = model.sol('sol1').getU();
fprintf('  伴随解 λ: %d DOFs, |λ| mean=%.4e\n', length(lambda_adj), mean(abs(lambda_adj)));

% 恢复模型
model.param.set('adjoint_mode', '1');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end

%% 6. 提取 K(ε+δε) 和 K(ε-δε)
fprintf('\n--- [4] K 矩阵差分 ---\n');
delta = 0.01;

% ε' 差分
voxel.epsilon_r(inner) = (p.eps_r_init_re + delta) + 1j * p.eps_r_init_im;
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolution(); model.sol('sol1').runAll();
MA_re_p = mphmatrix(model, 'sol1', 'out', {'K'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

voxel.epsilon_r(inner) = (p.eps_r_init_re - delta) + 1j * p.eps_r_init_im;
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolution(); model.sol('sol1').runAll();
MA_re_m = mphmatrix(model, 'sol1', 'out', {'K'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

dK_re = (MA_re_p.K - MA_re_m.K) / (2 * delta);
fprintf('  ||dK/dε''||=%.4e\n', norm(dK_re, 'fro'));

% ε'' 差分
voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im + delta);
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolution(); model.sol('sol1').runAll();
MA_im_p = mphmatrix(model, 'sol1', 'out', {'K'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im - delta);
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolution(); model.sol('sol1').runAll();
MA_im_m = mphmatrix(model, 'sol1', 'out', {'K'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

dK_im = (MA_im_p.K - MA_im_m.K) / (2 * delta);
fprintf('  ||dK/dε''''||=%.4e\n', norm(dK_im, 'fro'));

%% 7. 精确梯度: dF/dε = -Re(λ' · dK · u)
fprintf('\n--- [5] 精确梯度 (全 DOF) ---\n');

% 全空间梯度
grad_re_exact = -real(lambda_adj' * dK_re * u_fwd);
grad_im_exact = -real(lambda_adj' * dK_im * u_fwd);

fprintf('  精确 ε'' grad = %+.6e\n', grad_re_exact);
fprintf('  精确 ε'''' grad = %+.6e\n', grad_im_exact);

%% 8. FD 对比 (同样 delta)
fprintf('\n--- [6] FD 对比 ---\n');

% 恢复初值正演状态
voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * p.eps_r_init_im;
solve_forward(model, voxel, p);

% ε' FD
voxel.epsilon_r(inner) = (p.eps_r_init_re + delta) + 1j * p.eps_r_init_im;
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = compute_cost(voxel, E_p, E_truth_gp, p, true);

voxel.epsilon_r(inner) = (p.eps_r_init_re - delta) + 1j * p.eps_r_init_im;
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = compute_cost(voxel, E_m, E_truth_gp, p, true);

fd_re = (F_p - F_m) / (2 * delta);

% ε'' FD
voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im + delta);
solve_forward(model, voxel, p);
[E_p, ~] = read_field(model, voxel.gauss_pos);
F_p = compute_cost(voxel, E_p, E_truth_gp, p, true);

voxel.epsilon_r(inner) = p.eps_r_init_re + 1j * (p.eps_r_init_im - delta);
solve_forward(model, voxel, p);
[E_m, ~] = read_field(model, voxel.gauss_pos);
F_m = compute_cost(voxel, E_m, E_truth_gp, p, true);

fd_im = (F_p - F_m) / (2 * delta);

fprintf('\n========== K 精确梯度 vs FD ==========\n');
fprintf('  ε''  K-exact=%+.6e, FD=%+.6e, ratio=%.4f\n', grad_re_exact, fd_re, grad_re_exact/fd_re);
fprintf('  ε'''' K-exact=%+.6e, FD=%+.6e, ratio=%.4f\n', grad_im_exact, fd_im, grad_im_exact/fd_im);

%% 9. 同时计算解析公式（总场 + 散射场）
fprintf('\n--- [7] 解析公式对比 ---\n');
% 总场公式
lambda_gp = read_field(model, voxel.gauss_pos);
% 需要重新求解伴随来获取 lambda
% (lambda_adj 已有，但需要 Gauss 点值)
% 用 mphinterp 提取
lambda_gp_adj = mphinterp(model, 'emw.Ex', 'coord', voxel.gauss_pos'); % 这不是伴随解...

fprintf('  (解析公式对比需要额外步骤，跳过)\n');

result = struct();
result.grad_re_exact = grad_re_exact;
result.grad_im_exact = grad_im_exact;
result.fd_re = fd_re;
result.fd_im = fd_im;
result.ratio_re = grad_re_exact / fd_re;
result.ratio_im = grad_im_exact / fd_im;

end
