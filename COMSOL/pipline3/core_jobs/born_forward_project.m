function [J_hyp, lc] = born_forward_project(voxel, E_voxel, p, lc_obs)
%BORN_FORWARD_PROJECT 体积等效源 Born FT 正向算子
%
%   J_equi(r) = -iωε₀(ε_r(r) - 1) · E_total(r)
%   J_hyp(k̂) = ∫_V J_equi(r) · e^{-ik₀k̂·r} dV    (Born FT)
%
%   离散化：J_hyp(k̂_i) = Σ_v dV_v · J_equi(r_v) · e^{-ik₀k̂_i·r_v}
%
%   输入:
%       voxel    体素结构（pos, dV, epsilon_r, mask_interior）
%       E_voxel  体素中心电场 [N_inner × 3]
%       p        config
%       lc_obs   光锥数据（提供 k_dir, k_vec, dOmega）
%
%   输出:
%       J_hyp    [N_k × 3] 假设远场（Born FT 投影）
%       lc       更新后的光锥数据

inner = voxel.mask_interior;
inner_idx = find(inner);
pos = voxel.pos(inner_idx, :);     % [N_inner × 3]
dV = voxel.dV(inner_idx);          % [N_inner × 1]
eps_r = voxel.epsilon_r(inner_idx); % [N_inner × 1]

% 等效电流源 J_equi = -iωε₀(ε_r - 1) · E
J_equi = -1i * p.omega * p.eps0 * (eps_r - 1) .* E_voxel;  % [N_inner × 3]

% 从 lc_obs 获取 k 方向采样
k_dir = lc_obs.k_dir;    % [N_k × 3]
k_vec = lc_obs.k_vec;    % [N_k × 3] = k0 * k_dir
dOmega = lc_obs.dOmega;  % [N_k × 1]
N_k = size(k_dir, 1);
N_inner = size(pos, 1);

% Born FT: J_hyp(k̂_i) = Σ_v dV_v · J_equi(v) · e^{-ik₀k̂_i·r_v}
J_hyp = zeros(N_k, 3);
for ki = 1:N_k
    phase = exp(-1i * pos * k_vec(ki, :)');   % [N_inner × 1]
    J_hyp(ki, :) = sum(dV .* J_equi .* phase, 1);
end

% 填充 lc
lc = lc_obs;
lc.J_hyp_perp = J_hyp;
if ~isempty(lc.J_obs_perp) && size(lc.J_obs_perp,1) == N_k
    lc.Delta_J_perp = lc.J_obs_perp - J_hyp;
else
    lc.Delta_J_perp = [];
end

fprintf('[born_forward] J_hyp Born FT 完成: N_k=%d, N_voxel=%d\n', N_k, N_inner);
fprintf('  |J_hyp| mean=%.4e, |ΔJ| mean=%.4e\n', ...
    mean(vecnorm(J_hyp,2,2)), mean(vecnorm(lc.Delta_J_perp,2,2)));

end
