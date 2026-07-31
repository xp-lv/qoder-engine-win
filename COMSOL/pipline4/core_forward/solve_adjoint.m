function [lambda, ok, K_cache, lambda_gauss] = solve_adjoint(model, voxel, p, Je, ~, K_cache)
%SOLVE_ADJOINT 体积伴随求解（pipline4 专用）
%   [lambda, ok] = solve_adjoint(model, voxel, p, Je)
%   [lambda, ok, K_cache] = solve_adjoint(model, voxel, p, Je, [], K_cache)
%   [lambda, ok, K_cache, lambda_gauss] = solve_adjoint(...)
%
%   核心改进 (2026-07-31): 体积伴随源注入 + Gauss 点 λ 提取
%     Je 定义在所有内部体素中心，通过插值函数写入 COMSOL，
%     ExternalCurrentDensity 的 FEM 组装自动处理体积积分。
%     无需扩散补偿——体积源天然匹配 FEM 载荷。
%
%   输入:
%       model      COMSOL 模型（正演已求解）
%       voxel      体素结构（mask_interior, pos, dV, gauss_pos）
%       p          config
%       Je         [N_inner × 3] complex — 伴随电流密度（体素中心）
%       ~          (ignored, was probe_pos, kept for backward compat)
%       K_cache    (可选) LU 分解缓存
%   输出:
%       lambda       [N_inner × 3] complex — 体素中心伴随场
%       ok           logical — 成功标志
%       K_cache      LU decomposition 缓存
%       lambda_gauss [4*N_inner_tet × 3] complex — Gauss 点伴随场

lambda = []; ok = false;
if nargout >= 3 && (nargin < 6 || isempty(K_cache)), K_cache = []; end

if isempty(model)
    fprintf('[solve_adjoint] model is empty\n');
    return;
end

fprintf('[solve_adjoint] 体积伴随源注入路径\n');

inner = voxel.mask_interior;
phys = model.physics('emw');
inner_pos = voxel.pos(inner, :);
N_inner = sum(inner);

%% 确定 Je 的评估点位置（可能是体素中心或 Gauss 点）
N_je = size(Je, 1);
if N_je == N_inner
    je_pos = inner_pos;  % 体素中心
elseif isfield(voxel, 'gauss_pos') && N_je == size(voxel.gauss_pos, 1)
    je_pos = voxel.gauss_pos;  % Gauss 点
else
    fprintf('  [WARN] Je 维度 %d 不匹配体素(%d)或Gauss点，使用体素中心\n', ...
        N_je, N_inner);
    je_pos = inner_pos;
end
je_src = '体素中心'; if N_je ~= N_inner, je_src = 'Gauss点'; end
fprintf('  Je 注入点: %d (来源: %s)\n', N_je, je_src);

%% 1. 写入伴随源插值函数（与 ε_r 相同的机制）
func_names = {'int_adj_x_re','int_adj_x_im', ...
              'int_adj_y_re','int_adj_y_im', ...
              'int_adj_z_re','int_adj_z_im'};

try
    for d = 1:3
        for part = 1:2
            idx = (d-1)*2 + part;
            fn = func_names{idx};
            try
                model.component('comp1').func(fn);
            catch
                model.component('comp1').func.create(fn, 'Interpolation');
                model.component('comp1').func(fn).set('nargs', '3');
                model.component('comp1').func(fn).set('source', 'table');
            end
            % 外推设为0（外部区域 Je=0）
            try
                model.component('comp1').func(fn).set('extrap', 'specific');
                model.component('comp1').func(fn).set('constval', '0');
            catch
            end
            if part == 1
                vals = real(Je(:, d));
            else
                vals = imag(Je(:, d));
            end
            tmp = [tempname, '.csv'];
            dlmwrite(tmp, [je_pos, vals(:)]);
            model.component('comp1').func(fn).importData(tmp);
            delete(tmp);
        end
    end
    fprintf('  OK 伴随源插值函数写入完成 (%d 点)\n', N_je);
catch ME
    fprintf('  FAIL 写入伴随源: %s\n', ME.message);
    return;
end

%% 2. 配置 ExternalCurrentDensity
try
    try phys.feature('vec1'); catch
        phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    end
    try phys.feature('vec1').selection().all(); catch, end

    Je_x = '(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))';
    Je_y = '(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))';
    Je_z = '(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))';
    phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});
catch ME
    fprintf('  FAIL vec1 config: %s\n', ME.message);
    return;
end

%% 3. 归零背景场（伴随模式）
model.param.set('adjoint_mode', '0');
try
    phys.prop('BackgroundField').set('Eb', [0 0 0]);
    fprintf('  OK 背景场归零 (Eb=[0,0,0])\n');
