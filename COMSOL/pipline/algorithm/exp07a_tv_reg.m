function [g_tv_voxel, R_tv, diag] = exp07a_tv_reg(voxel, c, p, B_op)
%EXP07A_TV_REG exp07a TV L1 正则化 (各向同性 L1 范数)
%   [g_tv_voxel, R_tv, diag] = exp07a_tv_reg(voxel, c, p, B_op)
%
%   TV L1 各向同性正则化 (替换 exp04 Tikhonov L2):
%     R_TV = Σ_v ||∇ε_r(v)||_2          (v ∈ inner voxel)
%     g_TV(voxel) = -div(∇ε / |∇ε|)      (subgradient, ε_floor=1e-6)
%     g_TV(c) = B_op^T · g_TV(voxel)     (链式法则)
%
%   输入:
%     voxel    FEM voxel (含 pos, mask_interior, epsilon_r)
%     c        当前控制点系数 [N_c × 1]  (反演变量)
%     p        config (含 lambda_tv, voxel_size, tv_eps_floor)
%     B_op     稀疏 B-spline 算子 [N_v × N_c]
%   输出:
%     g_tv_voxel  TV 在 voxel 空间梯度 [N_v × 1]  (c 空间梯度在主循环算 B_op^T · g)
%     R_tv        当前 R_TV = Σ_v ||∇ε||_2
%     diag        诊断结构 (num_inner, mean_grad_norm, max_grad_norm, num_floor_activated)
%
%   物理含义: TV L1 强制 ε_r 空间分段常数 (跳变集中), 比 Tikhonov L2 强平滑更贴合
%   物理场景 (介电体边界清晰). 配合 B-spline 段内平滑, 整体鼓励"少块大块常数".
%
%   数值实现:
%     - 3D 中心差分 ∇ε = (∂ε/∂x, ∂ε/∂y, ∂ε/∂z)
%     - 边界 voxel 用前/后差分
%     - |∇ε|_floor = max(|∇ε|, ε_floor) 防止 0 除
%     - subgradient = -div(flux) where flux = ∇ε/|∇ε| (各向同性)
%     - 邻接关系用 voxel.pos 重建 3D grid (复用 exp04_tikhonov_reg.m 思路)
%
%   复杂度: O(N_inner × 6) ≈ 4000 次, N_inner=673 时 <0.5 s
%
%   复用前检查: core/ 下无 TV L1 实现 (grep_code 0 匹配)
%   算法族: chebyshev_v5_tikhonov_tv_bspline v5.1
%   决策依据: .research/decisions/ADR-010-bspline-tv-parameterization.md (待写)

fprintf('  [TV L1] 计算各向同性 TV 梯度 (B-spline 链式法则)...\n');

if ~isfield(p, 'lambda_tv'); p.lambda_tv = 0.1; end
if ~isfield(p, 'tv_eps_floor'); p.tv_eps_floor = 1.0e-6; end

inner = voxel.mask_interior;
N_v = length(voxel.epsilon_r);

g_tv_voxel = zeros(N_v, 1);
R_tv = 0.0;
diag = struct('num_inner', 0, 'mean_grad_norm', 0, 'max_grad_norm', 0, ...
              'num_floor_activated', 0, 'R_tv', 0);

if ~any(inner)
    fprintf('  [TV L1][WARN] 无 inner voxel, g_tv 全 0\n');
    return;
end

% 提取 inner voxel 信息
pos_inner = voxel.pos(inner, :);
% 用 c 重算 voxel 空间 ε_r (而非用 voxel.epsilon_r, 保证一致性)
eps_inner_all = B_op * c;  % [N_v × 1]
eps_inner = real(eps_inner_all(inner));
N_inner = length(eps_inner);

% 重建 3D grid 索引 (与 exp04_tikhonov_reg.m 一致)
vx = p.voxel_size;
coord_min = min(pos_inner, [], 1);
ix = round((pos_inner(:,1) - coord_min(1)) / vx) + 1;
iy = round((pos_inner(:,2) - coord_min(2)) / vx) + 1;
iz = round((pos_inner(:,3) - coord_min(3)) / vx) + 1;
Nx = max(ix);
Ny = max(iy);
Nz = max(iz);

% 准备 3D ε grid (NaN 表示无 inner voxel)
eps_3d = nan(Nx*Ny*Nz, 1);
idx3d = (iz - 1) * Nx * Ny + (iy - 1) * Nx + ix;
eps_3d(idx3d) = eps_inner;

fprintf('  [TV L1] inner N=%d, 3D grid %dx%dx%d\n', N_inner, Nx, Ny, Nz);

% 6 邻 offset
neighbor_offsets = [-1, 0, 0; 1, 0, 0; 0,-1, 0; 0, 1, 0; 0, 0,-1; 0, 0, 1];

% 阶段 1: 计算每个 inner voxel 的 3D 梯度 (中心差分, 边界前/后差分)
grad_eps = nan(N_inner, 3);  % [N_inner × 3] 3D 梯度
grad_norm = nan(N_inner, 1);
floor_count = 0;

