function pipeline_result = run_adjoint_pipeline(params)
% RUN_ADJOINT_PIPELINE  Adjoint pipeline entry for COMSOL Forward Pipeline SDK.
% =========================================================================
% Role:   SDK-layer adjoint pipeline orchestrator
% Source: engine/sdk/forward_pipeline/matlab/run_adjoint_pipeline.m
%
% Flow (serial):
%   1. Parse parameters
%   2. Connect LiveLink + load model
%   3. Load f_adj + voxel data from .mat files
%   4. adjoint_solve(params)             - reuse forward LU factorization
%   5. Save adjoint_field.mat
%   6. Cleanup
%
% Required params fields:
%   forward_mat_path        - .mat with forward result (provides LU factor)
%                              OR model_path .mph for cold-start
%   f_adj_mat_path           - .mat with f_adj [n_voxel x 3] complex
%   voxel_positions_mat_path - .mat with r_voxel [n_voxel x 3]
%   freq_list                - [Hz]
%   model_path               - .mph file path
%   output_path              - adjoint_field.mat output path
%
% Optional params:
%   comsol_port              - default 2036
%   comsol_server_path       - comsolmphserver.exe
%   mli_path                 - LiveLink API dir
%   comsol_startup_timeout   - default 240
%   timeout_minutes          - default 30
%
% Return:
%   pipeline_result.status       - 'success' / 'error'
%   pipeline_result.stage        - failure stage tag
%   pipeline_result.error_msg    - error detail
%   pipeline_result.adjoint_mat  - output .mat path
% =========================================================================

    pipeline_result = struct( ...
        'status', '', 'stage', '', 'error_msg', '', ...
        'adjoint_mat', '');

    comsol_server_started = false;
    livelink_connected = false;

    try
        % ============================================================
        % Stage 1: Parse parameters
        % ============================================================
        fprintf('[adjoint] Stage 1: parsing parameters\n');
        params = apply_adjoint_defaults(params);

        % Required fields
        required = {'f_adj_mat_path', 'voxel_positions_mat_path', 'freq_list', 'model_path', 'output_path'};
        for i = 1:numel(required)
            f = required{i};
            if ~isfield(params, f) || isempty(params.(f))
                pipeline_result.status = 'error';
                pipeline_result.stage = 'param_check';
                pipeline_result.error_msg = sprintf('Missing required parameter: %s', f);
                return;
            end
        end

        fprintf('[adjoint] Parameters: %d freqs, port %d\n', ...
            numel(params.freq_list), params.comsol_port);

        % ============================================================
        % Stage 2: COMSOL Server + LiveLink
        % ============================================================
        fprintf('[adjoint] Stage 2: starting COMSOL Server\n');

        port_in_use = check_port_in_use(params.comsol_port);
        if port_in_use
            fprintf('[adjoint][INFO] Port %d already in use; assuming external Server\n', ...
                params.comsol_port);
        else
            [comsol_server_started, start_msg] = start_comsol_server( ...
                params.comsol_server_path, params.comsol_port);
            if ~comsol_server_started
                fprintf('[adjoint][WARN] %s\n', start_msg);
            else
                ready = wait_for_port_ready(params.comsol_port, params.comsol_startup_timeout);
                if ~ready
                    pipeline_result.status = 'error';
                    pipeline_result.stage = 'comsol_server';
                    pipeline_result.error_msg = sprintf('Port %d not ready within %d s', ...
                        params.comsol_port, params.comsol_startup_timeout);
                    cleanup_adjoint(livelink_connected, comsol_server_started);
                    return;
                end
            end
        end

        try
            if exist(params.mli_path, 'dir')
                addpath(params.mli_path);
            end
            import com.comsol.model.*
            import com.comsol.model.util.*
            mphstart(params.comsol_port);
            livelink_connected = true;
            fprintf('[adjoint] LiveLink connected\n');
        catch ME
            pipeline_result.status = 'error';
            pipeline_result.stage = 'comsol_init';
            pipeline_result.error_msg = sprintf('LiveLink init failed: %s', ME.message);
            cleanup_adjoint(livelink_connected, comsol_server_started);
            return;
        end

        % ============================================================
        % Stage 3: Load f_adj + voxel data
        % ============================================================
        fprintf('[adjoint] Stage 3: loading f_adj + voxel data\n');
        try
            f_adj_data = load(params.f_adj_mat_path);
            if ~isfield(f_adj_data, 'f_adj')
                error('run_adjoint_pipeline:missingFadj', ...
                    'f_adj_mat_path must contain variable "f_adj"');
            end
            params.f_adj = f_adj_data.f_adj;

            vox_data = load(params.voxel_positions_mat_path);
            if isfield(vox_data, 'r_voxel')
                params.voxel_positions = vox_data.r_voxel;
            elseif isfield(vox_data, 'voxel_positions')
                params.voxel_positions = vox_data.voxel_positions;
            else
                error('run_adjoint_pipeline:missingVoxels', ...
                    'voxel_positions_mat_path must contain r_voxel or voxel_positions');
            end
        catch ME
            pipeline_result.status = 'error';
            pipeline_result.stage = 'load_data';
            pipeline_result.error_msg = sprintf('Data load failed: %s', ME.message);
            cleanup_adjoint(livelink_connected, comsol_server_started);
            return;
        end

        % ============================================================
        % Stage 4: adjoint_solve
        % ============================================================
        fprintf('[adjoint] Stage 4: adjoint_solve\n');

        % Pass model_path; adjoint_solve will load it via mphload.
        % If forward_mat_path contains a saved model state, it can be
        % loaded externally and passed as params.model — not supported here
        % in v1 (cold-start from .mph only).
        params.model = [];   % force adjoint_solve to load from model_path

        try
            result_adjoint = adjoint_solve(params);
        catch ME
            result_adjoint = struct('status', 'error', 'error_msg', ME.message);
        end

        if ~isfield(result_adjoint, 'status') || ~strcmp(result_adjoint.status, 'success')
            pipeline_result.status = 'error';
            pipeline_result.stage = 'adjoint';
            err_msg = '';
            if isfield(result_adjoint, 'error_msg'), err_msg = result_adjoint.error_msg; end
            pipeline_result.error_msg = sprintf('adjoint_solve failed: %s', err_msg);
            cleanup_adjoint(livelink_connected, comsol_server_started);
            return;
        end
        fprintf('[adjoint] adjoint_solve succeeded\n');

        % ============================================================
        % Stage 5: Save adjoint_field.mat
        % ============================================================
        fprintf('[adjoint] Stage 5: saving adjoint_field.mat\n');
        try
            save_data = struct();
            save_data.adjoint_field = result_adjoint.adjoint_field;
            save_data.freq_list     = params.freq_list;
            if isfield(result_adjoint, 'metadata')
                save_data.metadata = result_adjoint.metadata;
            end
            save(params.output_path, '-struct', 'save_data', '-v7.3');
        catch ME
            pipeline_result.status = 'error';
            pipeline_result.stage = 'save';
            pipeline_result.error_msg = sprintf('Save failed: %s', ME.message);
            cleanup_adjoint(livelink_connected, comsol_server_started);
            return;
        end

        % ============================================================
        % Stage 6: Cleanup
        % ============================================================
        cleanup_adjoint(livelink_connected, comsol_server_started);

        pipeline_result.status      = 'success';
        pipeline_result.stage       = 'done';
        pipeline_result.error_msg   = '';
        pipeline_result.adjoint_mat = params.output_path;
        fprintf('[adjoint] Pipeline completed successfully\n');
        fprintf('[adjoint]   mat: %s\n', params.output_path);

    catch ME
        pipeline_result.status = 'error';
        if isempty(pipeline_result.stage)
            pipeline_result.stage = 'unknown';
        end
        pipeline_result.error_msg = sprintf('Pipeline exception: %s', ME.message);
        fprintf('[adjoint][ERROR] %s\n', pipeline_result.error_msg);
        st = '';
        for ii = 1:numel(ME.stack)
            st = sprintf('%s\n    %s (line %d)', st, ME.stack(ii).name, ME.stack(ii).line);
        end
        fprintf('[adjoint][ERROR] stack:%s\n', st);
        cleanup_adjoint(livelink_connected, comsol_server_started);
    end
