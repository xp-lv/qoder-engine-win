function result = simple_forward_solve(params)
% SIMPLE_FORWARD_SOLVE  简化版正演求解（已知 .mph 本身工作）
% =========================================================================
% 与 SDK 沉淀版 forward_solve.m 的区别：
%   - 不做 set_epsilonr_userdef（背景场 + 默认 eps_r=1 已经能产出正确场）
%   - 不做 4 级回退写 int2/int3
%   - 直接调 study.run + mphinterp 提取场值
%
% 输出：
%   result.status, result.error_msg
%   result.scattered_field.{E_s, H_s, eval_pos, freq_list}
%   result.total_field.{E_total, voxel_pos}
% =========================================================================

    result = struct('status', '', 'error_msg', '');

    try
        import com.comsol.model.*
        import com.comsol.model.util.*

        % 加载 .mph
        fprintf('[simple] Loading model: %s\n', params.model_path);
        m = mphload(params.model_path);
        fprintf('[simple] Model loaded\n');

        % ========================================================
        % 设置背景场（可选）
        % 优先级：bg_csv（非均匀） > bg_E（均匀） > .mph 原始
        % ========================================================
        % 方式 1：均匀平面波——params.bg_E = [Ex, Ey, Ez] 单位 V/m
        if isfield(params, 'bg_E') && ~isempty(params.bg_E) ...
                && numel(params.bg_E) == 3
            bg = params.bg_E(:)';   % 强制行向量
            E0x = sprintf('%.6f[V/m]', bg(1));
            E0y = sprintf('%.6f[V/m]', bg(2));
            E0z = sprintf('%.6f[V/m]', bg(3));
            try
                m.physics('emw').prop('BackgroundField').set('Ebg', {E0x, E0y, E0z});
                fprintf('[simple] BackgroundField.Ebg (uniform) = [%.4f, %.4f, %.4f] V/m\n', ...
                    bg(1), bg(2), bg(3));
            catch ME_bg
                fprintf('[simple][WARN] bg_E set failed: %s\n', ME_bg.message);
            end
        end

        % 方式 2：非均匀背景场——params.bg_csv = 'xxx.csv'
        % CSV 格式：x, y, z, Ex_re, Ey_re, Ez_re, Ex_im, Ey_im, Ez_im
        %           （后 3 列虚部可选；不填则默认为 0）
        % 创建 6 个插值函数 int_bg_x_re / int_bg_x_im / ... 绑定到 Ebg
        if isfield(params, 'bg_csv') && ~isempty(params.bg_csv) ...
                && exist(params.bg_csv, 'file')
            setup_bg_field_from_csv(m, params.bg_csv, params.output_path);
        end

        % 如果需要设置 eps_r（用 CSV），用 importData 加载 + 绑定到 wee1
        % 关键 API 发现（COMSOL 6.2 实测）：
        %   - 没有 'argstr' 属性（这是老版 API）
        %   - set('table', numeric_matrix) 不接受数值矩阵
        %   - set('table', cell_of_strings) 也不接受
        %   - importData(filepath) 是唯一可靠的方式
        if isfield(params, 'eps_real_csv') && ~isempty(params.eps_real_csv) ...
                && exist(params.eps_real_csv, 'file')
            fprintf('[simple] Setting eps_r from CSV: %s\n', params.eps_real_csv);
            try
                % COMSOL importData 默认期望空格分隔的列，所以从 CSV 转为空格分隔 .txt
                csv_data = readmatrix(params.eps_real_csv);
                if size(csv_data, 2) < 4
                    error('CSV must have at least 4 columns: x, y, z, eps_r');
                end
                table_data = csv_data(:, 1:4);

                % 写入临时 .txt（空格分隔）
                txt_path = fullfile(fileparts(params.output_path), '.eps_r_data.txt');
                fid = fopen(txt_path, 'w');
                for ri = 1:size(table_data, 1)
                    fprintf(fid, '%.6f %.6f %.6f %.6f\n', table_data(ri, :));
                end
                fclose(fid);
                fprintf('[simple] Wrote %d rows to %s\n', size(table_data, 1), txt_path);

                % 删除旧的 int2（如果有）— 正确 API：m.func.remove('int2')
                funcs_tags = m.func.tags;
                has_int2 = false;
                for ci = 1:length(funcs_tags)
                    if strcmp(funcs_tags(ci), 'int2')
                        has_int2 = true;
                        break;
                    end
                end
                if has_int2
                    m.func.remove('int2');
                    fprintf('[simple] removed existing int2\n');
                end

                % 创建新的 int2 插值函数
                m.func.create('int2', 'Interpolation');
                m.func('int2').importData(txt_path);
                m.func('int2').set('funcname', 'int2');
                try m.func('int2').set('interp', 'linenn'); catch; end
                fprintf('[simple] int2 created from file (%d rows)\n', size(table_data, 1));

                % 关键：绑定到 emw.wee1 作为 userdef epsilonr
                % （让 COMSOL 用 int2(x,y,z) 计算每个网格点的介电常数）
                try
                    m.physics('emw').feature('wee1').set('epsilonr_mat', 'userdef');
                    m.physics('emw').feature('wee1').set('epsilonr', 'int2(x,y,z)');
                    fprintf('[simple] emw.wee1.epsilonr bound to int2(x,y,z)\n');
                catch ME_bind
                    fprintf('[simple][WARN] wee1 bind failed: %s\n', ME_bind.message);
                end
            catch ME
                fprintf('[simple][WARN] int2 setup failed: %s\n', ME.message);
            end
        end

        % 求解
        fprintf('[simple] Running study\n');
        m.study('std1').run;
        fprintf('[simple] Study run OK\n');

        % ========================================================
        % 提取散射场（在测量球面 R=params.measurement_R 上）
        % ========================================================
        n_dir = params.n_directions;
        R = params.measurement_R;
        freq_list = params.freq_list;
        n_freq = length(freq_list);

        % Fibonacci 球面采样
        golden_ratio = (1 + sqrt(5)) / 2;
        ga = 2 * pi * golden_ratio;
        idx = 0:(n_dir-1);
        theta = acos(1 - 2 * (idx + 0.5) / n_dir);   % row [1 x n_dir]
        phi = ga * idx;                                % row [1 x n_dir]

        x = R * sin(theta) .* cos(phi);   % [1 x n_dir]
        y = R * sin(theta) .* sin(phi);
        z = R * cos(theta);

        % 拼成 [n_dir x 3]
        eval_pos = [x(:), y(:), z(:)];
        fprintf('[simple] eval_pos shape: %s\n', mat2str(size(eval_pos)));

        % mphinterp coord 参数：在 6.2 上实测，[3 x N] 是正确形状
        eval_pos_3xN = eval_pos';   % [3 x n_dir]
        coord_arg = eval_pos_3xN;
        fprintf('[simple] coord_arg shape: %s\n', mat2str(size(coord_arg)));

        % 提取每个频率的散射场
        E_s_all = zeros(n_dir, 3, n_freq);
        H_s_all = zeros(n_dir, 3, n_freq);

        for fi = 1:n_freq
            % 散射场（relE）
            try
                % 先试 3 x N
                Ex_s = mphinterp(m, 'emw.relEx', 'dataset', 'dset1', ...
                                 'coord', coord_arg, 'solnum', fi);
            catch
                % 回退试 N x 3
                Ex_s = mphinterp(m, 'emw.relEx', 'dataset', 'dset1', ...
                                 'coord', eval_pos, 'solnum', fi);
            end
            try
                Ey_s = mphinterp(m, 'emw.relEy', 'dataset', 'dset1', ...
                                 'coord', coord_arg, 'solnum', fi);
            catch
                Ey_s = mphinterp(m, 'emw.relEy', 'dataset', 'dset1', ...
                                 'coord', eval_pos, 'solnum', fi);
            end
            try
                Ez_s = mphinterp(m, 'emw.relEz', 'dataset', 'dset1', ...
                                 'coord', coord_arg, 'solnum', fi);
            catch
                Ez_s = mphinterp(m, 'emw.relEz', 'dataset', 'dset1', ...
                                 'coord', eval_pos, 'solnum', fi);
            end
            E_s_all(:, 1, fi) = Ex_s;
            E_s_all(:, 2, fi) = Ey_s;
            E_s_all(:, 3, fi) = Ez_s;

            % 散射磁场
            try
                Hx_s = mphinterp(m, 'emw.relHx', 'dataset', 'dset1', ...
                                 'coord', coord_arg, 'solnum', fi);
            catch
                Hx_s = mphinterp(m, 'emw.relHx', 'dataset', 'dset1', ...
                                 'coord', eval_pos, 'solnum', fi);
            end
            try
                Hy_s = mphinterp(m, 'emw.relHy', 'dataset', 'dset1', ...
                                 'coord', coord_arg, 'solnum', fi);
            catch
                Hy_s = mphinterp(m, 'emw.relHy', 'dataset', 'dset1', ...
                                 'coord', eval_pos, 'solnum', fi);
            end
            try
                Hz_s = mphinterp(m, 'emw.relHz', 'dataset', 'dset1', ...
                                 'coord', coord_arg, 'solnum', fi);
            catch
                Hz_s = mphinterp(m, 'emw.relHz', 'dataset', 'dset1', ...
                                 'coord', eval_pos, 'solnum', fi);
            end
            H_s_all(:, 1, fi) = Hx_s;
            H_s_all(:, 2, fi) = Hy_s;
            H_s_all(:, 3, fi) = Hz_s;
        end

        E_norm = sqrt(sum(abs(E_s_all(:)).^2));
        H_norm = sqrt(sum(abs(H_s_all(:)).^2));
        fprintf('[simple] ||E_s|| = %.4e, ||H_s|| = %.4e\n', E_norm, H_norm);

        result.scattered_field = struct();
        result.scattered_field.E_s       = E_s_all;
        result.scattered_field.H_s       = H_s_all;
        result.scattered_field.eval_pos  = eval_pos;
        result.scattered_field.freq_list = freq_list;

        % ========================================================
        % 提取体素中心总场
        % ========================================================
        if isfield(params, 'voxel_positions') && ~isempty(params.voxel_positions)
            voxel_pos = params.voxel_positions;
            voxel_pos_mat = voxel_pos';   % [3 x N] for coord arg
            n_voxel = size(voxel_pos, 1);
            E_total_all = zeros(n_voxel, 3, n_freq);

            for fi = 1:n_freq
                try
                    Ex = mphinterp(m, 'emw.Ex', 'dataset', 'dset1', ...
                                   'coord', voxel_pos_mat, 'solnum', fi);
                catch
                    Ex = mphinterp(m, 'emw.Ex', 'dataset', 'dset1', ...
                                   'coord', voxel_pos, 'solnum', fi);
                end
                try
                    Ey = mphinterp(m, 'emw.Ey', 'dataset', 'dset1', ...
                                   'coord', voxel_pos_mat, 'solnum', fi);
                catch
                    Ey = mphinterp(m, 'emw.Ey', 'dataset', 'dset1', ...
                                   'coord', voxel_pos, 'solnum', fi);
                end
                try
                    Ez = mphinterp(m, 'emw.Ez', 'dataset', 'dset1', ...
                                   'coord', voxel_pos_mat, 'solnum', fi);
                catch
                    Ez = mphinterp(m, 'emw.Ez', 'dataset', 'dset1', ...
                                   'coord', voxel_pos, 'solnum', fi);
                end
                E_total_all(:, 1, fi) = Ex;
                E_total_all(:, 2, fi) = Ey;
                E_total_all(:, 3, fi) = Ez;
            end

            E_total_norm = sqrt(sum(abs(E_total_all(:)).^2));
            fprintf('[simple] ||E_total_voxel|| = %.4e\n', E_total_norm);

            result.total_field = struct();
            result.total_field.E_total   = E_total_all;
            result.total_field.voxel_pos = voxel_pos;
        end

        % ========================================================
        % 保存到 .mat
        % ========================================================
        if isfield(params, 'output_path') && ~isempty(params.output_path)
            save_data = result.scattered_field;
            if isfield(result, 'total_field') && ~isempty(result.total_field)
                save_data.E_total_voxel = result.total_field.E_total;
                save_data.voxel_pos = result.total_field.voxel_pos;
            end
            save(params.output_path, '-struct', 'save_data', '-v7.3');
            fprintf('[simple] Saved: %s\n', params.output_path);
        end

        % 不 disconnect（让外层管理）
        % ModelUtil.disconnect;   % 留给 launcher

        result.status = 'success';
        fprintf('[simple] DONE\n');

    catch ME
        result.status = 'error';
        result.error_msg = sprintf('%s\nstack:\n', ME.message);
        for ii = 1:numel(ME.stack)
            result.error_msg = [result.error_msg, ...
                sprintf('  %s (line %d)\n', ME.stack(ii).name, ME.stack(ii).line)];
        end
        fprintf('[simple][ERROR] %s\n', result.error_msg);
    end
