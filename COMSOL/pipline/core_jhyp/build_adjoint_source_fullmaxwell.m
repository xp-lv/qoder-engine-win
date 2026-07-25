function [f_adj, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, p)
%BUILD_ADJOINT_SOURCE_FULLMAXWELL Full Maxwell伴随源（表面反向投影）
%   [f_adj, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, p)
%
%   A07核心: 替代Born FT的build_adjoint_source。
%   Born FT: f_adj(v) ∝ (ε_r-1)·Σ_k ΔJ·e^{+ikr_v}  (体内voxel)
%   Full Maxwell: f_adj(s) ∝ Σ_k ΔJ·e^{+ikr_s}       (测量球面)
%
%   关键区别:
%     - 伴随源构建在测量球面 grid.pos，而非体内 voxel.pos
%     - 无 (ε_r-1) 因子（表面等效导数不含此因子）
%     - 简单反向投影近似（忽略表面等效极化投影核，捕获主相位关系）
%
%   物理: ∂J_hyp/∂E_scat 的伴随算子将 k 空间残差反向投影到测量表面
%         作为等效表面电流。COMSOL FEM 自然传播此表面源回内部。
%
%   输入:
%       grid    测量网格 (pos [N_surface×3], norm, weight)
%       lc      LightConeData (Delta_J_perp, J_obs_perp, dOmega, k_vec)
%       p       config
%   输出:
%       f_adj       [N_surface × 3] complex  伴随源（电流密度）
%       source_pos  [N_surface × 3]          伴随源位置（=grid.pos）
%       F_obs       scalar                   归一化因子

N_surface = size(grid.pos, 1);

omega = p.omega(1);
eps0 = p.eps0;

% 提取光锥数据
Delta_J = lc.Delta_J_perp;   % [N_k × 3]
J_obs   = lc.J_obs_perp;     % [N_k × 3]
dOmega  = lc.dOmega;         % [N_k × 1]
k_vec   = lc.k_vec;          % [N_k × 3]
N_k     = size(Delta_J, 1);

% F_obs 归一化（与 Born FT 一致）
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min
    F_obs = 1.0;
end

%% 1. 反向投影: S_surf(s) = Σ_k dΩ_k · ΔJ(k) · e^{+ik·r_s}
% 对每个表面点，将 N_k 个 k 方向残差加权叠加
S_surf = zeros(N_surface, 3);
for s = 1:N_surface
    r_s = grid.pos(s, :);
    phase = exp(1i * k_vec * r_s(:));  % [N_k × 1], e^{+ikr_s}
    for d = 1:3
        S_surf(s, d) = sum(dOmega .* Delta_J(:, d) .* phase);
    end
end

%% 2. 伴随源: f_adj(s) = -i·ω·ε₀/2 · S_surf(s) / F_obs
% 修正 2026-06-27: 系数从 +2i 改为 -i/2
% 推导: adjoint 梯度 g = 2i*(coeff/ωε₀)*g_Born
%   令 2i*coeff/ωε₀ = 1 → coeff = ωε₀/(2i) = -iωε₀/2
% 旧系数 +2i 导致 g_adjoint/g_Born = -4 (符号反+4x放大)
%   这解释了所有 B03 Armijo 拒绝: 梯度方向完全相反!
coeff_base = -0.5i * omega * eps0 / F_obs;
f_adj = coeff_base * S_surf;

fprintf('[build_adjoint_source_fullmaxwell] N_surface=%d, |f_adj| mean=%.4e, F_obs=%.4e\n', ...
    N_surface, mean(vecnorm(f_adj, 2, 2)), F_obs);

source_pos = grid.pos;

end
