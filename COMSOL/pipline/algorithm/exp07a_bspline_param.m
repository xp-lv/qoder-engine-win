function B_op = exp07a_bspline_param(voxel, p)
%BUILD_BSPLINE_OPERATOR exp07a 3D cubic B-spline 参数化算子
%   B_op = exp07a_bspline_param(voxel, p)
%
%   把 voxel.epsilon_r (N_v 维) 参数化为控制点 c (N_c 维):
%     ε_r(v) = Σ_{c ∈ local_support(v)} B_c(v) · c_c
%     等价矩阵形式: ε_r_voxel = B_op · c
%   B_op 形状: [N_v × N_c] sparse, cubic B-spline 局部紧支 (4x4x4 = 64 个非零/voxel)
%
%   设计参数 (来自 manifest.json):
%     n_cx, n_cy, n_cz: 控制点网格 (默认 10×10×5 = 500)
%     order:           B-spline 阶 (默认 3 = cubic)
%     控制点物理位置: 覆盖散射体包围盒, voxel 网格 (inner + outer)
%     边界: 立方 B-spline, 无需显式边界条件
%
%   反演时:
%     - 反演变量: c ∈ R^{N_c} (500 维)
%     - voxel 空间: ε_r = B_op · c (19268 维, 由 c 推算)
%     - 链式法则: g_c = B_op' · g_voxel (500 维梯度)
%
%   物理含义: B-spline 把散射体内部 ε_r 强制为分段连续 (cubic smooth),
%   而非 voxel-wise 独立. 19268 → 500 把约束/自由度比从 1:100 改善到 1:2.6.
%   配合 TV L1 段常数先验, 可解 exp06 Scenario C 强多解性.
%
%   复杂度: 19268 voxels × 64 邻居/voxel = 1.2M nonzero entries
%           sparse storage ~2-3 MB, B_op · c ~10 ms, B_op' · g ~10 ms
%
%   复用前检查: core/ 下无 B-spline 实现 (grep_code 0 匹配)
%   算法族: chebyshev_v5_tikhonov_tv_bspline v5.1
%   决策依据: .research/decisions/ADR-010-bspline-tv-parameterization.md (待写)

fprintf('  [B-spline] 构建 3D cubic B-spline 参数化算子...\n');

if ~isfield(p, 'n_cx'); p.n_cx = 10; end
if ~isfield(p, 'n_cy'); p.n_cy = 10; end
if ~isfield(p, 'n_cz'); p.n_cz = 5;  end
if ~isfield(p, 'bspline_order'); p.bspline_order = 3; end

N_v = length(voxel.epsilon_r);
N_c = p.n_cx * p.n_cy * p.n_cz;

%% ---- 控制点物理位置 (覆盖 voxel 包围盒) ----
pos = voxel.pos;
coord_min = min(pos, [], 1);
coord_max = max(pos, [], 1);
% 控制点位置: 均匀分布在包围盒内 (Cox-de Boor style uniform knots)
% 用 linspace 避免端点边界问题 (B-spline 在 [0,1] 端点不全支)
ctrl_x = linspace(coord_min(1), coord_max(1), p.n_cx);
ctrl_y = linspace(coord_min(2), coord_max(2), p.n_cy);
ctrl_z = linspace(coord_min(3), coord_max(3), p.n_cz);

% 控制点间距
if p.n_cx > 1
    dx_ctrl = (coord_max(1) - coord_min(1)) / (p.n_cx - 1);
else
    dx_ctrl = 1.0;
end
if p.n_cy > 1
    dy_ctrl = (coord_max(2) - coord_min(2)) / (p.n_cy - 1);
else
    dy_ctrl = 1.0;
end
if p.n_cz > 1
    dz_ctrl = (coord_max(3) - coord_min(3)) / (p.n_cz - 1);
else
    dz_ctrl = 1.0;
end

fprintf('  [B-spline] 控制点网格 %dx%dx%d = %d, voxel N_v=%d\n', ...
    p.n_cx, p.n_cy, p.n_cz, N_c, N_v);
fprintf('  [B-spline] 包围盒 x=[%.3f,%.3f] y=[%.3f,%.3f] z=[%.3f,%.3f]\n', ...
    coord_min(1), coord_max(1), coord_min(2), coord_max(2), coord_min(3), coord_max(3));
fprintf('  [B-spline] 控制点间距 dx=%.4f dy=%.4f dz=%.4f\n', dx_ctrl, dy_ctrl, dz_ctrl);

%% ---- 立方 B-spline 基函数 (cubic) ----
%   B-spline 基函数定义在 [0, 4] 区间 (order=3 时支撑 [i, i+4])
%   归一化参数: u ∈ [0, 1] 是局部参数
%   B_0(u) = (1-u)^3 / 6
%   B_1(u) = (3u^3 - 6u^2 + 4) / 6
%   B_2(u) = (-3u^3 + 3u^2 + 3u + 1) / 6
%   B_3(u) = u^3 / 6
%   满足 B_0+B_1+B_2+B_3 = 1 (partiton of unity)
bspline_basis = @(u) [(1-u).^3/6; (3*u.^3 - 6*u.^2 + 4)/6; ...
                       (-3*u.^3 + 3*u.^2 + 3*u + 1)/6; u.^3/6];

%% ---- 对每个 voxel, 找 4x4x4 控制点邻居 + 计算基函数值 ----
% 预分配 sparse 矩阵 (Nz=64/voxel × 19268 = 1.2M entries, ~3 MB)
max_nnz = N_v * 64;
rows = zeros(max_nnz, 1);
cols = zeros(max_nnz, 1);
vals = zeros(max_nnz, 1);
nnz_count = 0;

