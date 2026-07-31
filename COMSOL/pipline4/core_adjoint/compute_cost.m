function F = compute_cost(voxel, E_hyp, E_truth, p, use_gauss)
%COMPUTE_COST 体积 L2 代价函数（pipline4，Gauss 积分版）
%   F = compute_cost(voxel, E_hyp, E_truth, p)
%   F = compute_cost(voxel, E_hyp, E_truth, p, use_gauss)
%
%   Gauss 积分: F = Σ_gp w_gp |E(gp) - E*(gp)|² / Σ_gp w_gp |E*(gp)|²
%   质心积分:   F = Σ_v dV_v |E(r_v) - E*(r_v)|² / Σ_v dV_v |E*(r_v)|²
%
%   输入:
%       voxel      体素结构（mask_interior, dV, gauss_weights）
%       E_hyp      [N × 3] 当前 ε_r 下的电场
%       E_truth    [N × 3] 真值电场
%       p          config
%       use_gauss  (可选) logical，是否使用 Gauss 积分
%   输出:
%       F        double — 归一化残差（标量）

if nargin < 5
    use_gauss = isfield(voxel, 'gauss_weights') && ~isempty(voxel.gauss_weights) ...
        && isfield(voxel, 'gauss_pos') && ~isempty(voxel.gauss_pos);
end

residual = E_hyp - E_truth;

if use_gauss
    % Gauss 积分
    gw = voxel.gauss_weights;
    F_norm = sum(gw .* sum(abs(E_truth).^2, 2));
    F = sum(gw .* sum(abs(residual).^2, 2)) / F_norm;
else
    % 质心积分
    inner = voxel.mask_interior;
    dV = voxel.dV(inner);
    F_norm = sum(dV .* sum(abs(E_truth).^2, 2));
    F = sum(dV .* sum(abs(residual).^2, 2)) / F_norm;
end

if F_norm < p.F_norm_min
    F_norm = 1.0;
end

end