for v = 1:N_inner
    i = ix(v);
    j = iy(v);
    k = iz(v);
    eps_v = eps_inner(v);

    for d = 1:3  % x, y, z
        d_offset = neighbor_offsets(d, :);
        % 前向邻居
        i_fwd = i + d_offset(1);
        j_fwd = j + d_offset(2);
        k_fwd = k + d_offset(3);
        % 后向邻居
        i_bwd = i - d_offset(1);
        j_bwd = j - d_offset(2);
        k_bwd = k - d_offset(3);

        % 前向: 边界外或 NaN → 前差分 (eps_fwd - eps_v) / vx
        if i_fwd >= 1 && i_fwd <= Nx && j_fwd >= 1 && j_fwd <= Ny && k_fwd >= 1 && k_fwd <= Nz
            idx_fwd = (k_fwd-1)*Nx*Ny + (j_fwd-1)*Nx + i_fwd;
            eps_fwd = eps_3d(idx_fwd);
        else
            eps_fwd = NaN;  % 边界外
        end

        % 后向
        if i_bwd >= 1 && i_bwd <= Nx && j_bwd >= 1 && j_bwd <= Ny && k_bwd >= 1 && k_bwd <= Nz
            idx_bwd = (k_bwd-1)*Nx*Ny + (j_bwd-1)*Nx + i_bwd;
            eps_bwd = eps_3d(idx_bwd);
        else
            eps_bwd = NaN;
        end

        % 中心差分: 两个都有; 否则前/后差分; 否则 0
        if ~isnan(eps_fwd) && ~isnan(eps_bwd)
            grad_d = (eps_fwd - eps_bwd) / (2 * vx);
        elseif ~isnan(eps_fwd)
            grad_d = (eps_fwd - eps_v) / vx;
        elseif ~isnan(eps_bwd)
            grad_d = (eps_v - eps_bwd) / vx;
        else
            grad_d = 0.0;  % 孤立 voxel
        end

        grad_eps(v, d) = grad_d;
    end

    % 3D 梯度模长
    gn = norm(grad_eps(v, :));
    grad_norm(v) = gn;

    % ε_floor 处理
    if gn < p.tv_eps_floor
        floor_count = floor_count + 1;
        % subgradient 在 0 处是 subgradient set, 取 0 简化
        g_tv_voxel_v = 0.0;
    else
        % 各向同性 subgradient: div(∇ε/|∇ε|) → 3D 散度
        flux = grad_eps(v, :) / gn;  % [1×3] 单位向量
        % 散度 = Σ_d flux_d
        % div = ∂flux_x/∂x + ∂flux_y/∂y + ∂flux_z/∂z
        % 同样用前/后差分
        div_flux = 0.0;
        for d = 1:3
            d_offset = neighbor_offsets(d, :);
            % 邻居位置 (j_fwd, k_fwd)
            i_fwd = i + d_offset(1);
            j_fwd = j + d_offset(2);
            k_fwd = k + d_offset(3);
            i_bwd = i - d_offset(1);
            j_bwd = j - d_offset(2);
            k_bwd = k - d_offset(3);

            % 找邻居 voxel 索引
            if i_fwd >= 1 && i_fwd <= Nx && j_fwd >= 1 && j_fwd <= Ny && k_fwd >= 1 && k_fwd <= Nz
                idx_fwd = (k_fwd-1)*Nx*Ny + (j_fwd-1)*Nx + i_fwd;
                % 邻居 voxel 在 v 列表中的索引 (NaN 表示非 inner)
                eps_fwd_v = eps_3d(idx_fwd);
                if ~isnan(eps_fwd_v)
                    % 找邻居 v 索引
                    fwd_v = find(idx3d == idx_fwd, 1);
                    if ~isempty(fwd_v) && fwd_v <= N_inner
                        gn_fwd = grad_norm(fwd_v);
                        if gn_fwd >= p.tv_eps_floor
                            flux_fwd = grad_eps(fwd_v, d) / gn_fwd;
                        else
                            flux_fwd = 0;
                        end
                    else
                        flux_fwd = 0;
                    end
                else
                    flux_fwd = 0;  % 邻居是 outer (ε=1.0 锁死, flux=0)
                end
            else
                flux_fwd = 0;  % 边界外
            end

            if i_bwd >= 1 && i_bwd <= Nx && j_bwd >= 1 && j_bwd <= Ny && k_bwd >= 1 && k_bwd <= Nz
                idx_bwd = (k_bwd-1)*Nx*Ny + (j_bwd-1)*Nx + i_bwd;
                eps_bwd_v = eps_3d(idx_bwd);
                if ~isnan(eps_bwd_v)
                    bwd_v = find(idx3d == idx_bwd, 1);
                    if ~isempty(bwd_v) && bwd_v <= N_inner
                        gn_bwd = grad_norm(bwd_v);
                        if gn_bwd >= p.tv_eps_floor
                            flux_bwd = grad_eps(bwd_v, d) / gn_bwd;
                        else
                            flux_bwd = 0;
                        end
                    else
                        flux_bwd = 0;
                    end
                else
                    flux_bwd = 0;
                end
            else
                flux_bwd = 0;
            end

            div_flux = div_flux + (flux_fwd - flux_bwd) / (2 * vx);
        end

        g_tv_voxel_v = -div_flux;
    end

    % 写入 g_tv (inner 部分)
    inner_idx = find(inner);
    g_tv_voxel(inner_idx(v)) = g_tv_voxel_v;

    % R_TV 累加 (各向同性 L1 范数)
    R_tv = R_tv + gn;
end

% 诊断
diag = struct(...
    'num_inner', N_inner, ...
    'mean_grad_norm', mean(grad_norm), ...
    'max_grad_norm', max(grad_norm), ...
    'num_floor_activated', floor_count, ...
    'R_tv', R_tv, ...
    'fraction_floor_activated', floor_count / max(N_inner, 1));

fprintf('  [TV L1] 完成: N=%d, R_TV=%.4e, mean|∇ε|=%.4f, max|∇ε|=%.4f\n', ...
    N_inner, R_tv, diag.mean_grad_norm, diag.max_grad_norm);
fprintf('  [TV L1] ε_floor 激活: %d/%d (%.1f%%) — 反映 TV 强稀疏先验\n', ...
    floor_count, N_inner, 100 * diag.fraction_floor_activated);
fprintf('  [TV L1] 链式法则: g_c_tv = B_op^T · g_tv_voxel (在主循环算)\n');

end
