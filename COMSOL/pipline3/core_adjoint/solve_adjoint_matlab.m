function [lambda, ok, lambda_gauss, K_cache] = solve_adjoint_matlab(model, voxel, p, Js, source_pos, Ms, K_cache)
%SOLVE_ADJOINT_MATLAB 管线3核心：mphmatrix 提取 K + MATLAB backslash 伴随求解
%
%   [lambda, ok] = solve_adjoint_matlab(model, voxel, p, Js, source_pos, Ms)
%   [lambda, ok, lambda_gauss, K_cache] = solve_adjoint_matlab(..., K_cache)
%
%   核心创新 vs 管线2 solve_adjoint.m:
%     管线2: 设置 COMSOL 物理源 → model.sol('sol1').runAll() → read_field
%     管线3: 设置 COMSOL 物理源 → mphmatrix 提取 Kc+Lc → MATLAB Kc\Lc 回带
%
%   优势:
%     1. K 矩阵只需提取一次（K 不随 RHS 变化），后续迭代复用
%     2. MATLAB decomposition 对象缓存 LU 分解，backslash 仅做 forward/backward substitution
%     3. 避免 COMSOL runAll 内部的矩阵重组装 + 求解器初始化开销
%
%   输入:
%     model       COMSOL 模型（正演已求解，LU 已缓存）
%     voxel       体素网格
%     p           config 参数
%     Js          [N_src × 3] 表面电流伴随源
%     source_pos  [N_src × 3] 源位置
%     Ms          [N_src × 3] 表面磁流伴随源
%     K_cache     (可选) 缓存的 K decomposition 对象，避免重复提取
%
%   输出:
%     lambda       [N_inner × 3] complex — 体素中心伴随场
%     ok           logical
%     lambda_gauss [4*N_inner × 3] complex — Gauss 积分点伴随场
%     K_cache      decomposition 对象（用于后续迭代复用）

lambda = []; ok = false;
if nargout >= 3, lambda_gauss = []; end
if nargout >= 4 && nargin < 7, K_cache = []; end

if isempty(model)
    fprintf('[solve_adjoint_matlab] model is empty\n');
    return;
end

inner = voxel.mask_interior;
omega = p.omega(1);
mu0 = p.mu0;
omega_mu0 = omega * mu0;
phys = model.physics('emw');

%% ====== Step 1: 设置 COMSOL 伴随物理源（与管线2完全一致）======
% 这一步复用管线2的物理源设置逻辑——双重叉乘 + COMSOL 注入约定
% 因为 mphmatrix 需要通过物理接口组装 RHS

% Js 物理转换：双重叉乘 + omega*mu0 缩放（Faraday 定律）
pos_norm = vecnorm(source_pos, 2, 2);
pos_norm(pos_norm < 1e-30) = 1e-30;
n_hat_src = source_pos ./ pos_norm;
Js_for_comsol = cross(n_hat_src, Js, 2);
Js_for_comsol = Js_for_comsol / omega_mu0;

% 写入 Js 插值函数（-conj 约定）
sc_funcs = {'int_sc_x_re','int_sc_x_im','int_sc_y_re','int_sc_y_im','int_sc_z_re','int_sc_z_im'};
ms_funcs = {'int_ms_x_re','int_ms_x_im','int_ms_y_re','int_ms_y_im','int_ms_z_re','int_ms_z_im'};

try
    for d = 1:3
        for part = 1:2
            idx = (d-1)*2 + part;

            % Js
            fn = sc_funcs{idx};
            try model.component('comp1').func(fn); catch
                model.component('comp1').func.create(fn, 'Interpolation');
                model.component('comp1').func(fn).set('nargs', '3');
                model.component('comp1').func(fn).set('source', 'table');
            end
            if part == 1
                vals = -real(Js_for_comsol(:, d));
            else
                vals = imag(Js_for_comsol(:, d));
            end
            tmp = [tempname, '.csv'];
            dlmwrite(tmp, [source_pos, vals(:)]);
            model.component('comp1').func(fn).importData(tmp);
            delete(tmp);

            % Ms
            fn = ms_funcs{idx};
            try model.component('comp1').func(fn); catch
                model.component('comp1').func.create(fn, 'Interpolation');
                model.component('comp1').func(fn).set('nargs', '3');
                model.component('comp1').func(fn).set('source', 'table');
            end
            if part == 1
                vals = -real(Ms(:, d));
            else
                vals = imag(Ms(:, d));
            end
            tmp = [tempname, '.csv'];
            dlmwrite(tmp, [source_pos, vals(:)]);
            model.component('comp1').func(fn).importData(tmp);
            delete(tmp);
        end
    end
    fprintf('[adj_matlab] OK Js/Ms interpolation functions written\n');
