function [Je, F_norm, residual] = build_adjoint_source_nearfield(probe, E_hyp, E_truth, p)
%BUILD_ADJOINT_SOURCE_NEARFIELD 近场 L2 代价函数的伴随源
%
%   代价函数: F = Σ_p |E(r_p) - E*(r_p)|² / Σ_p |E*(r_p)|²
%
%   Wirtinger 导数: ∂F/∂E(r_p) = 2·conj(E(r_p) - E*(r_p)) / F_norm
%
%   伴随方程（K 复对称）: K·λ = ∂F/∂E 的 FEM 投影
%   COMSOL Maxwell-Ampere: K·λ = iωμ₀·Je
%   故 Je = 2·conj(r_p) / (iωμ₀·F_norm)，在探针点处非零
%
%   输入:
%       probe    探针点结构（pos, weight）
%       E_hyp    [N_probe × 3] 当前 ε_r 下的探针点电场
%       E_truth  [N_probe × 3] 真值 ε_r 下的探针点电场（固定不变）
%       p        config
%
%   输出:
%       Je       [N_probe × 3] complex — COMSOL ExternalCurrentDensity 值
%       F_norm   归一化因子 = Σ|E*|²
%       residual [N_probe × 3] complex — 残差 r_p = E_hyp - E_truth

% --- 残差 ---
residual = E_hyp - E_truth;

% --- 归一化因子 ---
w = probe.weight;
F_norm = sum(w .* sum(abs(E_truth).^2, 2));

if F_norm < p.F_norm_min
    F_norm = 1.0;
    fprintf('[build_adjoint_nearfield] WARNING: F_norm 极小, 使用 F_norm=1\n');
end

% --- 伴随源 Je ---
% COMSOL 方程: K·λ = iωμ₀·Je
% 伴随方程:    K·λ = 2·conj(r_p) / F_norm（探针点处）
% 故: Je = 2·conj(r_p) / (iωμ₀·F_norm)
%
% 展开系数: 2/(iωμ₀) = -2j/(ωμ₀)
omega_mu0 = p.omega * p.mu0;
coeff = 2 / (1j * omega_mu0);   % = -2j / (ωμ₀)

Je = (coeff / F_norm) * w .* conj(residual);   % [N_probe × 3]

fprintf('[build_adjoint_nearfield] 近场伴随源构建完成\n');
fprintf('  N_probe=%d, F_norm=%.4e\n', size(E_hyp,1), F_norm);
fprintf('  |residual| mean=%.4e, |Je| mean=%.4e\n', ...
    mean(vecnorm(residual, 2, 2)), mean(vecnorm(Je, 2, 2)));
fprintf('  F = %.6e\n', sum(w .* sum(abs(residual).^2, 2)) / F_norm);

end
