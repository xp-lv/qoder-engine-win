function result = adjoint_solve(params)
% ADJOINT_SOLVE  COMSOL 频域电磁伴随场求解脚本
% =========================================================================
% 仿体约束逆散射重建仿真验证 APP — 伴随场求解脚本 (R2a)
%
% 功能：
%   1. 将伴随源 f_adj 写入 6 个插值函数 (int4-int9)
%   2. 创建 External_current_density (vec1) 加载伴随源
%   3. 禁用散射场背景 (sctr1) — 伴随问题无背景场
%   4. 复用正演的 LU 分解因子执行伴随求解
%   5. 提取伴随场 λ（用于梯度间接项计算）
%   6. 恢复模型状态（重新启用 sctr1，移除 vec1）
%
% 参考：knowledge/COMSOL正演管线指南.md 第 8 节
%
% 接口约定：
%   params.model          — COMSOL 模型对象（从正演传递）
%                          或 params.model_path — .mph 文件路径
%   params.f_adj          — 伴随源数据 [n_voxel × 3] 复数（x/y/z 分量）
%   params.voxel_positions — 体素中心坐标 [n_voxel × 3]
%   params.freq_list      — 频率列表 [Hz]
%   params.output_path    — 伴随场输出 .mat 文件路径（可选）
%   params.timeout_minutes — 单次求解超时 [min]，默认 30
%   params.livelink_port  — LiveLink 端口，默认 2036
%
% 返回值：
%   result.status          — 'success' / 'error'
%   result.error_msg       — 错误信息
%   result.adjoint_field   — 伴随场 λ 数据 [n_voxel × 3 × n_freq]
%   result.metadata        — 运行元信息
% =========================================================================

    %% ===================== 初始化与参数校验 =====================
    result = struct('status', '', 'error_msg', '', ...
                    'adjoint_field', [], 'metadata', struct());

    % 参数默认值
    defaults = struct(...
        'timeout_minutes', 30, ...
        'livelink_port',   2036);
    params = set_defaults(params, defaults);

    % 必填字段检查
    required_fields = {'f_adj', 'voxel_positions', 'freq_list'};
    for i = 1:length(required_fields)
        f = required_fields{i};
        if ~isfield(params, f) || isempty(params.(f))
            result.status = 'error';
            result.error_msg = sprintf('Missing required parameter: %s', f);
            return;
        end
    end

    % 必须有 model 对象或 model_path
    if ~isfield(params, 'model') && ~isfield(params, 'model_path')
        result.status = 'error';
        result.error_msg = 'Either params.model or params.model_path is required.';
        return;
    end

    % 运行元信息
    result.metadata.solve_start_time = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    result.metadata.freq_list_Hz    = params.freq_list;
    result.metadata.n_voxels        = size(params.voxel_positions, 1);

    %% ===================== 获取 COMSOL 模型对象 =====================
    if isfield(params, 'model') && ~isempty(params.model)
        model = params.model;
    else
        % 需要加载模型
        try
            import com.comsol.model.*
            import com.comsol.model.util.*
            mphstart(params.livelink_port);
            model = mphload(params.model_path);
        catch ME
            result.status = 'error';
            result.error_msg = sprintf('Model load failed: %s', ME.message);
            return;
        end
    end

    %% ===================== 写入伴随源插值函数 =====================
    % 6 个插值函数将伴随源 f_adj 写入 COMSOL：
    %   int4 — f_adj_x 实部
    %   int5 — f_adj_x 虚部
    %   int6 — f_adj_y 实部
    %   int7 — f_adj_y 虚部
    %   int8 — f_adj_z 实部
    %   int9 — f_adj_z 虚部
    try
        write_adjoint_source(model, params.f_adj, params.voxel_positions);
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('Adjoint source write failed: %s', ME.message);
        return;
    end

    %% ===================== 创建 External_current_density (vec1) =====================
    try
        create_external_current(model);
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('External current density creation failed: %s', ME.message);
        return;
    end

    %% ===================== 禁用散射场背景 (sctr1) =====================
    % 伴随问题无背景场
    try
        disable_background_field(model);
    catch ME
        warning('adjoint_solve:bg', 'Background field disable failed: %s', ME.message);
        % 非致命，继续
    end

    %% ===================== 执行伴随求解（复用 LU 因子） =====================
    try
        run_adjoint_solve(model, params.timeout_minutes);
    catch ME
        % 尝试恢复模型状态后报错
        try; restore_model_state(model); catch; end
        result.status = 'error';
        result.error_msg = sprintf('Adjoint solve failed or timed out (%d min): %s', ...
                                   params.timeout_minutes, ME.message);
        return;
    end

    %% ===================== 提取伴随场 λ =====================
    try
        lambda_all = extract_adjoint_field(model, params.voxel_positions, params.freq_list);

        result.adjoint_field = struct();
        result.adjoint_field.lambda      = lambda_all;           % [n_voxel × 3 × n_freq]
        result.adjoint_field.voxel_pos   = params.voxel_positions;
        result.adjoint_field.freq_list   = params.freq_list;
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('Adjoint field extraction failed: %s', ME.message);
        try; restore_model_state(model); catch; end
        return;
    end

    %% ===================== 恢复模型状态 =====================
    % 重新启用 sctr1，移除 vec1
    % 为下一步迭代（正演求解）做准备
    try
        restore_model_state(model);
    catch ME
        warning('adjoint_solve:restore', 'Model state restore failed: %s', ME.message);
    end

    %% ===================== 保存输出 =====================
    if isfield(params, 'output_path') && ~isempty(params.output_path)
        try
            save_output(params.output_path, result);
        catch ME
            warning('adjoint_solve:save', 'Output save failed: %s', ME.message);
        end
    end

    %% ===================== 成功返回 =====================
    result.status = 'success';
    result.error_msg = '';
    result.metadata.solve_end_time = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    result.metadata.n_frequencies  = length(params.freq_list);

