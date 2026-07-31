function [lambda, ok, K_cache] = solve_adjoint(model, voxel, p, Je, probe_pos, K_cache)
%SOLVE_ADJOINT 极简伴随求解（pipline4 专用）
%   [lambda, ok] = solve_adjoint(model, voxel, p, Je, probe_pos)
%
%   仅体积路径：Je 作为 ExternalCurrentDensity 注入探针点 → 归零背景场 →
%   mphmatrix LU 回代 → 提取 λ
%
%   与管线3的核心差异:
%     - 无双源路径（删除 SurfaceCurrent + SurfaceMagneticCurrentDensity）
%     - 无 if-else 分支（仅一条路径）
%     - 无 keep_adjoint_state（不需要 FEM 自由度导出）
%     - 代码量 ~130 行（管线3为 415 行）
%
%   输入:
%       model      COMSOL 模型（正演已求解）
%       voxel      体素结构（mask_interior, pos）
%       p          config
%       Je         [N_probe × 3] complex — 伴随电流密度（探针点处）
%       probe_pos  [N_probe × 3] — 探针点坐标
%       K_cache    (可选) LU 分解缓存
%   输出:
%       lambda     [N_inner × 3] complex — 体素中心伴随场
%       ok         logical — 成功标志
%       K_cache    LU decomposition 缓存（供后续复用）

lambda = []; ok = false;
if nargout >= 3 && (nargin < 6 || isempty(K_cache)), K_cache = []; end

if isempty(model)
    fprintf('[solve_adjoint] model is empty\n');
    return;
end

fprintf('[solve_adjoint] 极简体积路径 (ExternalCurrentDensity)\n');

inner = voxel.mask_interior;
phys = model.physics('emw');

%% 1. 写入伴随源插值函数（Je 的实虚部分）
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
            % ★ 关键修复: 设置域外外推为 0（Je 只在探针点处非零）
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
            dlmwrite(tmp, [probe_pos, vals(:)]);
            model.component('comp1').func(fn).importData(tmp);
            delete(tmp);
        end
    end
    fprintf('  OK 伴随源插值函数写入完成\n');
catch ME
    fprintf('  FAIL 写入伴随源: %s\n', ME.message);
    return;
end

%% 2. 配置 ExternalCurrentDensity (vec1)
try
    try phys.feature('vec1'); catch
        phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
        fprintf('  OK created vec1\n');
    end
    try phys.feature('vec1').selection().all(); catch, end

    Je_x = sprintf('(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))');
    Je_y = sprintf('(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))');
    Je_z = sprintf('(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))');
    phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});
catch ME
    fprintf('  FAIL vec1 config: %s\n', ME.message);
    return;
end

%% 3. 归零背景场（伴随模式：无入射波）
model.param.set('adjoint_mode', '0');
try
    phys.prop('BackgroundField').set('Eb', [0 0 0]);
    fprintf('  OK 背景场归零 (Eb=[0,0,0])\n');
catch
    fprintf('  OK 背景场归零 (adjoint_mode=0)\n');
end

%% 4. 伴随求解（mphmatrix + LU 回代）
fprintf('  提取系统矩阵 (mphmatrix)...\n');
tic;
try
    sym_str = 'hermitian';
    if isfield(p, 'mphmatrix_symmetry'), sym_str = p.mphmatrix_symmetry; end
    MA = mphmatrix(model, 'sol1', ...
        'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
        'initmethod', 'sol', 'initsol', 'sol1', ...
        'symmetry', sym_str);
    fprintf('  mphmatrix 完成 (%.2fs): Kc %dx%d\n', toc, size(MA.Kc,1), size(MA.Kc,2));
catch ME
    fprintf('  FAIL mphmatrix (%.2fs): %s → 回退 runAll\n', toc, ME.message);
    try
        model.sol('sol1').runAll(); ok = true;
    catch ME2
        fprintf('  FAIL runAll: %s\n', ME2.message);
    end
end

if ~ok && exist('MA', 'var')
    % LU 分解（首次）或回代（后续）
    if isempty(K_cache) || ~isa(K_cache, 'decomposition')
        fprintf('  创建 LU decomposition...\n');
        tic;
        try
            use_dec = true;
            if isfield(p, 'use_decomposition'), use_dec = p.use_decomposition; end
            if use_dec
                K_cache = decomposition(MA.Kc, 'lu');
            else
                K_cache = MA.Kc;
            end
            fprintf('  LU 分解完成 (%.2fs)\n', toc);
        catch ME
            fprintf('  FAIL decomposition: %s → 直接 backslash\n', ME.message);
        end
    end

    % 回代求解
    tic;
    try
        Uc_raw = K_cache \ MA.Lc;
        fprintf('  LU 回代完成 (%.4fs)\n', toc);

        % 还原完整解向量
        Uc = MA.Null * Uc_raw;
        U0 = Uc + MA.ud;
        U_full = U0 .* MA.uscale;

        % 写回 COMSOL
        try mphsetu(model, 'sol1', U_full);
        catch
            model.sol('sol1').setU(U_full);
            model.sol('sol1').createSolution();
        end
        fprintf('  OK 伴随求解完成 (mphmatrix + LU)\n');
        ok = true;
    catch ME
        fprintf('  FAIL backslash: %s → 回退 runAll\n', ME.message);
        try model.sol('sol1').runAll(); ok = true; catch, end
    end
end

%% 5. 提取 λ 场
if ok
    try
        [lambda, ~] = read_field(model, voxel.pos(inner, :));
        fprintf('  OK λ 提取: %d 体素, |λ| mean=%.4e\n', ...
            size(lambda,1), mean(vecnorm(lambda, 2, 2)));
    catch ME
        fprintf('  FAIL λ 提取: %s\n', ME.message);
        ok = false;
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
