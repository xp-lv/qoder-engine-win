function result = compute_jobs(params)
%COMPUTE_JOBS  J_obs surface equivalent theorem integral.
%
% Computes J_obs(k_hat) for N_k Fibonacci sphere directions using the
% surface equivalent theorem on the measurement sphere (R=0.26 m).
%
% Physics (knowledge doc section 1.2):
%   J_obs(k_hat) = integral_S [
%       (I - k_hat*k_hat) * (n_hat x H^s)            â†?magnetic term (projected)
%     + ( n_hat*(E^s . k_hat) - E^s*(n_hat . k_hat) ) / eta_0  â†?electric term
%   ] * exp(-i*k0*k_hat . r) dS
%
% The transverse projection (I - k_hat*k_hat) is applied explicitly to the
% magnetic term (n_hat x H^s). The electric term is naturally transverse
% (perpendicular to k_hat by construction), so no additional projection
% is needed. A final cleanup projection is applied to the summed result
% to eliminate any residual longitudinal numerical noise.
%
% Each frequency produces N_k x 3 = 192 complex observations.
% Two frequencies (0.8 GHz, 1.0 GHz) total: 384 complex = 768 real.
%
% Standardised parameter interface (R2d can call without modification):
%   params.scatter_field_mat  - scatter field .mat file path (char)
%   params.freq_list          - frequency list [N_freq x 1] (Hz)
%   params.n_directions       - Fibonacci directions count (default 64)
%   params.measurement_R      - measurement sphere radius (default 0.26 m)
%
% Expected .mat file fields (produced by COMSOL export / R2a):
%   r_surface   [N_s x 3]          surface node coordinates on meas. sphere
%   n_hat       [N_s x 3]          outward unit normals
%   dS          [N_s x 1]          surface element areas (m^2)
%   E_s         [N_s x 3 x N_freq] scattered E-field (complex, V/m)
%   H_s         [N_s x 3 x N_freq] scattered H-field (complex, A/m)
%
% Output struct:
%   result.status      - 'success' / 'error'
%   result.J_obs_perp  - [N_k x 3 x N_freq]  transverse components (complex)
%   result.k_dir       - [N_k x 3]            Fibonacci directions (unit)
%   result.dOmega      - [N_k x 1]            solid angle weights
%   result.freq_list   - [N_freq x 1]         frequency list (Hz)
%   result.N_k         - number of directions
%   result.N_freq      - number of frequencies
%   result.N_obs_complex - total complex observations (N_k * 3 * N_freq)
%   result.N_obs_real  - total real observations (2 * N_k * 3 * N_freq)
%   result.error_msg   - error message (only when status == 'error')

    %% ---- physical constants ----
    c_light   = 2.99792458e8;           % speed of light (m/s)
    eta_0     = 376.730313668;          % free-space impedance (Ohm)
    eps_0     = 8.8541878128e-12;       % vacuum permittivity (F/m)

    %% ---- defaults ----
    if ~isfield(params, 'n_directions') || isempty(params.n_directions)
        params.n_directions = 64;
    end
    if ~isfield(params, 'measurement_R') || isempty(params.measurement_R)
        params.measurement_R = 0.26;    % m
    end

    N_k     = params.n_directions;
    R_meas  = params.measurement_R;

    try
        %% ---- load scatter field data from .mat ----
        scatter_data = load(params.scatter_field_mat);

        required = {'r_surface', 'n_hat', 'dS', 'E_s', 'H_s'};
        for idx = 1:numel(required)
            fn = required{idx};
            if ~isfield(scatter_data, fn)
                error('compute_jobs:missingField', ...
                    'Scatter data missing field: %s', fn);
            end
        end

        r_surf = scatter_data.r_surface;       % [N_s x 3]
        n_hat  = scatter_data.n_hat;           % [N_s x 3]
        dS     = scatter_data.dS;              % [N_s x 1]
        E_s    = scatter_data.E_s;             % [N_s x 3 x N_freq]
        H_s    = scatter_data.H_s;             % [N_s x 3 x N_freq]

        N_s = size(r_surf, 1);
        freq_list = params.freq_list(:);
        N_freq    = numel(freq_list);

        % Validate frequency dimension
        if size(E_s, 3) ~= N_freq || size(H_s, 3) ~= N_freq
            error('compute_jobs:freqMismatch', ...
                ['E_s/H_s frequency dim (%d) does not match ' ...
                 'params.freq_list length (%d).'], ...
                size(E_s, 3), N_freq);
        end

        % Validate scatter field data for NaN/Inf
        if any(~isfinite(E_s(:))) || any(~isfinite(H_s(:)))
            error('compute_jobs:nanInf', ...
                'Scatter field data contains NaN or Inf values.');
        end

        %% ---- generate Fibonacci sphere directions ----
        [k_dir, dOmega] = fibonacci_sphere(N_k);   % [N_k x 3], [N_k x 1]

        %% ---- precompute wavenumbers ----
        k0    = 2 * pi * freq_list / c_light;       % [N_freq x 1]
        omega = 2 * pi * freq_list;                  % [N_freq x 1]

        %% ---- allocate output ----
        J_obs_perp = zeros(N_k, 3, N_freq);          % complex

        %% ---- main loop: over directions and frequencies ----
        for ik = 1:N_k
            k_hat = k_dir(ik, :).';                  % [3 x 1]

            % Transverse projection matrix P = I - k_hat * k_hat^T  [3x3]
            % (k_hat is real, so k_hat.' = k_hat')
            P_perp = eye(3) - (k_hat * k_hat.');

            for ifr = 1:N_freq
                % Extract fields for this frequency  [N_s x 3]
                E_f = E_s(:, :, ifr);
                H_f = H_s(:, :, ifr);

                % Phase factor exp(-i * k0 * k_hat . r) for each surface point
                phase = exp(-1i * k0(ifr) * (r_surf * k_hat));   % [N_s x 1]

                % ---- Term 1 (magnetic): P * (n_hat x H^s) ----
                % Cross product n_hat x H^s  [N_s x 3] (complex result)
                nCROSSH = cross_vec(n_hat, H_f);
                % Apply transverse projection to magnetic term only
                % (nCROSSH * P applies P to each row as column vector,
                %  since P is symmetric: row*P = (P*row')')
                term1 = nCROSSH * P_perp;            % [N_s x 3]

                % ---- Term 2 (electric): naturally transverse ----
                % (n_hat*(E^s . k_hat) - E^s*(n_hat . k_hat)) / eta_0
                % This equals k_hat x (n_hat x E^s) / eta_0,
                % which is perpendicular to k_hat by construction.
                E_dot_k = sum(E_f .* k_hat.', 2);    % [N_s x 1] (no conjugate)
                n_dot_k = sum(n_hat .* k_hat.', 2);  % [N_s x 1] (real)
                term2   = (n_hat .* E_dot_k - E_f .* n_dot_k) / eta_0;  % [N_s x 3]

                % ---- Weighted surface integral ----
                % J_obs(k_hat) = sum_n (term1 + term2) .* phase(n) .* dS(n)
                integrand = (term1 + term2) .* (phase .* dS);  % [N_s x 3]
                J_raw = sum(integrand, 1).';                   % [3 x 1]

                % Final cleanup projection (removes residual numerical noise)
                J_obs_perp(ik, :, ifr) = (P_perp * J_raw).';
            end
        end

        % Validate output for NaN/Inf
        if any(~isfinite(J_obs_perp(:)))
            error('compute_jobs:nanInf', ...
                'J_obs contains NaN or Inf values after computation.');
        end

        %% ---- assemble result ----
        result.status        = 'success';
        result.J_obs_perp    = J_obs_perp;   % [N_k x 3 x N_freq]
        result.k_dir         = k_dir;        % [N_k x 3]
        result.dOmega        = dOmega;       % [N_k x 1]
        result.freq_list     = freq_list;    % [N_freq x 1]
        result.N_k           = N_k;
        result.N_freq        = N_freq;
        result.N_obs_complex = N_k * 3 * N_freq;   % 384
        result.N_obs_real    = 2 * N_k * 3 * N_freq; % 768

    catch ME
        result.status     = 'error';
        result.error_msg  = ME.message;
        result.J_obs_perp = [];
        result.k_dir      = [];
        result.dOmega     = [];
        result.freq_list  = [];
    end
end


%% ===================== helper: Fibonacci sphere =====================
function [dirs, dOmega] = fibonacci_sphere(N)
%FIBONACCI_SPHERE  Generate N quasi-uniform directions on unit sphere.
%
% Uses the Fibonacci spiral (golden angle) method to produce N
% quasi-uniformly distributed direction vectors on the unit sphere.
%
% Returns:
%   dirs   [N x 3]  unit direction vectors (k_hat)
%   dOmega [N x 1]  solid angle weight for each direction (sum = 4*pi)

    golden_ratio = (1 + sqrt(5)) / 2;
    ga = 2 * pi * golden_ratio;          % golden angle (~3.883 rad)

    indices = 0:(N-1);

    % Zenith angle theta in (0, pi), symmetric about equator
    theta = acos(1 - 2 * (indices + 0.5) / N);

    % Azimuthal angle (incremented by golden angle each step)
    phi   = ga * indices;

    sin_theta = sin(theta);
    dirs = [sin_theta .* cos(phi), ...
            sin_theta .* sin(phi), ...
            cos(theta)];

    % Uniform solid angle weight (Fibonacci spiral is quasi-uniform)
    dOmega = repmat(4 * pi / N, N, 1);
end


%% ===================== helper: row-wise cross product =====================
function C = cross_vec(A, B)
%CROSS_VEC  Row-wise cross product for [N x 3] matrices.
%   Computes C(i,:) = A(i,:) x B(i,:) for each row i.
%   Works correctly when A is real and B is complex.
    C = [ A(:,2).*B(:,3) - A(:,3).*B(:,2), ...
          A(:,3).*B(:,1) - A(:,1).*B(:,3), ...
          A(:,1).*B(:,2) - A(:,2).*B(:,1) ];
end
