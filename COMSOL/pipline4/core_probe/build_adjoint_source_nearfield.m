function [Je, F_norm, residual] = build_adjoint_source_nearfield(voxel, E_hyp, E_truth, p, use_gauss)
%BUILD_ADJOINT_SOURCE_NEARFIELD 体积 L2 代价函数的伴随源（pipline4，Gauss 积分版）
%
%   代价函数 (Gauss): F = Σ_gp w_gp |E(gp) - E*(gp)|² / Σ_gp w_gp |E*(gp)|²
%
%   Wirtinger 导数: ∂F/∂E(gp) = w_gp · conj(E(gp) - E*(gp)) / F_norm
%
%   伴随方程（K 复对称）: K·λ = ∂F/∂u 的 FEM 投影
%   COMSOL Maxwell-Ampere: K·λ = iωμ₀·Je
%   故 Je = conj(E-E*) / (iωμ₀·F_norm)，在所有内部体素处非零
%
%   输入:
%       voxel      体素结构（mask_interior, pos, dV, gauss_weights）
%       E_hyp      [N × 3] 当前 ε_r 下的电场
%       E_truth    [N × 3] 真值 ε_r 下的电场
%       p          config
%       use_gauss  (可选) logical，是否使用 Gauss 积分计算 F_norm
%   输出:
%       Je       [N × 3] complex — 伴随电流密度
%       F_norm   归一化因子
%       residual [N × 3] complex — 残差 r = E_hyp - E_truth

if nargin < 5
    use_gauss = isfield(voxel, 'gauss_weights') && ~isempty(voxel.gauss_weights) ...
        && isfield(voxel, 'gauss_pos') && ~isempty(voxel.gauss_pos);
end

% --- 残差 ---
residual = E_hyp - E_truth;

% --- 归一化因子 ---
if use_gauss
    gw = voxel.gauss_weights;
    F_norm = sum(gw .* sum(abs(E_truth).^2, 2));
else
    inner = voxel.mask_interior;
    dV = voxel.dV(inner);
    F_norm = sum(dV .* sum(abs(E_truth).^2, 2));
end

if F_norm < p.F_norm_min
    F_norm = 1.0;
    fprintf('[build_adjoint_vol] WARNING: F_norm 极小, 使用 F_norm=1\n');
end

% --- 伴随源 Je ---
% COMSOL 方程: K·λ = iωμ₀·Je
% 故: iωμ₀·Je(r_v) = conj(r_v) / F_norm
%     Je(r_v) = conj(r_v) / (iωμ₀·F_norm)
omega_mu0 = p.omega * p.mu0;
coeff = 1 / (1j * omega_mu0);   % = -j / (ωμ₀)

Je = (coeff / F_norm) * conj(residual);

fprintf('[build_adjoint_vol] 伴随源构建完成');
if use_gauss
    fprintf(' (Gauss, %d 点)\n', size(E_hyp,1));
else
    fprintf(' (质心, %d 点)\n', size(E_hyp,1));
end
fprintf('  F_norm=%.4e\n', F_norm);
fprintf('  |residual| mean=%.4e, |Je| mean=%.4e\n', ...
    mean(vecnorm(residual, 2, 2)), mean(vecnorm(Je, 2, 2)));

% 报告当前 F 值
if use_gauss
    F_val = sum(gw .* sum(abs(residual).^2, 2)) / F_norm;
else
    F_val = sum(dV .* sum(abs(residual).^2, 2)) / F_norm;
end
fprintf('  F = %.6e\n', F_val);

end
