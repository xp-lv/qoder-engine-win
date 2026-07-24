function pipeline_result = run_forward_pipeline(params)
% RUN_FORWARD_PIPELINE  Forward pipeline entry for COMSOL Forward Pipeline SDK.
% =========================================================================
% Role:   SDK-layer forward pipeline orchestrator
% Source: engine/sdk/forward_pipeline/matlab/run_forward_pipeline.m
%
% Adapted from z-workspace/default/scripts/run_forward_pipeline.m to align
% with the Z_workspace compute_jobs / v5a_check / save_results field
% contracts. Stage 1-4 are preserved; Stage 5-7 are rewritten to construct
% the exact fields each downstream function expects.
%
% Flow (serial within one process):
%   1. Parse parameters
%   2. Start COMSOL Server (background + port-ready probe)
%   3. Initialize LiveLink (addpath(mli) + mphstart)
%   4. forward_solve(params)            - COMSOL forward solve
%   5. compute_jobs(params)             - J_obs surface integral
%   6. v5a_check(params)                - V5a consistency check (optional)
%   7. save_results(params)             - persist .mat + .json
%   8. Cleanup COMSOL
%
% Required params fields (passed via params.json by launcher.m):
%   eps_real_csv        - eps_r real-part CSV path
%   eps_imag_csv        - eps_r imag-part CSV path (may be empty)
%   freq_list           - frequency list [Hz], e.g. [0.8e9, 1.0e9]
%   model_path          - .mph file path
%   output_path         - scatter field .mat path (forward_solve output)
%   mat_path            - J_obs_data.mat path (save_results output)
%   json_path           - metadata .json path (save_results output)
%   comsol_server_path  - comsolmphserver.exe path
%   mli_path            - LiveLink API dir
%
% Optional params fields:
%   comsol_port         - default 2036
%   comsol_startup_timeout - default 240
%   measurement_R       - default 0.26
%   n_directions        - default 64
%   timeout_minutes     - default 30 (per-solve, COMSOL-side)
%   run_v5a             - default true (skip V5a check if false)
%   tol                 - default 0.05 (5%)
%   phantom_type        - default 'single_layer'
%
% Return:
%   pipeline_result.status    - 'success' / 'error'
%   pipeline_result.stage     - stage tag on failure
%   pipeline_result.error_msg - error detail
%   pipeline_result.mat_path  - J_obs .mat path (on success)
%   pipeline_result.json_path - metadata .json path (on success)
% =========================================================================

    pipeline_result = struct( ...
        'status', '', 'stage', '', 'error_msg', '', ...
        'mat_path', '', 'json_path', '');

    comsol_server_started = false;
    livelink_connected = false;
    volume_mat_path = '';   % temp file created for v5a_check, deleted on cleanup

    try
        % ============================================================
        % Stage 1: Parse parameters
        % ============================================================
        fprintf('[pipeline] Stage 1: parsing parameters\n');
        params = apply_defaults(params);
        params = build_voxel_data(params);

        fprintf('[pipeline] Parameters parsed: %d freqs, %d dirs, port %d\n', ...
            numel(params.freq_list), params.n_directions, params.comsol_port);

        % ============================================================
        % Stage 2: Start COMSOL Server (or detect existing one)
        % ============================================================
        fprintf('[pipeline] Stage 2: starting COMSOL Server (port %d)\n', params.comsol_port);

        port_in_use = check_port_in_use(params.comsol_port);
        if port_in_use
            fprintf('[pipeline][INFO] Port %d already in use; assuming external COMSOL Server\n', ...
                params.comsol_port);
        else
            [comsol_server_started, start_msg] = start_comsol_server( ...
                params.comsol_server_path, params.comsol_port);
            if ~comsol_server_started
                fprintf('[pipeline][WARN] COMSOL Server start: %s\n', start_msg);
            else
                fprintf('[pipeline] Waiting for port ready (timeout %d s)...\n', ...
                    params.comsol_startup_timeout);
                ready = wait_for_port_ready(params.comsol_port, params.comsol_startup_timeout);
                if ~ready
                    pipeline_result.status = 'error';
                    pipeline_result.stage = 'comsol_server';
                    pipeline_result.error_msg = sprintf( ...
                        'COMSOL Server port %d not ready within %d s', ...
                        params.comsol_port, params.comsol_startup_timeout);
                    cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
                    return;
                end
                fprintf('[pipeline] COMSOL Server port %d ready\n', params.comsol_port);
            end
        end

        % ============================================================
        % Stage 3: Initialize LiveLink
        % ============================================================
        fprintf('[pipeline] Stage 3: initializing LiveLink\n');
        try
            if exist(params.mli_path, 'dir')
                addpath(params.mli_path);
                fprintf('[pipeline] Added LiveLink API path: %s\n', params.mli_path);
            else
                fprintf('[pipeline][WARN] LiveLink path not found: %s\n', params.mli_path);
            end
            import com.comsol.model.*
            import com.comsol.model.util.*
            mphstart(params.comsol_port);
            livelink_connected = true;
            fprintf('[pipeline] LiveLink connected (port %d)\n', params.comsol_port);
        catch ME
            pipeline_result.status = 'error';
            pipeline_result.stage = 'comsol_init';
            pipeline_result.error_msg = sprintf('LiveLink init failed: %s', ME.message);
            cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
            return;
        end

        % ============================================================
        % Stage 4: forward_solve - COMSOL forward solve
        % ============================================================
        fprintf('[pipeline] Stage 4: forward_solve\n');
        try
            if isfield(params, 'voxel_positions')
                params.voxel_pos = params.voxel_positions;
            end
            result_forward = forward_solve(params);
        catch ME
            result_forward = struct('status', 'error', 'error_msg', ME.message);
        end

        if ~isfield(result_forward, 'status') || ~strcmp(result_forward.status, 'success')
            pipeline_result.status = 'error';
            pipeline_result.stage = 'forward';
            err_msg = '';
            if isfield(result_forward, 'error_msg'), err_msg = result_forward.error_msg; end
            pipeline_result.error_msg = sprintf('forward_solve failed: %s', err_msg);
            cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
            return;
        end
        fprintf('[pipeline] forward_solve succeeded\n');

        % ============================================================
        % Stage 5: compute_jobs - J_obs surface integral
        %   (Z_workspace contract: scatter_field_mat, freq_list,
        %    n_directions, measurement_R)
        % ============================================================
        fprintf('[pipeline] Stage 5: compute_jobs\n');
        params_compute = struct();
        params_compute.scatter_field_mat = params.output_path;
        params_compute.freq_list         = params.freq_list;
        params_compute.n_directions      = params.n_directions;
        params_compute.measurement_R     = params.measurement_R;

        try
            result_compute = compute_jobs(params_compute);
        catch ME
            result_compute = struct('status', 'error', 'error_msg', ME.message);
        end

        if ~isfield(result_compute, 'status') || ~strcmp(result_compute.status, 'success')
            pipeline_result.status = 'error';
            pipeline_result.stage = 'compute';
            err_msg = '';
            if isfield(result_compute, 'error_msg'), err_msg = result_compute.error_msg; end
            pipeline_result.error_msg = sprintf('compute_jobs failed: %s', err_msg);
            cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
            return;
        end
        fprintf('[pipeline] compute_jobs succeeded (N_obs_complex=%d)\n', ...
            result_compute.N_obs_complex);

        % ============================================================
        % Stage 6: v5a_check (optional)
        %   (Z_workspace contract: J_obs struct, volume_mat .mat path, tol)
        %   volume_mat .mat must contain: r_voxel, dV, eps_r_true, E_total
        % ============================================================
        if params.run_v5a
            fprintf('[pipeline] Stage 6: v5a_check (tol=%.3f)\n', params.tol);

            % Build volume_mat .mat file for v5a_check
            vol_data = struct();
            if isfield(params, 'voxel_positions')
                vol_data.r_voxel = params.voxel_positions;
            else
                vol_data.r_voxel = [];
            end
            if isfield(params, 'voxel_volumes') && ~isempty(params.voxel_volumes)
                vol_data.dV = params.voxel_volumes;
            else
                % Fallback: unit volume per voxel
                vol_data.dV = ones(numel(params.epsilon_r_true), 1) * 1e-6;
            end
            vol_data.eps_r_true = params.epsilon_r_true;

            % Extract E_total from forward result
            % forward_solve returns result.scattered_field.E_total_voxel [N_v x 3 x N_freq]
            if isfield(result_forward, 'scattered_field') && ...
               isfield(result_forward.scattered_field, 'E_total_voxel') && ...
               ~isempty(result_forward.scattered_field.E_total_voxel)
                vol_data.E_total = result_forward.scattered_field.E_total_voxel;
            elseif isfield(params, 'E_total') && ~isempty(params.E_total)
                vol_data.E_total = params.E_total;
            else
                pipeline_result.status = 'error';
                pipeline_result.stage = 'v5a_no_E_total';
                pipeline_result.error_msg = 'E_total_voxel not available from forward_solve';
                cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
                return;
            end

            % Write volume_mat temp file
            volume_mat_path = fullfile(fileparts(params.mat_path), '.volume_data_temp.mat');
            try
                save(volume_mat_path, '-struct', 'vol_data');
            catch ME
                pipeline_result.status = 'error';
                pipeline_result.stage = 'v5a_vol_save';
                pipeline_result.error_msg = sprintf('Failed to write volume_mat: %s', ME.message);
                cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
                return;
            end

            % Build v5a_check params
            params_v5a = struct();
            params_v5a.J_obs      = result_compute;   % compute_jobs result is the J_obs struct
            params_v5a.volume_mat = volume_mat_path;
            params_v5a.tol        = params.tol;

            try
                result_v5a = v5a_check(params_v5a);
            catch ME
                result_v5a = struct('status', 'error', 'error_msg', ME.message);
            end

            if ~isfield(result_v5a, 'status') || ~strcmp(result_v5a.status, 'success')
                pipeline_result.status = 'error';
                pipeline_result.stage = 'v5a';
                err_msg = '';
                if isfield(result_v5a, 'error_msg'), err_msg = result_v5a.error_msg; end
                pipeline_result.error_msg = sprintf('v5a_check failed: %s', err_msg);
                cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
                return;
            end

            if isfield(result_v5a, 'passed') && result_v5a.passed
                fprintf('[pipeline] v5a_check PASSED (rel_error=%.4f%%)\n', ...
                    result_v5a.rel_error * 100);
            else
                fprintf('[pipeline][WARN] v5a_check FAILED (rel_error=%.4f%%, tol=%.4f%%)\n', ...
                    result_v5a.rel_error * 100, params.tol * 100);
                % Note: V5a failure is recorded in metadata but does NOT abort the pipeline.
                % Downstream consumers (inverse scattering) can decide whether to use the data.
            end
        else
            fprintf('[pipeline] Stage 6: v5a_check SKIPPED (run_v5a=false)\n');
            result_v5a = struct( ...
                'status', 'skipped', ...
                'passed', false, ...
                'rel_error', NaN, ...
                'criterion', 'skipped', ...
                'tol', params.tol);
        end

        % ============================================================
        % Stage 7: save_results
        %   (Z_workspace contract: J_obs_result, V5a_result,
        %    epsilon_r_true, phantom_type, output_mat, output_json)
        % ============================================================
        fprintf('[pipeline] Stage 7: save_results\n');
        params_save = struct();
        params_save.J_obs_result   = result_compute;
        params_save.V5a_result     = result_v5a;
        params_save.epsilon_r_true = params.epsilon_r_true;
        params_save.phantom_type   = params.phantom_type;
        params_save.output_mat     = params.mat_path;
        params_save.output_json    = params.json_path;

        try
            result_save = save_results(params_save);
        catch ME
            result_save = struct('status', 'error', 'error_msg', ME.message);
        end

        if ~isfield(result_save, 'status') || ~strcmp(result_save.status, 'success')
            pipeline_result.status = 'error';
            pipeline_result.stage = 'save';
            err_msg = '';
            if isfield(result_save, 'error_msg'), err_msg = result_save.error_msg; end
            pipeline_result.error_msg = sprintf('save_results failed: %s', err_msg);
            cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
            return;
        end

        % Write a small v5a_result.json for cache verification (Python reads this)
        try
            v5a_json_path = fullfile(fileparts(params.mat_path), 'v5a_result.json');
            v5a_summary = struct();
            if isfield(result_v5a, 'passed')
                v5a_summary.passed = result_v5a.passed;
            end
            if isfield(result_v5a, 'rel_error')
                v5a_summary.rel_error = result_v5a.rel_error;
            end
            if isfield(result_v5a, 'status')
                v5a_summary.status = result_v5a.status;
            end
            v5a_summary.tol = params.tol;
            fid = fopen(v5a_json_path, 'w');
            if fid > 0
                fprintf(fid, '%s', jsonencode(v5a_summary));
                fclose(fid);
            end
        catch
            % Non-fatal
        end

        % ============================================================
        % Stage 8: Cleanup
        % ============================================================
        cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);

        pipeline_result.status    = 'success';
        pipeline_result.stage     = 'done';
        pipeline_result.error_msg = '';
        pipeline_result.mat_path  = params.mat_path;
        pipeline_result.json_path = params.json_path;
        fprintf('[pipeline] Forward pipeline completed successfully\n');
        fprintf('[pipeline]   mat:  %s\n', params.mat_path);
        fprintf('[pipeline]   json: %s\n', params.json_path);

    catch ME
        pipeline_result.status = 'error';
        if isempty(pipeline_result.stage)
            pipeline_result.stage = 'unknown';
        end
        pipeline_result.error_msg = sprintf('Pipeline exception: %s', ME.message);
        fprintf('[pipeline][ERROR] %s\n', pipeline_result.error_msg);
        st = '';
        for ii = 1:numel(ME.stack)
            st = sprintf('%s\n    %s (line %d)', st, ME.stack(ii).name, ME.stack(ii).line);
        end
        fprintf('[pipeline][ERROR] stack:%s\n', st);
        cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path);
    end
