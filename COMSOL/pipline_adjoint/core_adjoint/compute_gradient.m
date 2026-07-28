function [g, g_direct, g_indirect] = compute_gradient(voxel, E_total, S_raw, lambda, p, F_obs_in, use_gi, E_gauss, lambda_gauss)
%COMPUTE_GRADIENT Exact gradient g = dF/deps_r
%   g = compute_gradient(voxel, E_total, S_raw, lambda, p)
%   [g, g_direct, g_indirect] = compute_gradient(...)
%
%   Formula (exp64-66 verified, 2026-06-08):
%     g(v) = gd + gi
%     gd = +2*w*eps0*dV*Im{dot(E,S)}/F_obs   (doc57: conj flip)
%     gi = -k0^2 * int_tet Re(E*lambda) dV   (via 4-pt Gauss if available)
%
%   Gauss quadrature (exp65-66 verified):
%     When voxel.gauss_pos is non-empty AND E_gauss/lambda_gauss are provided,
%     gi uses 4-point Gauss rule per tet. This improves gradient accuracy from
%     ~0.80 ratio (centroid) to ~0.93 ratio (Gauss), verified by directional
%     derivative on eps_r={4,6,4+6} initial guesses.
%
%   use_gi (optional, default=true): set false to zero gi (gd-only fallback)
%
%   Optional Gauss inputs (must both be provided or both absent):
%       E_gauss     [4*N_inner x 3] E at Gauss pts (before adjoint solve)
%       lambda_gauss [4*N_inner x 3] lambda at Gauss pts (after adjoint solve)
%
%   MATLAB semantics:
%     dot(E,S) = conj(E)*S  (Hermitian inner product)
%     gi uses dot(E, lambda) = conj(E)*lambda = Re[conj(E)*lambda]

N_v = length(voxel.epsilon_r);
inner = voxel.mask_interior;
N_in = sum(inner);
omega = p.omega(1); k0 = p.k0; eps0 = p.eps0; dV_vec = voxel.dV;

% ★ pipline_adjoint 修正 2026-07-27：
%   K 复对称 -> Wirtinger 导数 -> dF/deps = -k0^2*dV*Re(conj(lambda)*E)
%   即 Hermitian 内积，负号
%   旧版 bilinear 是错误的推导（忽略了 COMSOL 弱形式中的 conj 传递）
if isfield(p, 'gradient_dot') && strcmp(p.gradient_dot, 'hermitian_neg')
    dot_mode = 'hermitian_neg';
else
    dot_mode = 'hermitian_neg';  % 默认且唯一正确模式
end
fprintf('[compute_gradient] dot_mode=%s\n', dot_mode);

E_vox = zeros(N_v, 3);
if size(E_total, 1) == N_in, E_vox(inner, :) = E_total;
else, error('compute_gradient: E_total size mismatch'); end

lambda_vox = zeros(N_v, 3);
if size(lambda, 1) == N_in, lambda_vox(inner, :) = lambda;
else, error('compute_gradient: lambda size mismatch'); end

if nargin < 6 || isempty(F_obs_in), F_obs = 1.0; else, F_obs = F_obs_in; end
if nargin < 7 || isempty(use_gi), use_gi = true; end

% Determine Gauss quadrature availability
use_gauss = use_gi && (nargin >= 9) && ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && ~isempty(voxel.gauss_pos) && size(E_gauss,1) == size(voxel.gauss_pos,1);
if ~use_gauss && use_gi && ~isempty(voxel.gauss_pos)
    % Gauss points available but fields not provided -> fallback warning once
    persistent warned_gauss_fallback;
    if isempty(warned_gauss_fallback)
        fprintf('[compute_gradient] Gauss可用但未提供场值，使用质心近似\n');
        warned_gauss_fallback = true;
    end
end

g = zeros(N_v, 1);
if nargout >= 2, g_direct = zeros(N_v, 1); end
if nargout >= 3, g_indirect = zeros(N_v, 1); end

if use_gauss
    gauss_w = voxel.gauss_w;  % [4 x 1]
    inner_idx_list = find(inner);
    for vi = 1:N_in
        v_idx = inner_idx_list(vi);
        Ev = E_vox(v_idx, :); lambda_v = lambda_vox(v_idx, :);
        S_v = S_raw(v_idx, :); dV_v = dV_vec(v_idx);

        gd = +2 * omega * eps0 * dV_v * imag(dot(Ev, S_v)) / F_obs;

        % Gauss quadrature for gi
        gp_range = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            Eg = E_gauss(gp_range(gpi), :);
            Lg = lambda_gauss(gp_range(gpi), :);
            gs = gs + gauss_w(gpi) * real(grad_dot(Eg, Lg, dot_mode));
        end
        gi = -k0^2 * dV_v * gs;

        g(v_idx) = gd + gi;
        if nargout >= 2, g_direct(v_idx) = gd; end
        if nargout >= 3, g_indirect(v_idx) = gi; end
    end
else
    % Centroid approximation (original path)
    for v = find(inner)'
        Ev = E_vox(v, :); lambda_v = lambda_vox(v, :);
        S_v = S_raw(v, :); dV_v = dV_vec(v);

        gd = +2 * omega * eps0 * dV_v * imag(dot(Ev, S_v)) / F_obs;
        if use_gi
            gi = -k0^2 * dV_v * real(grad_dot(Ev, lambda_v, dot_mode));
        else
            gi = 0;
        end

        g(v) = gd + gi;
        if nargout >= 2, g_direct(v) = gd; end
        if nargout >= 3, g_indirect(v) = gi; end
    end
end

fprintf('[compute_gradient] |g| mean=%.4e, max=%.4e (gi=%s, gauss=%s, dot=%s)\n', ...
    mean(abs(g(inner))), max(abs(g(inner))), string(use_gi), string(use_gauss), dot_mode);
end

%% ====== 梯度内积函数 ======
function val = grad_dot(E, lam, mode)
    % pipline_adjoint: 唯一正确模式 hermitian_neg
    % g_v = -k0^2*dV*Re(conj(lambda)*E)
    % 外层已经乘了 -k0^2*dV，所以这里只返回 conj(lambda)*E 的内积值
    val = conj(lam) * E.';   % conj(lambda) · E (Hermitian)
    val = sum(val, 1).';     % 标量
    % 注意：调用方已经乘了 -k0^2*dV_v，所以这里返回的实部就是
    % gi = -k0^2*dV*Re(conj(lambda)*E) 中的 Re(conj(lambda)*E)
    % 但 grad_dot 返回的是复数值，外层取 Re
end
