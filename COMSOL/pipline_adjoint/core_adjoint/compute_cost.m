function F = compute_cost(lc, p)
%COMPUTE_COST 代价函数 F = ||J_obs - J_hyp||² / ||J_obs||²
%   F = compute_cost(lc, p)
%
%   输入:
%       lc  LightConeData（含 J_obs_perp, J_hyp_perp, dOmega）
%       p   config（含 F_obs_min）
%   输出:
%       F   double — 归一化残差

J_obs = lc.J_obs_perp;
J_hyp = lc.J_hyp_perp;
dOmega = lc.dOmega;

Delta_J = J_obs - J_hyp;
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));

if F_obs < p.F_obs_min
    F_obs = 1.0;
end

F = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs;

end