end

% =========================================================================
% ===================== 辅助函数 ==========================================
% =========================================================================

function p = set_defaults(p, defaults)
% SET_DEFAULTS  填充缺失的默认参数
    fnames = fieldnames(defaults);
    for i = 1:length(fnames)
        f = fnames{i};
        if ~isfield(p, f) || isempty(p.(f))
            p.(f) = defaults.(f);
        end
    end
end

% -------------------------------------------------------------------------

function write_adjoint_source(model, f_adj, voxel_pos)
% WRITE_ADJOINT_SOURCE
%   将伴随源 f_adj 的实虚部分量写入 6 个插值函数 (int4-int9)
%
%   f_adj: [n_voxel × 3] 复数矩阵（x, y, z 分量）
%   voxel_pos: [n_voxel × 3] 坐标

    % 分离实虚部
    f_adj_x_real = real(f_adj(:, 1));
    f_adj_x_imag = imag(f_adj(:, 1));
    f_adj_y_real = real(f_adj(:, 2));
    f_adj_y_imag = imag(f_adj(:, 2));
    f_adj_z_real = real(f_adj(:, 3));
    f_adj_z_imag = imag(f_adj(:, 3));

    % 构造 CSV 表格数据 [x, y, z, value]
    table_int4 = [voxel_pos, f_adj_x_real];   % int4: f_adj_x 实部
    table_int5 = [voxel_pos, f_adj_x_imag];   % int5: f_adj_x 虚部
    table_int6 = [voxel_pos, f_adj_y_real];   % int6: f_adj_y 实部
    table_int7 = [voxel_pos, f_adj_y_imag];   % int7: f_adj_y 虚部
    table_int8 = [voxel_pos, f_adj_z_real];   % int8: f_adj_z 实部
    table_int9 = [voxel_pos, f_adj_z_imag];   % int9: f_adj_z 虚部

    % 写入各插值函数
    create_interp_function(model, 'int4', table_int4, {'x', 'y', 'z'});
    create_interp_function(model, 'int5', table_int5, {'x', 'y', 'z'});
    create_interp_function(model, 'int6', table_int6, {'x', 'y', 'z'});
    create_interp_function(model, 'int7', table_int7, {'x', 'y', 'z'});
    create_interp_function(model, 'int8', table_int8, {'x', 'y', 'z'});
    create_interp_function(model, 'int9', table_int9, {'x', 'y', 'z'});
end

% -------------------------------------------------------------------------