end


% =========================================================================
% Subfunction: apply_defaults
% =========================================================================
function params = apply_defaults(params)
    if ~isfield(params, 'comsol_port') || isempty(params.comsol_port)
        params.comsol_port = 2036;
    end
    if ~isfield(params, 'comsol_startup_timeout') || isempty(params.comsol_startup_timeout)
        params.comsol_startup_timeout = 240;
    end
    if ~isfield(params, 'measurement_R') || isempty(params.measurement_R)
        params.measurement_R = 0.26;
    end
    if ~isfield(params, 'n_directions') || isempty(params.n_directions)
        params.n_directions = 64;
    end
    if ~isfield(params, 'timeout_minutes') || isempty(params.timeout_minutes)
        params.timeout_minutes = 30;
    end
    if ~isfield(params, 'run_v5a') || isempty(params.run_v5a)
        params.run_v5a = true;
    end
    if ~isfield(params, 'tol') || isempty(params.tol)
        params.tol = 0.05;
    end
    if ~isfield(params, 'phantom_type') || isempty(params.phantom_type)
        params.phantom_type = 'single_layer';
    end
    if ~isfield(params, 'freq_list') || isempty(params.freq_list)
        params.freq_list = [0.8e9, 1.0e9];
    end

    % Ensure output paths
    if ~isfield(params, 'mat_path') || isempty(params.mat_path)
        out_dir = fileparts(params.output_path);
        params.mat_path = fullfile(out_dir, 'J_obs_data.mat');
    end
    if ~isfield(params, 'json_path') || isempty(params.json_path)
        out_dir = fileparts(params.output_path);
        params.json_path = fullfile(out_dir, 'forward_dataset.json');
    end
