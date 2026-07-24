function launcher(entry_function, params_json_path)
%LAUNCHER  Generic CLI entry for COMSOL Forward Pipeline SDK.
% =========================================================================
% Role:   SDK-layer generic MATLAB entry point (called by MatlabRunner.run)
% Source: engine/sdk/forward_pipeline/matlab/launcher.m
%
% Invocation:
%   matlab.exe -batch "addpath('<sdk_matlab_dir>'); launcher('run_forward_pipeline', '<params.json>');"
%
% Contract (with engine/sdk/forward_pipeline/matlab_runner.py):
%   1. Reads params_json_path (ASCII-only JSON).
%   2. Converts JSON struct to params struct.
%   3. Calls feval(entry_function, params).
%   4. Writes work_dir/exit.flag with 0 (success) or 1 (failure).
%   5. exit.flag is the AUTHORITATIVE exit signal (overrides process rc).
%
% ASCII safety:
%   - params.json is written with ensure_ascii=True by Python.
%   - Any Chinese strings in MATLAB-side (e.g. for diary log filenames)
%     must be constructed via char([code_points]) to keep this file ASCII.
% =========================================================================

    exit_code = 1;  % pessimistic default

    % Determine work_dir: same directory as params_json_path
    if nargin < 2 || isempty(params_json_path)
        fprintf('[launcher][ERROR] params_json_path required\n');
        write_exit_flag(exit_code, pwd);
        return;
    end

    params_json_path = char(params_json_path);
    if ~exist(params_json_path, 'file')
        fprintf('[launcher][ERROR] params.json not found: %s\n', params_json_path);
        write_exit_flag(exit_code, fileparts(params_json_path));
        return;
    end

    work_dir = fileparts(params_json_path);

    % Add this directory to path so run_*.m / forward_solve.m etc. resolve
    sdk_matlab_dir = fileparts(mfilename('fullpath'));
    addpath(sdk_matlab_dir);

    % ------------------------------------------------------------------
    % Read params.json
    % ------------------------------------------------------------------
    try
        fid = fopen(params_json_path, 'r');
        raw = fread(fid, '*char')';
        fclose(fid);
        params_json = jsondecode(raw);
    catch ME
        fprintf('[launcher][ERROR] Failed to parse params.json: %s\n', ME.message);
        write_exit_flag(exit_code, work_dir);
        return;
    end

    % ------------------------------------------------------------------
    % Convert JSON struct (only cell/struct/numeric/char) to params struct
    % ------------------------------------------------------------------
    params = struct();
    jf = fieldnames(params_json);
    for i = 1:numel(jf)
        k = jf{i};
        v = params_json.(k);
        % Skip the runner-injected meta key
        if strcmp(k, '__entry_function__')
            continue;
        end
        % jsondecode returns arrays as numeric, strings as char, etc.
        % Direct assignment works for scalar struct fields.
        params.(k) = v;
    end

    % ------------------------------------------------------------------
    % Dispatch to entry function
    % ------------------------------------------------------------------
    fprintf('[launcher] entry: %s\n', entry_function);
    fprintf('[launcher] work_dir: %s\n', work_dir);
    fprintf('[launcher] params fields: %s\n', strjoin(fieldnames(params), ', '));

    allowed_entries = {'run_forward_pipeline', 'run_adjoint_pipeline'};
    if ~ismember(entry_function, allowed_entries)
        fprintf('[launcher][ERROR] entry_function not allowed: %s\n', entry_function);
        write_exit_flag(exit_code, work_dir);
        return;
    end

    try
        result = feval(entry_function, params);

        % Determine exit code from result.status if present
        if isstruct(result) && isfield(result, 'status')
            if strcmp(result.status, 'success') || strcmp(result.status, 'cached')
                exit_code = 0;
            else
                exit_code = 1;
            end
        else
            % No status field — assume success since no exception thrown
            exit_code = 0;
        end

        % Persist result struct for debugging
        try
            result_path = fullfile(work_dir, 'pipeline_result.mat');
            save(result_path, 'result', '-v7.3');
        catch ME_save
            fprintf('[launcher][WARN] Could not save result struct: %s\n', ME_save.message);
        end

    catch ME
        exit_code = 1;
        fprintf('[launcher][ERROR] %s threw: %s\n', entry_function, ME.message);
        st = '';
        for ii = 1:numel(ME.stack)
            st = sprintf('%s\n    %s (line %d)', st, ME.stack(ii).name, ME.stack(ii).line);
        end
        fprintf('[launcher][ERROR] stack:%s\n', st);

        % Save error result for debugging
        try
            result = struct( ...
                'status', 'error', ...
                'error_msg', ME.message, ...
                'stack', st);
            result_path = fullfile(work_dir, 'pipeline_result.mat');
            save(result_path, 'result', '-v7.3');
        catch
            % ignore
        end
    end

    write_exit_flag(exit_code, work_dir);
end


% =========================================================================
% Subfunction: write_exit_flag
% =========================================================================
function write_exit_flag(code, work_dir)
    % Write work_dir/exit.flag with the integer code.
    % This is the AUTHORITATIVE exit signal read by MatlabRunner.
    try
        flag_path = fullfile(work_dir, 'exit.flag');
        fid = fopen(flag_path, 'w');
        if fid > 0
            fprintf(fid, '%d\n', code);
            fclose(fid);
        else
            fprintf('[launcher][WARN] Cannot open exit.flag for writing: %s\n', flag_path);
        end
    catch ME
        fprintf('[launcher][WARN] write_exit_flag failed: %s\n', ME.message);
    end
end