catch ME
    fprintf('[adj_matlab] FAIL writing sources: %s\n', ME.message);
    return;
end

% 创建/配置 SurfaceCurrent (sc_adj)
try
    try phys.feature().remove('sc_adj'); catch, end
    phys.feature().create('sc_adj', 'SurfaceCurrent', 2);
    phys.feature('sc_adj').set('Js0', { ...
        '(-int_sc_x_im(x,y,z) + i*int_sc_x_re(x,y,z))', ...
        '(-int_sc_y_im(x,y,z) + i*int_sc_y_re(x,y,z))', ...
        '(-int_sc_z_im(x,y,z) + i*int_sc_z_re(x,y,z))'});
    try phys.feature('sc_adj').selection().all(); catch, end
catch ME
    fprintf('[adj_matlab] FAIL sc_adj: %s\n', ME.message);
    return;
end

% 创建/配置 SurfaceMagneticCurrentDensity (ms_adj)
try
    try phys.feature().remove('ms_adj'); catch, end
    phys.feature().create('ms_adj', 'SurfaceMagneticCurrentDensity', 2);
    phys.feature('ms_adj').set('Jms0', { ...
        '(-int_ms_x_im(x,y,z) + i*int_ms_x_re(x,y,z))', ...
        '(-int_ms_y_im(x,y,z) + i*int_ms_y_re(x,y,z))', ...
        '(-int_ms_z_im(x,y,z) + i*int_ms_z_re(x,y,z))'});
    try phys.feature('ms_adj').selection().all(); catch, end
catch ME
    fprintf('[adj_matlab] FAIL ms_adj: %s\n', ME.message);
    return;
end

% 归零旧 vec1 + 背景场
try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end
try model.physics('emw').prop('BackgroundField').set('Eb', [0 0 0]); catch, end
model.param.set('adjoint_mode', '0');

fprintf('[adj_matlab] OK physical sources configured (no runAll)\n');

%% ====== Step 2: mphmatrix 提取系统矩阵 ======
% ★ 核心创新：不调用 runAll，而是用 mphmatrix 组装并提取 Kc + Lc
%
% mphmatrix 会:
%   1. 根据当前物理 feature 重新组装系统矩阵（包含伴随源贡献）
%   2. 提取到 MATLAB 工作空间
%   3. 但不调用 PARDISO/MUMPS 求解器
%
% Kc = 消除约束后的刚度矩阵（复对称）
% Lc = 消除约束后的载荷向量（含伴随源贡献）

fprintf('[adj_matlab] 提取系统矩阵 (mphmatrix)...\n');
tic;
try
    MA = mphmatrix(model, 'sol1', ...
        'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
        'initmethod', 'sol', 'initsol', 'sol1', ...
        'symmetry', p.mphmatrix_symmetry);
    t_extract = toc;
    fprintf('[adj_matlab] mphmatrix 完成 (%.2fs): Kc %s, Lc %s\n', ...
        t_extract, matSizeStr(MA.Kc), matSizeStr(MA.Lc));
catch ME
    t_extract = toc;
    fprintf('[adj_matlab] FAIL mphmatrix (%.2fs): %s\n', t_extract, ME.message);
    return;
end

Kc = MA.Kc;
Lc = MA.Lc;

%% ====== Step 3: MATLAB backslash 求解 ======
% ★ 核心：用 MATLAB 的 decomposition + backslash 代替 COMSOL runAll
%
% 对于复对称矩阵 Kc（非 Hermitian），MATLAB \ 自动选择 LU 分解
% decomposition 对象可缓存 LU，后续迭代仅做 O(n) 回带

if isempty(K_cache) || ~isa(K_cache, 'decomposition')
    % 首次：创建 decomposition 对象（含 LU 分解，O(n^{1.5}) 一次性开销）
    fprintf('[adj_matlab] 创建 MATLAB decomposition (LU factorization)...\n');
    tic;
    try
        if p.use_decomposition
            K_cache = decomposition(Kc, 'lu');
        else
            K_cache = Kc;  % 直接用稀疏矩阵（每次 backslash 都做 LU）
        end
        t_lu = toc;
        fprintf('[adj_matlab] LU 分解完成 (%.2fs)\n', t_lu);
    catch ME
        t_lu = toc;
        fprintf('[adj_matlab] FAIL decomposition (%.2fs): %s\n', t_lu, ME.message);

        % 回退：直接 backslash（不缓存 LU）
        fprintf('[adj_matlab] 回退到直接 backslash...\n');
        Uc_raw = Kc \ Lc;
        ok = true;
    end
