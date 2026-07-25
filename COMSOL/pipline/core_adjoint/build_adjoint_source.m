function [f_adj, S_raw, F_obs] = build_adjoint_source(voxel, E_total, lc, p)
%BUILD_ADJOINT_SOURCE 构建伴随源 f_adj
%   [f_adj, S_raw] = build_adjoint_source(voxel, E_total, lc, p)
%
%   公式（修订 2026-06-08，移除 dV 多重计数）:
%     F = Σ_k dΩ·|ΔJ(k)|² / F_obs
%     S_raw(v) = Σ_k dΩ·ΔJ(k)·e^{+ik·r_v}    (k空间残差伴随回投)
%     f_adj(v) = -2·δF/δconj(E)|_{r_v} = +2iωε₀(ε_r-1)·S_raw(v) / F_obs
%        ──────────────────────────────────────────────────────────
%        【关键】f_adj 是「连续场密度」(无 dV)，不是「逐体素偏导」。
%        理由：solve_adjoint 通过 Je = i·f_adj/(ωμ₀) 把它注入 COMSOL
%        作为「域电流密度」，FEM 装配时自动乘 dV 形成正确的离散 RHS。
%        若此处再乘 dV，则装配后 RHS 多算了 dV 倍 → λ 偏小 ~10⁵–10⁶。
%        FD 验证应比较 dF/dE_v ↔ dV_v · f_adj(v)，而非直接比较 f_adj(v)。
%        参考: docs/实验文档/52_Born-FT目标函数下伴随源量级失效分析.md
%
%   输入:
%       voxel   体素网格（epsilon_r, mask_interior, pos）
%       E_total [N_inner × 3] — 内部体素中心全场
%       lc      LightConeData（Delta_J_perp, dOmega, k_vec）
%       p       config
%   输出:
%       f_adj   [N_v × 3] complex — 伴随源（供 COMSOL 伴随求解用）
%       S_raw   [N_v × 3] complex — 空间域残差回投（诊断用）

N_v = length(voxel.epsilon_r);
inner = voxel.mask_interior;

omega = p.omega(1);
eps0 = p.eps0;

% 提取光锥数据
Delta_J = lc.Delta_J_perp;
dOmega  = lc.dOmega;
k_vec   = lc.k_vec;
N_k     = size(Delta_J, 1);

% F_obs 归一化常数
J_obs = lc.J_obs_perp;
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min, F_obs = 1.0; end

%% 1. S_raw(v) = Σ_k dΩ_k · ΔJ(k) · e^{+ik·r_v}
S_raw = zeros(N_v, 3);
for v = find(inner)'
    r_v = voxel.pos(v, :);
    phase = exp(1i * k_vec * r_v(:));   % [N_k × 1], e^{+ikr}
    for d = 1:3
        S_raw(v, d) = sum(dOmega .* Delta_J(:, d) .* phase);
    end
end

%% 2. f_adj(v) = +2·∂F/∂conj(E)|_{r_v} = -2iωε₀(ε_r-1)·S_raw(v) / F_obs
% f_adj 是连续场密度，不含 dV（COMSOL FEM 装配时自动加权）
% solve_adjoint 中会对 λ 取 conj 修正 PML 非自伴性
% 推导: A^Hλ = -f_adj, f_adj = 2∂F/∂E* => coeff = -2i (exp64 verified)
delta_eps = voxel.epsilon_r - 1;
coeff_base = -2i * omega * eps0 / F_obs;
f_adj = zeros(N_v, 3);
for v = find(inner)'
    for d = 1:3
        f_adj(v, d) = coeff_base * delta_eps(v) * S_raw(v, d);
    end
end

fprintf('[build_adjoint_source] |f_adj| mean=%.4e, F_obs=%.4e\n', ...
    mean(vecnorm(f_adj(inner,:), 2, 2)), F_obs);

end
