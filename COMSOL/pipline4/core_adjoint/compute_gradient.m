function [g, g_re, g_im] = compute_gradient(voxel, E_total, lambda, p)
%COMPUTE_GRADIENT 单体素复数介电梯度（pipline4 专用）
%
%   完整梯度 g = dF/dε_r，基于 Wirtinger 微积分的复对称 K 伴随法：
%
%     dF/dε'  = +2·k₀²·Re(∫_Ω E·λ dV)    (bilinear, 无共轭)
%     dF/dε'' = -2·k₀²·Im(∫_Ω E·λ dV)
%
%   推导（原理）:
%     F = Σ|E-E*|²/F_norm,  K(ε)·u = f,  K 复对称
%     dF = -2·Re(λ^T · dK · u)
%     dK/dε' = -k₀²·M  →  dF/dε' = +2k₀²·Re(λ^T·M·u)
%     dK/dε''= -jk₀²·M →  dF/dε''= -2k₀²·Im(λ^T·M·u)
%     其中 λ^T·M·u ≈ ∫_Ω E·λ dV（bilinear 内积）
%
%   单体素：ε_r 全均匀，积分 = Σ_inner dV·(E·λ)，无空间循环
%
%   内积约定:
%     'bilinear'  = E·λ = Σ E_i·λ_i      （COMSOL 复对称 K 正确公式）
%     'hermitian' = conj(E)·λ = Σ conj(E_i)·λ_i  （旧版，已知偏差）
%
%   输入:
%       voxel    体素结构（mask_interior, pos, dV）
%       E_total  [N_inner × 3] 内部体素中心正演电场
%       lambda   [N_inner × 3] 内部体素中心伴随场
%       p        config（使用 gradient_dot, k0）
%   输出:
%       g    complex — g = g_re + j·g_im（复数 packing）
%       g_re double  — dF/dε'
%       g_im double  — dF/dε''

inner = voxel.mask_interior;
inner_idx = find(inner);
N_in = length(inner_idx);
dV = voxel.dV(inner_idx);

k0_sq = p.k0^2;

% --- 内积约定 ---
dot_mode = 'bilinear';
if isfield(p, 'gradient_dot'), dot_mode = p.gradient_dot; end

% --- 计算 ∫_Ω E·λ dV（体积分，bilinear 或 hermitian）---
integral_EL = 0;
for vi = 1:N_in
    Ev = E_total(vi, :);    % [1×3]
    Lv = lambda(vi, :);     % [1×3]

    if strcmp(dot_mode, 'bilinear')
        % bilinear: E·λ = Σ E_i·λ_i（无共轭）
        EL = sum(Ev .* Lv);
    else
        % hermitian: conj(E)·λ = Σ conj(E_i)·λ_i
        EL = sum(conj(Ev) .* Lv);
    end

    integral_EL = integral_EL + dV(vi) * EL;
end

% --- 梯度公式（因子 2 来自 Wirtinger dF = 2·Re(...)）---
g_re = +2 * k0_sq * real(integral_EL);
g_im = -2 * k0_sq * imag(integral_EL);

g = g_re + 1j * g_im;

fprintf('[compute_gradient] dot=%s, ∫E·λ = %.6e %+.6ei\n', ...
    dot_mode, real(integral_EL), imag(integral_EL));
fprintf('  g_re = dF/dε''  = %+.6e\n', g_re);
fprintf('  g_im = dF/dε'''' = %+.6e\n', g_im);
fprintf('  |g_re| = %.4e, |g_im| = %.4e\n', abs(g_re), abs(g_im));

end