end

if ~ok  % 还未求解
    tic;
    try
        % ★ 核心回带：K_cache \ Lc（仅 forward/backward substitution，O(n)）
        Uc_raw = K_cache \ Lc;
        t_solve = toc;
        fprintf('[adj_matlab] MATLAB backslash 完成 (%.4fs)\n', t_solve);
        ok = true;
    catch ME
        t_solve = toc;
        fprintf('[adj_matlab] FAIL backslash (%.4fs): %s\n', t_solve, ME.message);
        return;
    end
end

%% ====== Step 4: 还原完整解向量 ======
% Uc_raw 是消除约束后的解，需要还原到完整 DOF 空间
Uc = MA.Null * Uc_raw;
U0 = Uc + MA.ud;
U_full = U0 .* MA.uscale;

fprintf('[adj_matlab] 解向量: %d DOF, |U| range [%.4e, %.4e]\n', ...
    length(U_full), min(abs(U_full)), max(abs(U_full)));

%% ====== Step 5: 从解向量提取体素中心 + Gauss 点伴随场 ======
% 需要将 FEM DOF 解映射到体素中心坐标——通过 mphinterp
% 但 mphinterp 需要已求解的模型，而我们没有调用 runAll
% 替代方案：直接将 U_full 写回模型，然后用 mphinterp 提取

% 方案 A（推荐）：用 mphsetu 将解写回 COMSOL，然后 mphinterp 提取
try
    mphsetu(model, 'sol1', U_full);
    fprintf('[adj_matlab] 解已写回 COMSOL (mphsetu)\n');

    % 用 mphinterp 提取体素中心 lambda
    inner_pos = voxel.pos(inner, :);
    lx = mphinterp(model, 'emw.Ex', 'coord', inner_pos');
    ly = mphinterp(model, 'emw.Ey', 'coord', inner_pos');
    lz = mphinterp(model, 'emw.Ez', 'coord', inner_pos');
    lambda_raw = [lx(:), ly(:), lz(:)];

    % Gauss 点
    if ~isempty(voxel.gauss_pos)
        gx = mphinterp(model, 'emw.Ex', 'coord', voxel.gauss_pos');
        gy = mphinterp(model, 'emw.Ey', 'coord', voxel.gauss_pos');
        gz = mphinterp(model, 'emw.Ez', 'coord', voxel.gauss_pos');
        lambda_gauss_raw = [gx(:), gy(:), gz(:)];
    end

    fprintf('[adj_matlab] lambda extracted via mphinterp: %d points\n', size(lambda_raw, 1));

catch ME_setu
    % 方案 B（后备）：mphinterp 失败，回退到 runAll + read_field
    fprintf('[adj_matlab] mphsetu/mphinterp 失败: %s → 回退到 runAll\n', ME_setu.message);
    try model.sol('sol1').runAll();
    catch, end
    inner_pos = voxel.pos(inner, :);
    [lambda_raw, ~] = read_field(model, inner_pos);
    if ~isempty(voxel.gauss_pos)
        [lambda_gauss_raw, ~] = read_field(model, voxel.gauss_pos);
    end
end

% ★ conj 补偿（与管线2一致的约定：双源路径需要 conj）
lambda = conj(lambda_raw);
if exist('lambda_gauss_raw', 'var') && ~isempty(lambda_gauss_raw)
    lambda_gauss = conj(lambda_gauss_raw);
end

fprintf('[adj_matlab] OK lambda: %d voxels, |lambda| mean=%.4e (conj=1)\n', ...
    size(lambda, 1), mean(vecnorm(lambda, 2, 2)));

%% ====== Step 6: 恢复模型状态 ======
try
    model.param.set('adjoint_mode', '1');
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    try phys.feature().remove('sc_adj'); catch, end
    try phys.feature().remove('ms_adj'); catch, end
    try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end
    fprintf('[adj_matlab] OK model restored\n');
catch
end

end

%% ====== 辅助函数 ======
function s = matSizeStr(M)
if isempty(M)
    s = '[]';
elseif isvector(M)
    s = sprintf('%d×%d', size(M, 1), size(M, 2));
else
    s = sprintf('%d×%d (nnz=%d)', size(M, 1), size(M, 2), nnz(M));
end
end
