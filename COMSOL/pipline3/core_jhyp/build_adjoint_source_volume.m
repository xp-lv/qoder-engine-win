function [f_adj, S_field, F_obs] = build_adjoint_source_volume(voxel, lc, p)
%BUILD_ADJOINT_SOURCE_VOLUME 体积等效源路径的伴随源构建
%
%   伴随源 = -（∂F/∂E）† = P† · ΔJ · [iωε₀(ε_r - 1)] / F_norm
%
%   其中 P†（Born FT 共轭转置）将远场残差反向投影回散射体体积：
%     S(r_v) = Σ_k ΔΩ_k · ΔJ(k) · e^{+ik₀k̂·r_v}
%
%   伴随源 = -iωε₀(ε_r - 1) · S(r_v) / F_obs
%
%   输入:
%       voxel    体素结构
%       lc       光锥数据（Delta_J_perp, J_obs_perp, dOmega, k_dir, k_vec）
%       p        config
%
%   输出:
%       f_adj    [N_inner × 3] 伴随体积电流源（注入 vec1）
%       S_field  [N_inner × 3] 残差反投影场（用于直接项 g_direct）
%       F_obs    归一化因子

inner = voxel.mask_interior;
inner_idx = find(inner);
pos = voxel.pos(inner_idx, :);     % [N_inner × 3]
eps_r = voxel.epsilon_r(inner_idx); % [N_inner × 1]
N_inner = length(inner_idx);

omega = p.omega(1);
eps0 = p.eps0;

% 光锥数据
Delta_J = lc.Delta_J_perp;   % [N_k × 3]
J_obs   = lc.J_obs_perp;     % [N_k × 3]
dOmega  = lc.dOmega;         % [N_k × 1]
k_vec   = lc.k_vec;          % [N_k × 3]
N_k = size(Delta_J, 1);

% 归一化因子 F_obs
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min
    F_obs = 1.0;
end

%% 1. Born FT 共轭转置 P†: 残差反投影
% S(r_v) = Σ_k ΔΩ_k · ΔJ(k) · e^{+ik₀k̂·r_v}
S_field = zeros(N_inner, 3);
for ki = 1:N_k
    phase = exp(1i * pos * k_vec(ki, :)');   % [N_inner × 1]  共轭相位
    S_field = S_field + dOmega(ki) * Delta_J(ki, :) .* phase;
end

%% 2. 伴随源 f_adj（COMSOL 注入的 Je）
% 原理 §7.1：-(∂F/∂E)† = +2iωε₀(ε_r-1) · S / F_obs
%   （因子 2 来自代价函数 ∂F/∂J_hyp = -2ΔJ^H/F_obs 的链式法则）
%
% COMSOL 频域 Maxwell-Ampere（e^{iωt} 约定）：
%   ∇×∇×E - k₀²ε_r E = +iωμ₀·Je
% 故 COMSOL 方程：K·E = +iωμ₀·Je
% 伴随方程（原理 §6.2）：K·λ = -(∂F/∂E)†
%
% 设 Je 使得：+iωμ₀·Je = -(∂F/∂E)† = 2iωε₀(ε_r-1)·S/F_obs
%   Je = 2iωε₀(ε_r-1)·S / (+iωμ₀·F_obs)
%      = +2ε₀(ε_r-1)·S / (μ₀·F_obs)

coeff = +2 * eps0 / p.mu0;  % +2ε₀/μ₀，使 +iωμ₀·Je = 2iωε₀(ε_r-1)·S/F_obs
% S_field 已含 conj(Phi)（exp(+ikr)），此处不额外取 conj
f_adj = (coeff ./ F_obs) .* (eps_r - 1) .* S_field;  % [N_inner x 3]

fprintf('[build_adjoint_volume] 体积伴随源构建完成\n');
fprintf('  N_inner=%d, N_k=%d, F_obs=%.4e\n', N_inner, N_k, F_obs);
fprintf('  |S| mean=%.4e, |f_adj| mean=%.4e\n', ...
    mean(vecnorm(S_field,2,2)), mean(vecnorm(f_adj,2,2)));

end