catch
    fprintf('  OK 背景场归零 (adjoint_mode=0)\n');
end

%% 4. 伴随求解（COMSOL runAll — 最可靠）
fprintf('  COMSOL runAll 求解...\n');
tic;
try
    model.sol('sol1').clearSolution();
    model.sol('sol1').runAll();
    ok = true;
    fprintf('  runAll 完成 (%.2fs)\n', toc);
catch ME
    fprintf('  FAIL runAll (%.2fs): %s\n', toc, ME.message);
end

%% 4b. K 矩阵对称性诊断 + 转置求解
if ok
    fprintf('  提取 Kc (symmetry=off) 诊断对称性...\n');
    tic;
    try
        MA = mphmatrix(model, 'sol1', ...
            'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
            'initmethod', 'sol', 'initsol', 'sol1', ...
            'symmetry', 'off');
        fprintf('  mphmatrix 完成 (%.2fs): Kc %dx%d\n', toc, size(MA.Kc,1), size(MA.Kc,2));

        % 对称性检查（复对称：K = K^T，用 .' 而非 '）
        sym_err = norm(MA.Kc - MA.Kc.', 'fro') / norm(MA.Kc, 'fro');
        fprintf('  ||Kc - Kc.T|| / ||Kc|| = %.4e\n', sym_err);

        if sym_err > 1e-10
            fprintf('  ⚠ K 矩阵非对称！伴随需要 K^T 求解\n');
            % 转置求解
            lambda_raw = MA.Kc' \ MA.Lc;
            lambda_full = (MA.Null * lambda_raw + MA.ud) .* MA.uscale;

            % 写回 COMSOL（mphserver 模式下 mphsetu 不可用，改用 Java API）
            write_ok = false;
            try
                mphsetu(model, 'sol1', lambda_full);
                try model.sol('sol1').createSolution(); catch, end
                write_ok = true;
                fprintf('  OK K^T 求解完成 (mphsetu)\n');
            catch
                % mphserver 模式回退：Java API setU
                try
                    model.sol('sol1').setU(lambda_full);
                    model.sol('sol1').createSolution();
                    write_ok = true;
                    fprintf('  OK K^T 求解完成 (Java API setU)\n');
                catch ME2
                    fprintf('  setU 也失败: %s\n', ME2.message);
                    % 最后回退：尝试 set('U', ...)
                    try
                        model.sol('sol1').set('U', lambda_full);
                        model.sol('sol1').createSolution();
                        write_ok = true;
                        fprintf('  OK K^T 求解完成 (set U property)\n');
                    catch ME3
                        fprintf('  ✗ 无法写回 K^T 解: %s\n', ME3.message);
                        fprintf('  → 将从 runAll 解提取 λ（可能不正确）\n');
                    end
                end
            end

            % 重新提取 λ
            if write_ok
                try
                    [lambda_tr, ~] = read_field(model, inner_pos);
                    fprintf('  K^T λ: |λ| mean=%.4e\n', mean(vecnorm(lambda_tr, 2, 2)));
                catch ME
                    fprintf('  K^T λ 提取失败: %s\n', ME.message);
                end
            end
        else
            fprintf('  ✓ K 矩阵对称，runAll 解正确\n');
        end
    catch ME
        fprintf('  K 对称性诊断失败: %s\n', ME.message);
    end
end

%% 5. 提取 λ 场
lambda_gauss = [];
if ok
    try
        [lambda, ~] = read_field(model, inner_pos);
        fprintf('  OK λ 提取: %d 体素, |λ| mean=%.4e\n', ...
            size(lambda,1), mean(vecnorm(lambda, 2, 2)));
    catch ME
        fprintf('  FAIL λ 提取: %s\n', ME.message);
        ok = false;
    end
    % 提取 Gauss 点 λ（用于精确积分）
    if ok && isfield(voxel, 'gauss_pos') && ~isempty(voxel.gauss_pos)
        try
            [lambda_gauss, ~] = read_field(model, voxel.gauss_pos);
            fprintf('  OK Gauss λ 提取: %d 点, |λ| mean=%.4e\n', ...
                size(lambda_gauss,1), mean(vecnorm(lambda_gauss, 2, 2)));
        catch ME
            fprintf('  [WARN] Gauss λ 提取失败: %s\n', ME.message);
        end
    end
end

%% 6. 恢复模型
try
    model.param.set('adjoint_mode', '1');
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end
    fprintf('  OK 模型已恢复\n');
catch
end

end
