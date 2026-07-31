function [g, g_re, g_im] = compute_gradient(voxel, E_field, lambda, p, lambda_gauss)
%COMPUTE_GRADIENT 复数介电梯度（pipline4）
%
%   公式（FD 标定符号）:
%     dF/dε'  = -k₀²·Re(∫_Ω E·λ dV)
%     dF/dε'' = -k₀²·Im(∫_Ω E·λ dV)
%
%   注意: 此公式在均匀 ε_r 场景下 FD sign 6/6 PASS。
%   对于非均匀 ε_r 且 ε_im 符号变化场景，需要使用
%   compute_gradient_kmatrix.m（K 矩阵精确法）。
%
%   输入:
%       voxel         体素结构
%       E_field       [N × 3] Gauss 点正演电场（总场 emw.Ex）
%       lambda        [N × 3] 体素中心伴随场
%       p             config
%       lambda_gauss  (可选) Gauss 点伴随场

k0_sq = p.k0^2;

% --- 内积约定 ---
dot_mode = 'bilinear';
if isfield(p, 'gradient_dot'), dot_mode = p.gradient_dot; end

% --- 选择积分模式 ---
use_gauss = false;
if nargin >= 5 && ~isempty(lambda_gauss) && isfield(voxel, 'gauss_weights') && ~isempty(voxel.gauss_weights)
    use_gauss = true;
end

if use_gauss
    gw = voxel.gauss_weights;
    Ng = size(lambda_gauss, 1);
    if size(E_field, 1) == Ng
        E_gp = E_field;
    else
        use_gauss = false;
    end
end

if use_gauss
    integral_EL = 0;
    for vi = 1:Ng
        Ev = E_gp(vi, :);
        Lv = lambda_gauss(vi, :);
        if strcmp(dot_mode, 'bilinear')
            EL = sum(Ev .* Lv);
        else
            EL = sum(conj(Ev) .* Lv);
        end
        integral_EL = integral_EL + gw(vi) * EL;
    end
else
    inner = voxel.mask_interior;
    inner_idx = find(inner);
    dV = voxel.dV(inner_idx);
    N_in = length(inner_idx);
    integral_EL = 0;
    for vi = 1:N_in
        Ev = E_field(vi, :);
        Lv = lambda(vi, :);
        if strcmp(dot_mode, 'bilinear')
            EL = sum(Ev .* Lv);
        else
            EL = sum(conj(Ev) .* Lv);
        end
        integral_EL = integral_EL + dV(vi) * EL;
    end
end

% --- 梯度公式 ---
g_re = -k0_sq * real(integral_EL);
g_im = -k0_sq * imag(integral_EL);

g = g_re + 1j * g_im;

fprintf('[compute_gradient] ∫E·λ = %.6e %+.6ei → g_re=%+.4e, g_im=%+.4e\n', ...
    real(integral_EL), imag(integral_EL), g_re, g_im);

end