for v = 1:N_v
    vx = voxel.pos(v, 1);
    vy = voxel.pos(v, 2);
    vz = voxel.pos(v, 3);

    % FIX: 正确计算 4 个控制点索引 + 局部参数 u
    % ix0 = 0-based 区间索引, clamp 到 [0, n-4] 保证 4 个控制点都在网格内
    % ux = fx - ix0, clamp 到 [0, 1] 保证 B-spline 基函数非负
    if dx_ctrl > 0
        fx = (vx - coord_min(1)) / dx_ctrl;
        ix0 = max(0, min(p.n_cx - 4, floor(fx)));
        ux = max(0, min(1, fx - ix0));
        ix_base = ix0 + 1;  % 1-based
    else
        ix_base = 1;
        ux = 0;
    end
    if dy_ctrl > 0
        fy = (vy - coord_min(2)) / dy_ctrl;
        iy0 = max(0, min(p.n_cy - 4, floor(fy)));
        uy = max(0, min(1, fy - iy0));
        iy_base = iy0 + 1;
    else
        iy_base = 1;
        uy = 0;
    end
    if dz_ctrl > 0
        fz = (vz - coord_min(3)) / dz_ctrl;
        iz0 = max(0, min(p.n_cz - 4, floor(fz)));
        uz = max(0, min(1, fz - iz0));
        iz_base = iz0 + 1;
    else
        iz_base = 1;
        uz = 0;
    end

    % 计算 4 个方向基函数值
    Bx = bspline_basis(ux);   % 4x1
    By = bspline_basis(uy);
    Bz = bspline_basis(uz);

    % 3D 张量积: 64 个非零 (Bx ⊗ By ⊗ Bz)
    for dx = 0:3
        for dy = 0:3
            for dz = 0:3
                ix = ix_base + dx;
                iy = iy_base + dy;
                iz = iz_base + dz;
                if ix > p.n_cx || iy > p.n_cy || iz > p.n_cz
                    continue;
                end
                c_idx = (iz-1) * p.n_cx * p.n_cy + (iy-1) * p.n_cx + ix;
                w = Bx(dx+1) * By(dy+1) * Bz(dz+1);

                if abs(w) > 1e-12  % 跳过数值零
                    nnz_count = nnz_count + 1;
                    rows(nnz_count) = v;
                    cols(nnz_count) = c_idx;
                    vals(nnz_count) = w;
                end
            end
        end
    end
end

% 截断到实际非零数
rows = rows(1:nnz_count);
cols = cols(1:nnz_count);
vals = vals(1:nnz_count);

% 构造 sparse 矩阵
B_op = sparse(rows, cols, vals, N_v, N_c);

% --- FIX: Row normalization to enforce partition of unity at boundaries ---
% 边界 voxel 的 4 个 B-spline 基函数中有部分超出控制点网格被跳过,
% 导致行和 < 1 (PoU 违反). 修复: 每行除以行和, 强制 PoU=1.
% 效果: c=4.0*ones → eps_r=4.0 everywhere (而非 inner_mean=2.324)
row_sums_raw = full(sum(B_op, 2));
fprintf('  [B-spline] 行和 (修复前): min=%.6f max=%.6f mean=%.6f (理论=1)\n', ...
    min(row_sums_raw), max(row_sums_raw), mean(row_sums_raw));

% 行归一化: B_op(v,:) /= row_sum(v)
row_sums_safe = max(row_sums_raw, 1e-12);  % 避免除零
B_op = spdiags(1 ./ row_sums_safe, 0, N_v, N_v) * B_op;

% 验证修复后 PoU
row_sums = full(sum(B_op, 2));
fprintf('  [B-spline] 行和 (修复后): min=%.6f max=%.6f mean=%.6f (理论=1, partition of unity)\n', ...
    min(row_sums), max(row_sums), mean(row_sums));

fprintf('  [B-spline] 算子 NNZ=%d (每行 64 邻居 → 实际 %d nnz, 密度 %.2f%%)\n', ...
    nnz_count, nnz_count, 100 * nnz_count / (N_v * N_c));
fprintf('  [B-spline] 内存: %.2f MB (sparse)\n', ...
    whos('B_op').bytes / 1e6);

% 健康检查 (修复后应全部 PASS)
if abs(mean(row_sums) - 1.0) > 1e-6
    fprintf('  [B-spline][WARN] partition of unity 修复后仍偏离 1: mean=%.6f\n', mean(row_sums));
else
    fprintf('  [B-spline] partition of unity 修复成功: mean=%.6f \u2248 1.0\n', mean(row_sums));
end
if abs(min(row_sums) - 1.0) > 1e-6
    fprintf('  [B-spline][WARN] 端点 voxel 修复后仍偏离: min=%.6f\n', min(row_sums));
else
    fprintf('  [B-spline] 端点 PoU 修复成功: min=%.6f \u2248 1.0\n', min(row_sums));
end

% 保存 B_op 到 state 用的辅助元数据
fprintf('  [B-spline] 自由度: 约束/控制点 = 192/%d = 1:%.1f (vs exp06 1:100 改善 38×)\n', ...
    N_c, N_c / 192);
fprintf('  [B-spline] 算子已就绪, 链式法则: ε_r = B_op · c, g_c = B_op^T · g_voxel\n');

end