end


% =========================================================================
% Subfunction: build_voxel_data
%   Reads eps_real.csv to extract voxel_positions, epsilon_r_true,
%   voxel_volumes. forward_solve also reads the CSV internally for COMSOL
%   model loading; this is the post-processing copy used by v5a_check.
% =========================================================================
function params = build_voxel_data(params)
    csv_path = '';
    if isfield(params, 'eps_real_csv') && ~isempty(params.eps_real_csv)
        csv_path = params.eps_real_csv;
    end

    if isempty(csv_path) || ~exist(csv_path, 'file')
        return;
    end

    try
        fprintf('[pipeline] Building voxel data from %s\n', csv_path);
        data = readmatrix(csv_path);
        if size(data, 2) >= 4 && any(~isfinite(data(1, :)))
            data = readmatrix(csv_path, 'NumHeaderLines', 1);
        end

        params.voxel_positions = data(:, 1:3);
        params.epsilon_r_true  = data(:, 4);
        n_vox = size(data, 1);
        fprintf('[pipeline] Voxel data: %d voxels, eps_r range [%.1f, %.1f]\n', ...
            n_vox, min(params.epsilon_r_true), max(params.epsilon_r_true));

        if n_vox >= 2
            diffs = sort(sqrt(sum((data(2:min(n_vox, 100), 1:3) - ...
                data(1:min(n_vox-1, 99), 1:3)).^2, 2)));
            h = diffs(max(1, floor(numel(diffs) * 0.1)));
            params.voxel_volumes = h^3 * ones(n_vox, 1);
        end
    catch ME
        fprintf('[pipeline][WARN] Voxel data build failed: %s\n', ME.message);
    end
