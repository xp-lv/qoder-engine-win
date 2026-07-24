function result = v5a_check(params)
%V5A_CHECK  V5a consistency check via Born FT forward pipeline.
%
% Verifies the Born FT forward pipeline by comparing J_hyp(eps_r_true)
% (computed from the volume equivalent source + Born Fourier transform)
% against J_obs (computed from COMSOL native scattered fields via the
% surface equivalent theorem).
%
% Pass criterion (knowledge doc section 3.3, config section 6.4):
%   |J_hyp(eps_r_true) - J_obs| / |J_obs|  <  5%
%
% This is a MANDATORY pre-gate: if V5a fails, the forward data is invalid
% and the cause must be investigated (COMSOL mesh resolution, Born FT
% interpolation accuracy, transverse projection implementation).
%
% Volume equivalent source (Born approximation, knowledge doc section 2.1):
%   J_equi(r)  = -i*omega*eps_0*(eps_r(r) - 1) * E_total(r)
%
% Born Fourier transform + transverse projection (knowledge doc section 2.2):
%   J_hyp(k_hat) = (I - k_hat*k_hat) * sum_v J_equi(r_v)*dV_v*exp(-i*k0*k_hat.r_v)
%
% Standardised parameter interface (R2d can call without modification):
%   params.J_obs          - struct from compute_jobs()
%     .J_obs_perp         - [N_k x 3 x N_freq]  observed transverse J_obs
%     .k_dir              - [N_k x 3]            Fibonacci directions
%     .dOmega             - [N_k x 1]            solid angle weights
%     .freq_list          - [N_freq x 1]         frequency list (Hz)
%   params.volume_mat     - .mat file path with volume field data
%     .r_voxel            - [N_v x 3]   voxel centres (m)
%     .dV                 - [N_v x 1]   voxel volumes (m^3)
%     .eps_r_true         - [N_v x 1]   true eps_r distribution
%     .E_total            - [N_v x 3 x N_freq]  total field from COMSOL
%   params.tol            - relative error tolerance (default 0.05 = 5%)
%
% Output struct:
%   result.status         - 'success' / 'error'
%   result.passed         - true / false
%   result.rel_error      - overall relative error (scalar)
%   result.rel_error_per_freq  - [N_freq x 1] per-frequency relative error
%   result.J_hyp_perp     - [N_k x 3 x N_freq]  hypothetical transverse J
%   result.tol            - tolerance used
%   result.criterion      - pass criterion string
%   result.error_msg      - error message (when status == 'error')

    %% ---- physical constants ----
    c_light = 2.99792458e8;            % speed of light (m/s)
    eps_0   = 8.8541878128e-12;        % vacuum permittivity (F/m)

    %% ---- default tolerance ----
    if ~isfield(params, 'tol') || isempty(params.tol)
        params.tol = 0.05;             % 5%
    end
    tol = params.tol;

    try
        %% ---- extract J_obs ----
        J_obs = params.J_obs;
        J_obs_perp = J_obs.J_obs_perp;        % [N_k x 3 x N_freq]
        k_dir      = J_obs.k_dir;             % [N_k x 3]
        dOmega     = J_obs.dOmega;            % [N_k x 1]
        freq_list  = J_obs.freq_list;         % [N_freq x 1]

        N_k    = size(J_obs_perp, 1);
        N_freq = size(J_obs_perp, 3);

        %% ---- load volume data ----
        vol_data = load(params.volume_mat);

        required = {'r_voxel', 'dV', 'eps_r_true', 'E_total'};
        for idx = 1:numel(required)
            fn = required{idx};
            if ~isfield(vol_data, fn)
                error('v5a_check:missingField', ...
                    'Volume data missing field: %s', fn);
            end
        end

        r_voxel    = vol_data.r_voxel;       % [N_v x 3]
        dV         = vol_data.dV;            % [N_v x 1]
        eps_r_true = vol_data.eps_r_true;    % [N_v x 1]
        E_total    = vol_data.E_total;       % [N_v x 3 x N_freq]

        N_v = size(r_voxel, 1);

        % Validate frequency dimension
        if size(E_total, 3) ~= N_freq
            error('v5a_check:freqMismatch', ...
                'E_total frequency dim (%d) != J_obs N_freq (%d).', ...
                size(E_total, 3), N_freq);
        end

        % Validate data for NaN/Inf
        if any(~isfinite(E_total(:)))
            error('v5a_check:nanInf', ...
                'E_total contains NaN or Inf values.');
        end
        if any(~isfinite(eps_r_true(:)))
            error('v5a_check:nanInf', ...
                'eps_r_true contains NaN or Inf values.');
        end

        %% ---- precompute ----
        k0    = 2 * pi * freq_list(:) / c_light;     % [N_freq x 1]
        omega = 2 * pi * freq_list(:);                % [N_freq x 1]

        % Mask: interior voxels (eps_r > 1) contribute to J_equi
        mask_interior = (eps_r_true > 1);             % [N_v x 1] logical

        %% ---- compute J_hyp for each frequency ----
        J_hyp_perp = zeros(N_k, 3, N_freq);           % complex

        for ifr = 1:N_freq
            % Volume equivalent source (knowledge doc section 2.1):
            %   J_equi(r) = -i*omega*eps_0*(eps_r(r) - 1)*E_total(r)
            contrast = (eps_r_true - 1);              % [N_v x 1]
            E_f      = E_total(:, :, ifr);            % [N_v x 3]

            % J_equi  [N_v x 3]
            J_equi = -1i * omega(ifr) * eps_0 * (contrast .* E_f);

            % Zero-out exterior voxels explicitly for numerical safety
            % (contrast = 0 there, but this enforces the mask)
            J_equi(~mask_interior, :) = 0;

            % Weighted source: J_equi .* dV  [N_v x 3]
            J_weighted = J_equi .* dV;

            % Born FT for each direction k_hat:
            %   J_hyp(k_hat) = (I-k_hat*k_hat) * sum_v J_w(v)*exp(-i*k0*k_hat.r_v)
            for ik = 1:N_k
                k_hat = k_dir(ik, :).';              % [3 x 1]

                % Phase factor for all voxels
                phase = exp(-1i * k0(ifr) * (r_voxel * k_hat));  % [N_v x 1]

                % Weighted sum over voxels (Born FT)
                J_raw = sum(J_weighted .* phase, 1).';  % [3 x 1]

                % Transverse projection P = I - k_hat*k_hat^T
                P_perp = eye(3) - (k_hat * k_hat.');
                J_perp = P_perp * J_raw;            % [3 x 1]

                J_hyp_perp(ik, :, ifr) = J_perp.';
            end
        end

        % Validate J_hyp for NaN/Inf
        if any(~isfinite(J_hyp_perp(:)))
            error('v5a_check:nanInf', ...
                'J_hyp contains NaN or Inf values after computation.');
        end

        %% ---- compute relative error ----
        % Overall:  |J_hyp - J_obs| / |J_obs|
        % (Frobenius norm over all elements)
        diff      = J_hyp_perp - J_obs_perp;
        norm_diff = sqrt(sum(abs(diff(:)).^2));
        norm_obs  = sqrt(sum(abs(J_obs_perp(:)).^2));

        if norm_obs == 0
            error('v5a_check:zeroNorm', ...
                'J_obs norm is zero; cannot compute relative error.');
        end

        rel_error = norm_diff / norm_obs;

        % Per-frequency relative error
        rel_error_per_freq = zeros(N_freq, 1);
        for ifr = 1:N_freq
            d_f  = diff(:, :, ifr);
            o_f  = J_obs_perp(:, :, ifr);
            rel_error_per_freq(ifr) = sqrt(sum(abs(d_f(:)).^2)) / ...
                                       sqrt(sum(abs(o_f(:)).^2));
        end

        %% ---- pass/fail ----
        passed = rel_error < tol;

        %% ---- assemble result ----
        result.status              = 'success';
        result.passed              = passed;
        result.rel_error           = rel_error;
        result.rel_error_per_freq  = rel_error_per_freq;
        result.J_hyp_perp          = J_hyp_perp;
        result.tol                 = tol;
        result.criterion           = '|J_hyp(eps_r_true) - J_obs| / |J_obs| < 5%';
        result.N_k                 = N_k;
        result.N_freq              = N_freq;
        result.N_voxel_interior    = sum(mask_interior);

    catch ME
        result.status     = 'error';
        result.passed     = false;
        result.error_msg  = ME.message;
        result.rel_error  = NaN;
        result.J_hyp_perp = [];
    end
end
