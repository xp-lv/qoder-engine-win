function [g, g_direct, g_indirect] = compute_gradient(voxel, E_total, S_raw, lambda, p, F_obs_in, use_gi, E_gauss, lambda_gauss)
%COMPUTE_GRADIENT Exact gradient g = dF/deps_r (supports complex eps_r)
%   g = compute_gradient(voxel, E_total, S_raw, lambda, p)
%   [g, g_direct, g_indirect] = compute_gradient(...)
%
%   For real eps_r:
%     g(v) = gd + gi  (real scalar)
%     gd = +2*w*eps0*dV*Im{conj(E)*S}/F_obs     (direct, Hermitian)
%     gi = -k0^2 * dV * Re{conj(E)*lambda}       (indirect, Hermitian)
%
%   For complex eps_r = eps_re + j*eps_im:
%     g(v) = g_re + j*g_im  (complex packing: Re=g_re, Im=g_im)
%     Direct term: Hermitian conj(E)*S
%     Indirect term: bilinear conj(E)*conj(lambda) = conj(E*lambda)
%       (solve_adjoint returns lambda_raw; conj applied in compute_gradient)
%
%     g_re = +2*w*eps0*dV*Im{conj(E)*S}/F_obs  - k0^2*dV*Re{E*lambda}
%     g_im = -2*w*eps0*dV*Re{conj(E)*S}/F_obs  + k0^2*dV*Im{E*lambda}
%
%   g_direct and g_indirect follow the same complex packing convention.
%
%   Gauss quadrature (exp65-66 verified):
%     When voxel.gauss_pos is non-empty AND E_gauss/lambda_gauss are provided,
%     gi uses 4-point Gauss rule per tet.
%
%   use_gi (optional, default=true): set false to zero gi (gd-only fallback)
%
%   Optional Gauss inputs (must both be provided or both absent):
%       E_gauss     [4*N_inner x 3] E at Gauss pts (before adjoint solve)
%       lambda_gauss [4*N_inner x 3] lambda at Gauss pts (after adjoint solve)
%
%   MATLAB semantics:
%     dot(E,S) = conj(E)*S     (Hermitian, used for direct term)
%     After conj(lambda): dot(E, conj(lambda)) = conj(E*lambda)  (bilinear, complex eps_r)

N_v = length(voxel.epsilon_r);
inner = voxel.mask_interior;
N_in = sum(inner);
omega = p.omega(1); k0 = p.k0; eps0 = p.eps0; dV_vec = voxel.dV;

% --- Detect complex eps_r ---
eps_r_inner = voxel.epsilon_r(inner);
is_complex_eps = any(abs(imag(eps_r_inner)) > 0);
if is_complex_eps
    fprintf('[compute_gradient] complex eps_r mode: g = g_re + j*g_im\n');
end

% --- 内积约定选择 (原理 §6.1, §7.5.5) ---
gradient_mode = 'hermitian';
if isfield(p, 'gradient_dot'), gradient_mode = p.gradient_dot; end

E_vox = zeros(N_v, 3);
if size(E_total, 1) == N_in, E_vox(inner, :) = E_total;
else, error('compute_gradient: E_total size mismatch'); end

lambda_vox = zeros(N_v, 3);
if size(lambda, 1) == N_in, lambda_vox(inner, :) = lambda;
else, error('compute_gradient: lambda size mismatch'); end

% 复数 ε_r + bilinear 模式: conj(λ) 把 MATLAB dot 翻转为 bilinear
if is_complex_eps && strcmp(gradient_mode, 'bilinear')
    lambda_vox = conj(lambda_vox);
    if exist('lambda_gauss', 'var') && ~isempty(lambda_gauss)
        lambda_gauss = conj(lambda_gauss);
    end
end

if nargin < 6 || isempty(F_obs_in), F_obs = 1.0; else, F_obs = F_obs_in; end
if nargin < 7 || isempty(use_gi), use_gi = true; end