end


% =========================================================================
% Subfunction: check_port_in_use
% =========================================================================
function in_use = check_port_in_use(port)
    in_use = false;
    try
        sock = java.net.Socket();
        sock_addr = java.net.InetSocketAddress('127.0.0.1', port);
        sock.connect(sock_addr, 2000);
        sock.close();
        in_use = true;
    catch
        in_use = false;
    end
end


% =========================================================================
% Subfunction: wait_for_port_ready
% =========================================================================
function ready = wait_for_port_ready(port, timeout_sec)
    ready = false;
    t_start = tic;
    poll_interval = 3;
    while toc(t_start) < timeout_sec
        if check_port_in_use(port)
            ready = true;
            pause(2);
            return;
        end
        pause(poll_interval);
    end
end


% =========================================================================
% Subfunction: start_comsol_server
% =========================================================================
function [started, msg] = start_comsol_server(server_path, port)
    started = false;
    msg = '';

    if ~exist(server_path, 'file')
        msg = sprintf('COMSOL Server executable not found: %s', server_path);
        fprintf('[pipeline][WARN] %s\n', msg);
        return;
    end

    if ispc
        cmd = sprintf('start /B "" "%s" -port %d', server_path, port);
    else
        cmd = sprintf('"%s" -port %d > /dev/null 2>&1 &', server_path, port);
    end
    fprintf('[pipeline] Start command: %s\n', cmd);

    try
        [status, ~] = system(cmd);
        if status == 0
            started = true;
            msg = 'COMSOL Server start command issued';
        else
            msg = sprintf('COMSOL Server start returned non-zero: %d', status);
        end
    catch ME
        msg = sprintf('Failed to start COMSOL Server: %s', ME.message);
    end
end


% =========================================================================
% Subfunction: cleanup_all
%   Cleans up LiveLink + COMSOL Server + temp volume_mat file.
% =========================================================================
function cleanup_all(livelink_connected, comsol_server_started, params, volume_mat_path)
    if livelink_connected
        try
            import com.comsol.model.util.*
            ModelUtil.disconnect;
            fprintf('[pipeline] LiveLink disconnected\n');
        catch ME1
            try
                mphexit;
                fprintf('[pipeline] LiveLink disconnected (mphexit)\n');
            catch
                % ignore
            end
        end
    end

    if comsol_server_started
        try
            fprintf('[pipeline] Terminating COMSOL Server\n');
            if ispc
                system('taskkill /F /IM comsolmphserver.exe >nul 2>&1');
            else
                system('pkill -f comsolmphserver 2>/dev/null');
            end
        catch
            % ignore
        end
    end

    % Remove temp volume_mat file
    if ~isempty(volume_mat_path) && exist(volume_mat_path, 'file')
        try
            delete(volume_mat_path);
        catch
            % ignore
        end
    end
end