end


% =========================================================================
% Subfunction: apply_adjoint_defaults
% =========================================================================
function params = apply_adjoint_defaults(params)
    if ~isfield(params, 'comsol_port') || isempty(params.comsol_port)
        params.comsol_port = 2036;
    end
    if ~isfield(params, 'comsol_server_path') || isempty(params.comsol_server_path)
        params.comsol_server_path = 'C:\Program Files\COMSOL\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe';
    end
    if ~isfield(params, 'mli_path') || isempty(params.mli_path)
        params.mli_path = 'C:\Program Files\COMSOL\COMSOL62\Multiphysics\mli';
    end
    if ~isfield(params, 'comsol_startup_timeout') || isempty(params.comsol_startup_timeout)
        params.comsol_startup_timeout = 240;
    end
    if ~isfield(params, 'timeout_minutes') || isempty(params.timeout_minutes)
        params.timeout_minutes = 30;
    end
    if ~isfield(params, 'livelink_port') || isempty(params.livelink_port)
        params.livelink_port = params.comsol_port;
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
    while toc(t_start) < timeout_sec
        if check_port_in_use(port)
            ready = true;
            pause(2);
            return;
        end
        pause(3);
    end
end


% =========================================================================
% Subfunction: start_comsol_server
% =========================================================================
function [started, msg] = start_comsol_server(server_path, port)
    started = false;
    msg = '';
    if ~exist(server_path, 'file')
        msg = sprintf('COMSOL Server not found: %s', server_path);
        return;
    end
    if ispc
        cmd = sprintf('start /B "" "%s" -port %d', server_path, port);
    else
        cmd = sprintf('"%s" -port %d > /dev/null 2>&1 &', server_path, port);
    end
    try
        [status, ~] = system(cmd);
        if status == 0
            started = true;
        else
            msg = sprintf('start returned %d', status);
        end
    catch ME
        msg = ME.message;
    end
end


% =========================================================================
% Subfunction: cleanup_adjoint
% =========================================================================
function cleanup_adjoint(livelink_connected, comsol_server_started)
    if livelink_connected
        try
            import com.comsol.model.util.*
            ModelUtil.disconnect;
            fprintf('[adjoint] LiveLink disconnected\n');
        catch
            try
                mphexit;
            catch
                % ignore
            end
        end
    end
    if comsol_server_started
        try
            if ispc
                system('taskkill /F /IM comsolmphserver.exe >nul 2>&1');
            else
                system('pkill -f comsolmphserver 2>/dev/null');
            end
        catch
            % ignore
        end
    end
end