% Determine Gauss quadrature availability
use_gauss = use_gi && (nargin >= 9) && ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && ~isempty(voxel.gauss_pos) && size(E_gauss,1) == size(voxel.gauss_pos,1);
if ~use_gauss && use_gi && ~isempty(voxel.gauss_pos)
    persistent warned_gauss_fallback;
    if isempty(warned_gauss_fallback)
        fprintf('[compute_gradient] Gauss available but no field values, using centroid\n');
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
        S_v = S_raw(vi, :); dV_v = dV_vec(v_idx);  % S_raw 是 [N_inner×3]，用 vi 索引

        % --- Direct term (g_direct) ---
        % Hermitian: conj(E)*S
        ES = dot(Ev, S_v);  % Hermitian: conj(E)*S
        gd_re = +2 * omega * eps0 * dV_v * imag(ES) / F_obs;

        % --- Indirect term (g_indirect) via 4-pt Gauss ---
        % gi_re = -k0^2*Re[E·λ], gi_im = +k0^2*Im[E·λ] (bilinear，原理 §7.5.3)
        gp_range = (4*(vi-1)+1):(4*vi);
        gs_re = 0; gs_im = 0;
        for gpi = 1:4
            Eg = E_gauss(gp_range(gpi), :);
            Lg = lambda_gauss(gp_range(gpi), :);
            EL = dot(Eg, Lg);  % Hermitian (conj(λ) applied above for complex eps_r)
            gs_re = gs_re + gauss_w(gpi) * real(EL);
            if is_complex_eps
                gs_im = gs_im + gauss_w(gpi) * imag(EL);
            end
        end
        gi_re = -k0^2 * dV_v * gs_re;

        g_re = gd_re + gi_re;

        if is_complex_eps
            % gi_im = -k0^2*Im[E·λ] (bilinear, 直接取 imag)
            gd_im = -2 * omega * eps0 * dV_v * real(ES) / F_obs;
            gi_im = -k0^2 * dV_v * gs_im;
            g_im = gd_im + gi_im;

            g(v_idx) = g_re + 1j * g_im;
            if nargout >= 2, g_direct(v_idx) = gd_re + 1j * gd_im; end
            if nargout >= 3, g_indirect(v_idx) = gi_re + 1j * gi_im; end
        else
            g(v_idx) = g_re;
            if nargout >= 2, g_direct(v_idx) = gd_re; end
            if nargout >= 3, g_indirect(v_idx) = gi_re; end
        end
    end
else
    % Centroid approximation
    inner_idx_list = find(inner);
    for vi = 1:N_in
        v = inner_idx_list(vi);
        Ev = E_vox(v, :); lambda_v = lambda_vox(v, :);
        S_v = S_raw(vi, :); dV_v = dV_vec(v);  % S_raw 是 [N_inner×3]，用 vi 索引

        % --- Direct term ---
        % Hermitian: conj(E)*S
        ES = dot(Ev, S_v);  % Hermitian: conj(E)*S
        gd_re = +2 * omega * eps0 * dV_v * imag(ES) / F_obs;

        % --- Indirect term ---
        if use_gi
            EL = dot(Ev, lambda_v);  % Hermitian (conj(λ) applied above for complex eps_r)
            gi_re = -k0^2 * dV_v * real(EL);
        else
            gi_re = 0;
        end

        g_re = gd_re + gi_re;

        if is_complex_eps
            gd_im = -2 * omega * eps0 * dV_v * real(ES) / F_obs;
            if use_gi
                gi_im = -k0^2 * dV_v * imag(EL);  % bilinear: -k₀²·Im[E·λ]
            else
                gi_im = 0;
            end
            g_im = gd_im + gi_im;

            g(v) = g_re + 1j * g_im;
            if nargout >= 2, g_direct(v) = gd_re + 1j * gd_im; end
            if nargout >= 3, g_indirect(v) = gi_re + 1j * gi_im; end
        else
            g(v) = g_re;
            if nargout >= 2, g_direct(v) = gd_re; end
            if nargout >= 3, g_indirect(v) = gi_re; end
        end
    end
end

if is_complex_eps
    fprintf('[compute_gradient] |g_re| mean=%.4e, |g_im| mean=%.4e (gi=%s, gauss=%s)\n', ...
        mean(abs(real(g(inner)))), mean(abs(imag(g(inner)))), string(use_gi), string(use_gauss));
else
    fprintf('[compute_gradient] |g| mean=%.4e, max=%.4e (gi=%s, gauss=%s, Hermitian)\n', ...
        mean(abs(g(inner))), max(abs(g(inner))), string(use_gi), string(use_gauss));
end
end
