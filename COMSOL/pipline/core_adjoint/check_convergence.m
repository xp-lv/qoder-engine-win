function [converged, residual] = check_convergence(lc, p)
%CHECK_CONVERGENCE 收敛判断
%   [converged, residual] = check_convergence(lc, p)
%
%   判据: residual = sqrt(F) = ||ΔJ|| / ||J_obs|| < p.eps_tol
%
%   输入:
%       lc  LightConeData（含 J_obs_perp, J_hyp_perp, dOmega）
%       p   config（含 eps_tol, F_obs_min）
%   输出:
%       converged  logical
%       residual   double — 相对残差

J_obs = lc.J_obs_perp;
J_hyp = lc.J_hyp_perp;

if isempty(J_hyp)
    converged = false;
    residual = inf;
    return;
end

Delta_J = J_obs - J_hyp;
F_obs = sum(lc.dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min, F_obs = 1.0; end

F = sum(lc.dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs;
residual = sqrt(F);

converged = residual < p.eps_tol;

end