end


% =========================================================================
function setup_bg_field_from_csv(model, csv_path, output_path)
% SETUP_BG_FIELD_FROM_CSV  从 CSV 加载非均匀背景场并绑定到 emw.Ebg
% =========================================================================
% CSV 格式：x, y, z, Ex_re, Ey_re, Ez_re, [Ex_im, Ey_im, Ez_im]
%           （后 3 列虚部可选，默认为 0）
%
% 创建 6 个插值函数：
%   int_bg_x_re, int_bg_y_re, int_bg_z_re（实部）
%   int_bg_x_im, int_bg_y_im, int_bg_z_im（虚部）
%
% 然后设 emw.Ebg = {
%   'int_bg_x_re(x,y,z) + j*int_bg_x_im(x,y,z)',
%   'int_bg_y_re(x,y,z) + j*int_bg_y_im(x,y,z)',
%   'int_bg_z_re(x,y,z) + j*int_bg_z_im(x,y,z)'
% }
% =========================================================================

    fprintf('[bg_csv] Loading non-uniform background field: %s\n', csv_path);
    csv_data = readmatrix(csv_path);
    n_cols = size(csv_data, 2);
    n_pts = size(csv_data, 1);

    if n_cols < 6
        error('bg_csv:badFormat', ...
            'CSV must have at least 6 columns: x, y, z, Ex_re, Ey_re, Ez_re (got %d)', n_cols);
    end

    has_imag = (n_cols >= 9);
    if ~has_imag
        fprintf('[bg_csv][INFO] No imaginary columns, defaulting to 0\n');
    end

    xyz = csv_data(:, 1:3);
    Ex_re = csv_data(:, 4);
    Ey_re = csv_data(:, 5);
    Ez_re = csv_data(:, 6);
    if has_imag
        Ex_im = csv_data(:, 7);
        Ey_im = csv_data(:, 8);
        Ez_im = csv_data(:, 9);
    else
        Ex_im = zeros(n_pts, 1);
        Ey_im = zeros(n_pts, 1);
        Ez_im = zeros(n_pts, 1);
    end

    % 写入 6 个 .txt 文件（空格分隔，每行：x y z value）
    out_dir = fileparts(output_path);
    if isempty(out_dir), out_dir = '.'; end

    funcs_to_create = {'int_bg_x_re', 'int_bg_y_re', 'int_bg_z_re', ...
                       'int_bg_x_im', 'int_bg_y_im', 'int_bg_z_im'};
    values = {Ex_re, Ey_re, Ez_re, Ex_im, Ey_im, Ez_im};

    for fi = 1:length(funcs_to_create)
        fn = funcs_to_create{fi};
        vals = values{fi};

        % 写 .txt
        txt_path = fullfile(out_dir, sprintf('.%s.txt', fn));
        fid = fopen(txt_path, 'w');
        if fid < 0
            error('bg_csv:fileOpen', 'Cannot open %s for writing', txt_path);
        end
        for ri = 1:n_pts
            fprintf(fid, '%.6f %.6f %.6f %.6f\n', xyz(ri,1), xyz(ri,2), xyz(ri,3), vals(ri));
        end
        fclose(fid);

        % 删旧 func（如有）
        funcs_tags = model.func.tags;
        has_old = false;
        for ci = 1:length(funcs_tags)
            if strcmp(funcs_tags(ci), fn)
                has_old = true;
                break;
            end
        end
        if has_old
            model.func.remove(fn);
        end

        % 创建 + importData
        model.func.create(fn, 'Interpolation');
        model.func(fn).importData(txt_path);
        model.func(fn).set('funcname', fn);
        try model.func(fn).set('interp', 'linenn'); catch; end
    end

    fprintf('[bg_csv] Created 6 interpolation functions (%d pts each)\n', n_pts);

    % 绑定到 emw.Ebg
    % 使用复数表达式：real + j*imag
    Ebg_x = 'int_bg_x_re(x,y,z) + j*int_bg_x_im(x,y,z)';
    Ebg_y = 'int_bg_y_re(x,y,z) + j*int_bg_y_im(x,y,z)';
    Ebg_z = 'int_bg_z_re(x,y,z) + j*int_bg_z_im(x,y,z)';
    try
        model.physics('emw').prop('BackgroundField').set('Ebg', {Ebg_x, Ebg_y, Ebg_z});
        fprintf('[bg_csv] emw.Ebg bound to 6 interpolation functions\n');
    catch ME
        fprintf('[bg_csv][ERROR] Ebg bind failed: %s\n', ME.message);
        rethrow(ME);
    end
end