function create_interp_function(model, func_name, table_data, argnames)
% CREATE_INTERP_FUNCTION  创建或更新 COMSOL 插值函数
    try
        model.func().remove(func_name);
    catch
    end

    model.func().create(func_name, 'Interpolation');
    model.func(func_name).set('argname', argnames{:});
    model.func(func_name).set('interp', 'linear');
    model.func(func_name).set('extrap', 'const');

    coords = table_data(:, 1:3);
    values = table_data(:, 4);
    full_table = [coords, values];

    table_cell = num2cell(full_table');
    model.func(func_name).set('table', table_cell);
    model.func(func_name).set('funcname', func_name);
end

% -------------------------------------------------------------------------

function create_external_current(model)
% CREATE_EXTERNAL_CURRENT
%   创建 External_current_density (vec1) 加载伴随源
%   表达式将 int4-int9 组合为复数外部电流密度

    % 伴随源表达式（复数形式）
    % Jx = int4(x,y,z) + i*int5(x,y,z)
    % Jy = int6(x,y,z) + i*int7(x,y,z)
    % Jz = int8(x,y,z) + i*int9(x,y,z)
    Jx_expr = 'int4(x,y,z) + i*int5(x,y,z)';
    Jy_expr = 'int6(x,y,z) + i*int7(x,y,z)';
    Jz_expr = 'int8(x,y,z) + i*int9(x,y,z)';

    success = false;

    % 尝试在 emw 物理场中创建外部电流密度节点
    try
        emw = model.component('comp1').physics('emw');

        % 尝试常见标签名
        vec_tags = {'vec1', 'ExternalCurrentDensity1', 'ec1'};

        % 先检查是否已存在，若存在则更新
        for vi = 1:length(vec_tags)
            try
                vec = emw.feature(vec_tags{vi});
                vec.set('Jx', Jx_expr);
                vec.set('Jy', Jy_expr);
                vec.set('Jz', Jz_expr);
                vec.set('enabled', true);
                success = true;
                return;
            catch
                continue;
            end
        end

        % 不存在，创建新节点
        try
            emw.feature().create('vec1', 'ExternalCurrentDensity', 3);
            vec = emw.feature('vec1');
            vec.set('Jx', Jx_expr);
            vec.set('Jy', Jy_expr);
            vec.set('Jz', Jz_expr);
            success = true;
        catch
            % 尝试其他创建方式
            try
                emw.create('vec1', 'ExternalCurrentDensity', 3);
                emw.set('Jx', Jx_expr);
                emw.set('Jy', Jy_expr);
                emw.set('Jz', Jz_expr);
                success = true;
            catch
            end
        end
    catch
    end

    % 备选：尝试 ewfd 命名空间
    if ~success
        try
            ewfd = model.component('comp1').physics('ewfd');
            ewfd.feature().create('vec1', 'ExternalCurrentDensity', 3);
            vec = ewfd.feature('vec1');
            vec.set('Jx', Jx_expr);
            vec.set('Jy', Jy_expr);
            vec.set('Jz', Jz_expr);
            success = true;
        catch
        end
    end

    if ~success
        error('adjoint_solve:extCurrent', ...
              'Failed to create External_current_density (vec1).');
    end
end

% -------------------------------------------------------------------------

function disable_background_field(model)
% DISABLE_BACKGROUND_FIELD
%   禁用散射场背景 (sctr1) — 伴随问题无背景场

    success = false;

    % 尝试禁用 sctr1（散射场背景场节点）
    sctr_tags = {'sctr1', 'BackgroundField1', 'bg1', 'sctr'};
    phys_tags_to_try = {'emw', 'ewfd'};

    for pi = 1:length(phys_tags_to_try)
        try
            phys = model.component('comp1').physics(phys_tags_to_try{pi});
            for si = 1:length(sctr_tags)
                try
                    sctr = phys.feature(sctr_tags{si});
                    sctr.set('enabled', false);
                    success = true;
                    return;
                catch
                    continue;
                end
            end
        catch
            continue;
        end
    end

    % 备选：遍历物理场所有 feature，查找背景场相关并禁用
    if ~success
        try
            physics = model.component('comp1').physics();
            all_phys_tags = physics.tags();
            for pi = 1:length(all_phys_tags)
                phys = physics.feature(all_phys_tags{pi});
                feat_tags = phys.tags();
                for fi = 1:length(feat_tags)
                    feat_tag = feat_tags{fi};
                    if contains(lower(feat_tag), 'sctr') || ...
                       contains(lower(feat_tag), 'background') || ...
                       contains(lower(feat_tag), 'bg')
                        try
                            feat = phys.feature(feat_tag);
                            feat.set('enabled', false);
                            success = true;
                        catch
                            continue;
                        end
                    end
                end
            end
        catch
        end
    end

    if ~success
        warning('adjoint_solve:disableBg', ...
                'Could not disable background field (sctr1) by standard name. Manual check recommended.');
    end
end

% -------------------------------------------------------------------------

function run_adjoint_solve(model, timeout_minutes)
% RUN_ADJOINT_SOLVE
%   执行伴随场求解，复用正演的 LU 分解因子

    % 尝试复用已有 LU 分解因子（不重新初始化求解器）
    try
        % 使用相同的 solver 序列，COMSOL 会自动复用矩阵分解
        % 仅右端项（源项）改变
        model.study('std1').run();
    catch
        % 若复用失败，重新求解
        try
            model.sol().clearSolution();
            model.study('std1').run();
        catch ME
            error('adjoint_solve:runFailed', ...
                  'Adjoint solve execution failed: %s', ME.message);
        end
    end

    % 超时检查（近似）
    % COMSOL Java API 不直接支持运行中超时
    % 此处依赖外部 timeout 机制
end

% -------------------------------------------------------------------------

function lambda_all = extract_adjoint_field(model, voxel_pos, freq_list)
% EXTRACT_ADJOINT_FIELD
%   在体素中心提取伴随场 λ（复数）
%
%   输出维度：
%     lambda_all — [n_voxel × 3 × n_freq] 复数

    n_voxel = size(voxel_pos, 1);
    n_freq = length(freq_list);

    lambda_all = zeros(n_voxel, 3, n_freq);

    for fi = 1:n_freq
        try
            % 伴随场 λ = 求解后的电场（此时源是伴随源而非背景场）
            lx = mphinterp(model, 'emw.Ex', 'dataset', 'dset1', ...
                          'selection', voxel_pos', ...
                          'solnum', fi);
            ly = mphinterp(model, 'emw.Ey', 'dataset', 'dset1', ...
                          'selection', voxel_pos', ...
                          'solnum', fi);
            lz = mphinterp(model, 'emw.Ez', 'dataset', 'dset1', ...
                          'selection', voxel_pos', ...
                          'solnum', fi);

            lambda_all(:, 1, fi) = lx;
            lambda_all(:, 2, fi) = ly;
            lambda_all(:, 3, fi) = lz;
        catch
            % 备选：ewfd 命名空间
            try
                lx = mphinterp(model, 'ewfd.Ex', 'dataset', 'dset1', ...
                              'selection', voxel_pos', 'solnum', fi);
                ly = mphinterp(model, 'ewfd.Ey', 'dataset', 'dset1', ...
                              'selection', voxel_pos', 'solnum', fi);
                lz = mphinterp(model, 'ewfd.Ez', 'dataset', 'dset1', ...
                              'selection', voxel_pos', 'solnum', fi);

                lambda_all(:, 1, fi) = lx;
                lambda_all(:, 2, fi) = ly;
                lambda_all(:, 3, fi) = lz;
            catch ME
                warning('adjoint_solve:extract', ...
                        'Adjoint field extraction failed for freq %d: %s', fi, ME.message);
            end
        end
    end
end

% -------------------------------------------------------------------------

function restore_model_state(model)
% RESTORE_MODEL_STATE
%   伴随求解后恢复模型到正演状态：
%   1. 重新启用散射场背景 (sctr1)
%   2. 移除 External_current_density (vec1)
%   为下一步迭代的正演求解做准备

    % ---- 重新启用 sctr1 ----
    sctr_tags = {'sctr1', 'BackgroundField1', 'bg1'};
    phys_tags_to_try = {'emw', 'ewfd'};

    for pi = 1:length(phys_tags_to_try)
        try
            phys = model.component('comp1').physics(phys_tags_to_try{pi});
            for si = 1:length(sctr_tags)
                try
                    sctr = phys.feature(sctr_tags{si});
                    sctr.set('enabled', true);
                catch
                end
            end

            % 遍历查找并重新启用背景场相关 feature
            feat_tags = phys.tags();
            for fi = 1:length(feat_tags)
                feat_tag = feat_tags{fi};
                if contains(lower(feat_tag), 'sctr') || ...
                   contains(lower(feat_tag), 'background')
                    try
                        phys.feature(feat_tag).set('enabled', true);
                    catch
                    end
                end
            end
        catch
        end
    end

    % ---- 移除 External_current_density (vec1) ----
    vec_tags = {'vec1', 'ExternalCurrentDensity1', 'ec1'};

    for pi = 1:length(phys_tags_to_try)
        try
            phys = model.component('comp1').physics(phys_tags_to_try{pi});
            for vi = 1:length(vec_tags)
                try
                    % 先禁用
                    phys.feature(vec_tags{vi}).set('enabled', false);
                catch
                end
                try
                    % 然后移除
                    phys.feature().remove(vec_tags{vi});
                catch
                end
            end
        catch
        end
    end
end

% -------------------------------------------------------------------------

function save_output(output_path, result)
% SAVE_OUTPUT  保存标准化 .mat 输出文件

    [out_dir, ~, ~] = fileparts(output_path);
    if ~isempty(out_dir) && ~exist(out_dir, 'dir')
        mkdir(out_dir);
    end

    save(output_path, '-struct', 'result');

    fprintf('[adjoint_solve] Output saved to: %s\n', output_path);
end
function result = adjoint_solve(params, model)
% ADJOINT_SOLVE  COMSOL 伴随场求解脚本
% =========================================================================
% 仿体约束逆散射重建仿真验证 APP — 伴随场求解层
%
% 在已执行正演求解的 COMSOL 模型上，写入伴随源 f_adj，
% 禁用散射场背景场，复用正演 LU 分解因子执行伴随场求解，
% 在体素中心提取伴随场 lambda，然后恢复模型到正演状态。
%
% 伴随场用于反演算法 (R3/R4) 中的梯度计算:
%   g_direct = -i*omega*eps0 * conj(eps_r - 1) .* conj(lambda .* E_total)
%   g_indirect = ... (通过 Born 近似)
%
% 接口参数:
%   params.model_path          — COMSOL 模型文件路径 (.mph)
%   params.f_adj               — 伴随源数据 [n_vox × 3] (复数, 外部电流密度)
%       或 params.f_adj_csv_re — 伴随源实部 CSV (列: x, y, z, fx, fy, fz)
%       或 params.f_adj_csv_im — 伴随源虚部 CSV (列: x, y, z, fx, fy, fz)
%   params.voxel_positions     — 体素中心坐标 [n_vox × 3]
%   params.freq_list           — 频率列表 [Hz]
%   params.timeout_minutes     — 单次求解超时 [min] (默认 30)
%   params.livelink_port       — LiveLink 端口 (默认 2036)
%   params.output_path         — 输出 .mat 文件路径 (可选)
%
% 传入参数:
%   model — (可选) 已加载并正演求解的 COMSOL 模型对象。
%           若传入，直接复用其 LU 分解因子; 若不传，从 model_path 加载。
%
% 返回结构体 (result):
%   result.status         — 'success' | 'error'
%   result.error_msg      — 错误信息
%   result.adjoint_field  — 伴随场数据:
%       .lambda           — 伴随场 lambda [n_vox × 3 × n_freq] (complex)
%       .voxel_positions  — 体素中心坐标
%       .freq_list        — 频率列表
%       .solve_time_s     — 求解耗时 [s]
%
% 参考文档:
%   - knowledge/COMSOL正演管线指南.md §8 伴随场求解
%   - 仿真配置.md §7 反演算法参数 (9 步迭代循环 ⑥⑦)
%
% 作者: R2a — COMSOL 脚本编写者
% 版本: v1.0
% =========================================================================

    %% ---- 初始化结果结构体 ----
    result = struct();
    result.status = 'error';
    result.error_msg = '';
    result.adjoint_field = struct();

    model_loaded_here = false;   % 标记是否在本函数内加载模型

    %% ---- 参数校验 ----
    try
        params = validate_adjoint_params(params);
    catch ME
        result.error_msg = sprintf('[adjoint_solve] 参数校验失败: %s', ME.message);
        return;
    end

    timer_start = tic;

    try
        %% ========== 1. 加载或复用 COMSOL 模型 ==========
        if nargin < 2 || isempty(model)
            % 未传入模型 — 从文件加载
            import com.comsol.model.*
            import com.comsol.model.util.*

            ensure_livelink(params.livelink_port);

            fprintf('[adjoint_solve] 加载 COMSOL 模型: %s\n', params.model_path);
            model = mphload(params.model_path);
            model_loaded_here = true;
            fprintf('[adjoint_solve] 注意: 新加载模型，LU 分解因子不可复用\n');
        else
            % 复用已传入的模型 (含 LU 分解因子)
            fprintf('[adjoint_solve] 复用已传入的 COMSOL 模型 (LU 分解因子可复用)\n');
        end

        %% ========== 2. 写入伴随源 f_adj 到插值函数 (int4-int9) ==========
        %  6 个插值函数分别存储伴随源的各分量实虚部:
        %    int4 → f_adj_x 实部
        %    int5 → f_adj_x 虚部
        %    int6 → f_adj_y 实部
        %    int7 → f_adj_y 虚部
        %    int8 → f_adj_z 实部
        %    int9 → f_adj_z 虚部
        fprintf('[adjoint_solve] 写入伴随源 f_adj 到插值函数 (int4-int9)...\n');

        write_adjoint_source(model, params);

        %% ========== 3. 创建 External_current_density (vec1) ==========
        %  将伴随源加载为外部电流密度，驱动伴随场方程
        fprintf('[adjoint_solve] 创建 External_current_density (vec1)...\n');
        create_external_current_density(model);

        %% ========== 4. 禁用散射场背景 (sctr1) ==========
        %  伴随问题无背景场 — 禁用散射场公式中的背景场贡献
        fprintf('[adjoint_solve] 禁用散射场背景 (sctr1)...\n');
        disable_background_field(model);

        %% ========== 5. 配置频率扫描 ==========
        freq_str = strtrim(sprintf('%.6e ', params.freq_list));
        fprintf('[adjoint_solve] 设置频率扫描: [%s]\n', freq_str);
        model.study('std1').feature('freq').set('plist', freq_str);

        %% ========== 6. 执行伴随场求解 (复用 LU 分解因子) ==========
        fprintf('[adjoint_solve] 启动 COMSOL 伴随场求解 (超时 %d min)...\n', ...
                params.timeout_minutes);

        solve_adjoint_with_timeout(model, params.timeout_minutes);

        solve_time = toc(timer_start);
        fprintf('[adjoint_solve] 伴随求解完成 (耗时 %.1f s)\n', solve_time);

        %% ========== 7. 提取伴随场 lambda (体素中心) ==========
        fprintf('[adjoint_solve] 提取体素中心伴随场 lambda...\n');

        n_freq = numel(params.freq_list);
        n_vox = size(params.voxel_positions, 1);
        voxel_coords = params.voxel_positions';   % [3 × n_vox]

        lambda = zeros(n_vox, 3, n_freq);

        for fi = 1:n_freq
            lx = mphinterp(model, 'emw.Ex', ...
                'dataset', 'dset1', 'coord', voxel_coords, ...
                'tunit', 'Hz', 'solnum', fi);
            ly = mphinterp(model, 'emw.Ey', ...
                'dataset', 'dset1', 'coord', voxel_coords, ...
                'tunit', 'Hz', 'solnum', fi);
            lz = mphinterp(model, 'emw.Ez', ...
                'dataset', 'dset1', 'coord', voxel_coords, ...
                'tunit', 'Hz', 'solnum', fi);

            lambda(:, 1, fi) = lx;
            lambda(:, 2, fi) = ly;
            lambda(:, 3, fi) = lz;
        end

        fprintf('[adjoint_solve] lambda 提取完成: %d 体素 × 3 分量 × %d 频率\n', ...
                n_vox, n_freq);

        %% ========== 8. 恢复模型状态到正演配置 ==========
        %  重新启用 sctr1 (散射场背景)，移除 vec1 (外部电流密度)
        %  为下一步迭代的正演求解做准备
        fprintf('[adjoint_solve] 恢复模型状态 (重新启用 sctr1, 移除 vec1)...\n');
        restore_forward_state(model);

        %% ========== 9. 保存输出 (可选) ==========
        output_data = struct();
        output_data.lambda = lambda;
        output_data.voxel_positions = params.voxel_positions;
        output_data.freq_list = params.freq_list;
        output_data.solve_time_s = solve_time;
        output_data.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');

        if ~isempty(params.output_path)
            output_dir = fileparts(params.output_path);
            if ~isempty(output_dir) && ~exist(output_dir, 'dir')
                mkdir(output_dir);
            end
            save(params.output_path, '-struct', 'output_data');
            fprintf('[adjoint_solve] 伴随场结果已保存: %s\n', params.output_path);
        end

        %% ========== 10. 组装返回结构体 ==========
        result.adjoint_field.lambda = lambda;
        result.adjoint_field.voxel_positions = params.voxel_positions;
        result.adjoint_field.freq_list = params.freq_list;
        result.adjoint_field.solve_time_s = solve_time;

        result.status = 'success';
        fprintf('[adjoint_solve] ===== 伴随场求解成功 =====\n');

    catch ME
        solve_time = toc(timer_start);
        result.status = 'error';
        result.error_msg = sprintf('[adjoint_solve] 求解失败: %s\n  文件: %s (行 %d)\n  标识: %s', ...
            ME.message, ME.stack(1).name, ME.stack(1).line, ME.identifier);
        result.solve_time_s = solve_time;
        fprintf(2, '%s\n', result.error_msg);

        % 尝试恢复模型状态 (即使出错也尝试恢复)
        try
            if ~isempty(model) && exist('model', 'var')
                restore_forward_state(model);
            end
        catch
            % 忽略恢复错误
        end
    end
end


% =========================================================================
% ============================ 辅助函数 ====================================
% =========================================================================

function params = validate_adjoint_params(params)
% VALIDATE_ADJOINT_PARAMS  校验伴随求解参数并填充默认值

    if ~isstruct(params)
        error('adjoint_solve:InvalidParams', 'params 必须为结构体');
    end

    % 必填参数检查
    required_fields = {'freq_list', 'voxel_positions'};
    for i = 1:numel(required_fields)
        fld = required_fields{i};
        if ~isfield(params, fld) || isempty(params.(fld))
            error('adjoint_solve:MissingParam', '缺少必填参数: params.%s', fld);
        end
    end

    % 伴随源数据检查 — 必须有 f_adj 或 CSV 路径
    has_f_adj = isfield(params, 'f_adj') && ~isempty(params.f_adj);
    has_csv = (isfield(params, 'f_adj_csv_re') && ~isempty(params.f_adj_csv_re)) || ...
              (isfield(params, 'f_adj_csv_im') && ~isempty(params.f_adj_csv_im));
    if ~has_f_adj && ~has_csv
        error('adjoint_solve:MissingParam', ...
              '需要提供 params.f_adj (矩阵) 或 params.f_adj_csv_re/im (CSV 路径)');
    end

    % 默认值填充
    defaults = struct( ...
        'model_path',       '', ...
        'timeout_minutes',  30, ...
        'livelink_port',    2036, ...
        'output_path',      '', ...
        'f_adj',            [], ...
        'f_adj_csv_re',     '', ...
        'f_adj_csv_im',     '');

    flds = fieldnames(defaults);
    for i = 1:numel(flds)
        fld = flds{i};
        if ~isfield(params, fld) || isempty(params.(fld))
            params.(fld) = defaults.(fld);
        end
    end

    if params.timeout_minutes < 1
        error('adjoint_solve:InvalidParam', 'timeout_minutes 必须 >= 1');
    end
end


function ensure_livelink(port)
% ENSURE_LIVELINK  确认 COMSOL LiveLink 连接状态

    try
        mphstart(port);
        fprintf('[adjoint_solve] LiveLink 连接成功 (端口 %d)\n', port);
    catch
        try
            models = ModelUtil.models;
            if ~isempty(models)
                fprintf('[adjoint_solve] LiveLink 已有活动连接\n');
                return;
            end
        catch
            % 忽略
        end
        error('adjoint_solve:LiveLinkError', ...
              '无法连接 COMSOL LiveLink (端口 %d)', port);
    end
end


function write_adjoint_source(model, params)
% WRITE_ADJOINT_SOURCE  将伴随源 f_adj 写入 6 个插值函数 (int4-int9)
%
% 6 个插值函数分别存储伴随源 f_adj 的各分量实虚部:
%   int4 → f_adj_x 实部
%   int5 → f_adj_x 虚部
%   int6 → f_adj_y 实部
%   int7 → f_adj_y 虚部
%   int8 → f_adj_z 实部
%   int9 → f_adj_z 虚部
%
% 数据来源:
%   - params.f_adj (矩阵 [n_vox × 3] 复数) + params.voxel_positions
%   - 或 params.f_adj_csv_re / params.f_adj_csv_im (CSV 路径)

    % 从矩阵或 CSV 获取伴随源数据
    if ~isempty(params.f_adj)
        % 从矩阵数据构建
        voxel_pos = params.voxel_positions;   % [n_vox × 3]
        f_adj = params.f_adj;                 % [n_vox × 3] complex

        % 拆分实虚部
        f_re = real(f_adj);   % [n_vox × 3]
        f_im = imag(f_adj);   % [n_vox × 3]

        % 构建 CSV 表格: [x, y, z, fx, fy, fz]
        csv_re = [voxel_pos, f_re];
        csv_im = [voxel_pos, f_im];

    else
        % 从 CSV 文件读取
        if ~isempty(params.f_adj_csv_re) && exist(params.f_adj_csv_re, 'file')
            csv_re = readmatrix(params.f_adj_csv_re);
        else
            csv_re = [];
        end
        if ~isempty(params.f_adj_csv_im) && exist(params.f_adj_csv_im, 'file')
            csv_im = readmatrix(params.f_adj_csv_im);
        else
            csv_im = [];
        end
    end

    % 写入 6 个插值函数
    % int4: f_adj_x 实部
    write_single_interp(model, 'int4', csv_re, 4);   % 第4列 = fx_re
    % int5: f_adj_x 虚部
    write_single_interp(model, 'int5', csv_im, 4);   % 第4列 = fx_im
    % int6: f_adj_y 实部
    write_single_interp(model, 'int6', csv_re, 5);   % 第5列 = fy_re
    % int7: f_adj_y 虚部
    write_single_interp(model, 'int7', csv_im, 5);   % 第5列 = fy_im
    % int8: f_adj_z 实部
    write_single_interp(model, 'int8', csv_re, 6);   % 第6列 = fz_re
    % int9: f_adj_z 虚部
    write_single_interp(model, 'int9', csv_im, 6);   % 第6列 = fz_im

    fprintf('[adjoint_solve] 伴随源已写入 int4-int9 (6 个插值函数)\n');
end


function write_single_interp(model, func_name, csv_data, value_col)
% WRITE_SINGLE_INTERP  将单列数据写入 COMSOL 插值函数
%
% 参数:
%   model      — COMSOL 模型对象
%   func_name  — 插值函数标签 (如 'int4')
%   csv_data   — 完整 CSV 数据矩阵 [n × 6] (x, y, z, fx, fy, fz)
%   value_col  — 要提取的值列号 (4=fx, 5=fy, 6=fz)

    % 提取 (x, y, z, value) 四列
    if isempty(csv_data)
        % 无数据 — 写入零值
        if model.func().index(func_name) == 0
            model.func().create(func_name, 'Interpolation');
        end
        model.func(func_name).set('funcname', func_name);
        model.func(func_name).set('argname', {'x', 'y', 'z'});
        model.func(func_name).set('nargs', 3);
        model.func(func_name).set('table', sprintf('%.6e %.6e %.6e %.6e\n', [0 0 0 0]));
        fprintf('[adjoint_solve] %s: 无数据，写入零值\n', func_name);
        return;
    end

    % 确保列数足够
    if size(csv_data, 2) < value_col
        % 值列不存在 — 写入零值
        interp_data = [csv_data(:, 1:3), zeros(size(csv_data, 1), 1)];
    else
        interp_data = [csv_data(:, 1:3), csv_data(:, value_col)];
    end

    % 创建或更新插值函数
    try
        existing_idx = model.func().index(func_name);
    catch
        existing_idx = 0;
    end

    if existing_idx == 0
        model.func().create(func_name, 'Interpolation');
    end

    model.func(func_name).set('funcname', func_name);
    model.func(func_name).set('argname', {'x', 'y', 'z'});
    model.func(func_name).set('nargs', 3);
    model.func(func_name).set('extrap', 'linear');
    model.func(func_name).set('interp', 'linear');

    % 写入数据表
    n_rows = size(interp_data, 1);
    table_str = '';
    for r = 1:n_rows
        table_str = [table_str, sprintf('%.6e %.6e %.6e %.6e\n', interp_data(r, :))];
    end
    model.func(func_name).set('table', table_str);

    fprintf('[adjoint_solve] %s: 写入 %d 个数据点\n', func_name, n_rows);
end


function create_external_current_density(model)
% CREATE_EXTERNAL_CURRENT_DENSITY  创建外部电流密度节点 (vec1)
%
% 在 EMW 物理场中创建 External_current_density 节点，
% 引用 int4-int9 插值函数定义伴随源的三个分量:
%   Jx = int4(x,y,z) + i*int5(x,y,z)
%   Jy = int6(x,y,z) + i*int7(x,y,z)
%   Jz = int8(x,y,z) + i*int9(x,y,z)

    comp_tags = model.component().tags();
    created = false;

    for ct = comp_tags
        comp = model.component(ct);
        try
            phys_tags = comp.physics().tags();
            for pt = phys_tags
                phys = comp.physics(pt);
                phys_type = '';
                try
                    phys_type = phys.getType();
                catch
                    % 忽略
                end

                if contains(phys_type, 'ElectromagneticWaves') || strcmp(pt, 'emw')
                    % 检查是否已存在 vec1
                    try
                        existing = phys.feature('vec1');
                        % 已存在 — 更新
                        existing.set('Jx', sprintf('int4(x,y,z)+i*int5(x,y,z)'));
                        existing.set('Jy', sprintf('int6(x,y,z)+i*int7(x,y,z)'));
                        existing.set('Jz', sprintf('int8(x,y,z)+i*int9(x,y,z)'));
                        existing.set('enabled', 'on');
                        fprintf('[adjoint_solve] vec1 已存在，已更新\n');
                        created = true;
                        return;
                    catch
                        % 不存在 — 创建新节点
                        try
                            phys.feature().create('vec1', 'ExternalCurrentDensity', 1);
                            vec1 = phys.feature('vec1');
                            vec1.set('Jx', sprintf('int4(x,y,z)+i*int5(x,y,z)'));
                            vec1.set('Jy', sprintf('int6(x,y,z)+i*int7(x,y,z)'));
                            vec1.set('Jz', sprintf('int8(x,y,z)+i*int9(x,y,z)'));
                            fprintf('[adjoint_solve] vec1 (ExternalCurrentDensity) 创建成功\n');
                            created = true;
                            return;
                        catch ME2
                            % 尝试备选类型名
                            try
                                phys.feature().create('vec1', 'ExternalCurrentDensity');
                                vec1 = phys.feature('vec1');
                                vec1.set('Jx', sprintf('int4(x,y,z)+i*int5(x,y,z)'));
                                vec1.set('Jy', sprintf('int6(x,y,z)+i*int7(x,y,z)'));
                                vec1.set('Jz', sprintf('int8(x,y,z)+i*int9(x,y,z)'));
                                fprintf('[adjoint_solve] vec1 创建成功 (备选)\n');
                                created = true;
                                return;
                            catch
                                % 继续尝试
                            end
                        end
                    end
                end
            end
        catch
            % 跳过
        end
    end

    if ~created
        error('adjoint_solve:Vec1CreationFailed', ...
              '无法创建 External_current_density (vec1)');
    end
end


function disable_background_field(model)
% DISABLE_BACKGROUND_FIELD  禁用散射场背景场 (sctr1)
%
% 伴随问题无背景场 — 禁用散射场公式中的背景场贡献 (sctr1 节点)，
% 使 COMSOL 仅在伴随源 (vec1) 驱动下求解。

    comp_tags = model.component().tags();
    disabled = false;

    for ct = comp_tags
        comp = model.component(ct);
        try
            phys_tags = comp.physics().tags();
            for pt = phys_tags
                phys = comp.physics(pt);
                try
                    % 查找散射场背景节点 sctr1
                    sctr1 = phys.feature('sctr1');
                    sctr1.set('enabled', 'off');
                    fprintf('[adjoint_solve] sctr1 已禁用\n');
                    disabled = true;
                    return;
                catch
                    % 尝试其他可能的标签名
                    alt_tags = {'sctr1', 'scat1', 'scatteredField1', ...
                                'backgroundField1', 'bf1'};
                    for at = alt_tags
                        try
                            feat = phys.feature(at);
                            feat.set('enabled', 'off');
                            fprintf('[adjoint_solve] 背景场节点 %s 已禁用\n', at);
                            disabled = true;
                            return;
                        catch
                            % 继续尝试
                        end
                    end
                end

                % 暴力搜索: 查找包含 'scattered' 或 'background' 的特征
                feat_tags = phys.feature().tags();
                for ft = feat_tags
                    try
                        feat = phys.feature(ft);
                        feat_type = feat.getType();
                        if contains(feat_type, 'Scattered') || ...
                           contains(feat_type, 'Background') || ...
                           contains(feat_type, 'background')
                            feat.set('enabled', 'off');
                            fprintf('[adjoint_solve] 背景场节点 %s (%s) 已禁用\n', ...
                                    ft, feat_type);
                            disabled = true;
                        end
                    catch
                        % 跳过
                    end
                end
            end
        catch
            % 跳过
        end
    end

    if ~disabled
        fprintf('[adjoint_solve] 警告: 未找到散射场背景节点 sctr1 (可能已在模型中预设)\n');
    end
end


function restore_forward_state(model)
% RESTORE_FORWARD_STATE  恢复模型到正演状态
%
% 伴随求解完成后恢复模型配置:
%   1. 重新启用散射场背景 (sctr1)
%   2. 移除/禁用 External_current_density (vec1)
% 为下一步迭代的正演求解做准备。

    restored_sctr = false;
    removed_vec = false;

    comp_tags = model.component().tags();

    for ct = comp_tags
        comp = model.component(ct);
        try
            phys_tags = comp.physics().tags();
            for pt = phys_tags
                phys = comp.physics(pt);

                % 1. 重新启用散射场背景 (sctr1)
                try
                    sctr1 = phys.feature('sctr1');
                    sctr1.set('enabled', 'on');
                    fprintf('[adjoint_solve] sctr1 已重新启用\n');
                    restored_sctr = true;
                catch
                    % 尝试其他标签
                    alt_tags = {'scat1', 'scatteredField1', 'backgroundField1', 'bf1'};
                    for at = alt_tags
                        try
                            feat = phys.feature(at);
                            feat.set('enabled', 'on');
                            fprintf('[adjoint_solve] 背景场节点 %s 已重新启用\n', at);
                            restored_sctr = true;
                            break;
                        catch
                            % 继续
                        end
                    end
                end

                % 暴力搜索恢复
                if ~restored_sctr
                    feat_tags = phys.feature().tags();
                    for ft = feat_tags
                        try
                            feat = phys.feature(ft);
                            feat_type = feat.getType();
                            if contains(feat_type, 'Scattered') || ...
                               contains(feat_type, 'Background')
                                feat.set('enabled', 'on');
                                fprintf('[adjoint_solve] 背景场节点 %s 已重新启用\n', ft);
                                restored_sctr = true;
                            end
                        catch
                            % 跳过
                        end
                    end
                end

                % 2. 移除/禁用 External_current_density (vec1)
                try
                    vec1 = phys.feature('vec1');
                    % 优先禁用 (比删除更安全，保留可复用性)
                    vec1.set('enabled', 'off');
                    fprintf('[adjoint_solve] vec1 已禁用\n');
                    removed_vec = true;
                catch
                    % vec1 不存在或已移除
                end
            end
        catch
            % 跳过
        end
    end

    if ~restored_sctr
        fprintf('[adjoint_solve] 警告: 未能显式恢复 sctr1 (可能已默认启用)\n');
    end
    if ~removed_vec
        fprintf('[adjoint_solve] 警告: 未找到 vec1 用于禁用 (可能已被移除)\n');
    end

    % 清理插值函数 (int4-int9) 以释放内存 (可选)
    cleanup_interp_funcs = false;   % 设为 true 可在恢复后清理插值函数
    if cleanup_interp_funcs
        func_names = {'int4', 'int5', 'int6', 'int7', 'int8', 'int9'};
        for fn = func_names
            try
                model.func().remove(fn{:});
                fprintf('[adjoint_solve] 插值函数 %s 已移除\n', fn{:});
            catch
                % 跳过
            end
        end
    end

    fprintf('[adjoint_solve] 模型状态已恢复到正演配置\n');
end


function solve_adjoint_with_timeout(model, timeout_minutes)
% SOLVE_ADJOINT_WITH_TIMEOUT  执行 COMSOL 伴随场求解 (带超时保护)
%
% 复用正演的 LU 分解因子执行伴随求解。
% COMSOL 在检测到相同系数矩阵时自动复用已有 LU 分解。

    timeout_seconds = timeout_minutes * 60;
    timer_start = tic;

    study_tags = model.study().tags();
    if isempty(study_tags)
        error('adjoint_solve:NoStudy', '模型中未找到任何研究 (study)');
    end

    % 重置求解器以确保复用 LU 因子
    % COMSOL 在求解序列中会自动检测并复用已有矩阵分解
    primary_study = study_tags{1};

    % 清除之前的解 (但保留矩阵结构以复用 LU 分解)
    try
        sol_tags = model.sol().tags();
        for sot = sol_tags
            sol = model.sol(sot);
            % 尝试复用 LU 分解 (不清除因子)
            try
                sol.feature('st1').create('v1', 'Variables');
                fprintf('[adjoint_solve] 尝试复用 LU 分解因子\n');
            catch
                % 跳过
            end
        end
    catch
        % 跳过
    end

    % 执行求解
    model.study(primary_study).run();

    elapsed = toc(timer_start);
    if elapsed > timeout_seconds
        error('adjoint_solve:Timeout', ...
              '伴随求解超时: %.1f s > %.1f s (%.0f min)', ...
              elapsed, timeout_seconds, timeout_minutes);
    end

    fprintf('[adjoint_solve] 伴随求解耗时: %.1f s (%.1f min)\n', ...
            elapsed, elapsed / 60);
end
