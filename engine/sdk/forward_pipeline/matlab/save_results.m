function result = save_results(params)
%SAVE_RESULTS  Save J_obs and V5a check results to .mat and .json files.
%
% Writes the forward-model observation data and V5a consistency check
% metadata to disk for downstream use (R3 baseline inversion, R4
% constrained inversion, R5 evaluation).
%
% .mat file contents (skill.md step 3):
%   J_obs_perp       [N_k x 3 x N_freq]  transverse light-cone components
%   k_dir            [N_k x 3]            Fibonacci sphere directions
%   dOmega           [N_k x 1]            solid angle weights
%   freq_list        [N_freq x 1]         frequency list (Hz)
%   epsilon_r_true   [N_v x 1]            true eps_r distribution
%   phantom_type     char                 phantom type string
%   N_k              scalar               number of directions
%   N_freq           scalar               number of frequencies
%
% .json file contents (metadata):
%   V5a check result (pass/fail + relative error)
%   phantom type, frequencies (GHz), direction count
%   data dimensions and file paths
%   timestamp and description
%
% Standardised parameter interface (R2d can call without modification):
%   params.J_obs_result    - struct from compute_jobs()
%   params.V5a_result      - struct from v5a_check()
%   params.epsilon_r_true  - [N_v x 1]  true eps_r distribution
%   params.phantom_type    - phantom type string ('single_layer', etc.)
%   params.output_mat      - output .mat file path
%   params.output_json     - output .json file path
%
% Output struct:
%   result.status    - 'success' / 'error'
%   result.mat_path  - written .mat file path
%   result.json_path - written .json file path
%   result.error_msg - error message (only when status == 'error')

    try
        %% ---- extract inputs ----
        J_obs = params.J_obs_result;
        V5a   = params.V5a_result;

        if ~isfield(params, 'phantom_type') || isempty(params.phantom_type)
            params.phantom_type = 'single_layer';
        end

        J_obs_perp      = J_obs.J_obs_perp;       % [N_k x 3 x N_freq]
        k_dir           = J_obs.k_dir;            % [N_k x 3]
        dOmega          = J_obs.dOmega;           % [N_k x 1]
        freq_list       = J_obs.freq_list;        % [N_freq x 1]
        epsilon_r_true  = params.epsilon_r_true;  % [N_v x 1]

        N_k    = size(J_obs_perp, 1);
        N_freq = size(J_obs_perp, 3);

        %% ---- write .mat file ----
        % Structured save with all required variables (skill.md step 3)
        save_data = struct();
        save_data.J_obs_perp      = J_obs_perp;
        save_data.k_dir           = k_dir;
        save_data.dOmega          = dOmega;
        save_data.freq_list       = freq_list;
        save_data.epsilon_r_true  = epsilon_r_true;
        save_data.phantom_type    = params.phantom_type;
        save_data.N_k             = N_k;
        save_data.N_freq          = N_freq;
        save_data.N_obs_complex   = N_k * 3 * N_freq;
        save_data.N_obs_real      = 2 * N_k * 3 * N_freq;

        save(params.output_mat, '-struct', 'save_data');

        %% ---- build JSON metadata ----
        % V5a summary
        if strcmp(V5a.status, 'success')
            v5a_summary = struct( ...
                'passed',          V5a.passed, ...
                'rel_error',       V5a.rel_error, ...
                'criterion',       V5a.criterion, ...
                'tol',             V5a.tol);
            if isfield(V5a, 'rel_error_per_freq')
                v5a_summary.rel_error_per_freq = V5a.rel_error_per_freq;
            end
        else
            v5a_summary = struct( ...
                'passed',     false, ...
                'error_msg',  V5a.error_msg);
        end

        % Frequency info (convert to GHz for readability)
        freq_GHz = freq_list(:)' / 1e9;

        meta = struct();
        meta.phantom_type    = params.phantom_type;
        meta.frequencies_GHz = freq_GHz;
        meta.n_directions    = N_k;
        meta.n_freq          = N_freq;
        meta.n_obs_complex   = N_k * 3 * N_freq;
        meta.n_obs_real      = 2 * N_k * 3 * N_freq;
        meta.measurement_R_m = 0.26;
        meta.scatterer_R_m   = 0.13;

        meta.data_dimensions = struct( ...
            'J_obs_perp',     sprintf('[%d x 3 x %d]', N_k, N_freq), ...
            'k_dir',          sprintf('[%d x 3]', N_k), ...
            'dOmega',         sprintf('[%d x 1]', N_k), ...
            'freq_list',      sprintf('[%d x 1]', N_freq), ...
            'epsilon_r_true', sprintf('[%d x 1]', numel(epsilon_r_true)));

        meta.V5a_check = v5a_summary;

        meta.files = struct( ...
            'mat_path',  params.output_mat, ...
            'json_path', params.output_json);

        % Use modern datetime (replaces deprecated datestr/now)
        meta.timestamp   = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
        meta.description = 'Phantom-constrained inverse scattering forward-model observation data';

        %% ---- write JSON file ----
        json_str = jsonencode(meta, 'PrettyPrint', true);
        fid = fopen(params.output_json, 'w');
        if fid < 0
            error('save_results:fileOpen', ...
                'Cannot open JSON file for writing: %s', params.output_json);
        end
        fprintf(fid, '%s', json_str);
        fclose(fid);

        %% ---- assemble result ----
        result.status    = 'success';
        result.mat_path  = params.output_mat;
        result.json_path = params.output_json;
        result.N_k       = N_k;
        result.N_freq    = N_freq;

    catch ME
        result.status    = 'error';
        result.error_msg = ME.message;
        result.mat_path  = '';
        result.json_path = '';
    end
end
