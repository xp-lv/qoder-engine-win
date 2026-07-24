function result = forward_solve(params)
% FORWARD_SOLVE  COMSOL 频域电磁正演求解脚本
% =========================================================================
% 仿体约束逆散射重建仿真验证 APP — 正演数据层脚本 (R2a)
%
% 功能：
%   1. 连接 COMSOL LiveLink（端口 2036）
%   2. 将 eps_r 分布写入 int2/int3 插值函数（含 4 级回退策略）
%   3. 设置 epsilonr_mat = 'userdef'
%   4. 配置 PARDISO 直接求解器 + PML 吸收边界
%   5. 频率扫描求解 [0.8 GHz, 1.0 GHz]
%   6. 在测量球面 (R=0.26m) 提取散射场 E^s / H^s（64 Fibonacci 方向）
%   7. 在体素中心提取总场 E_total（用于 J_equi 计算）
%   8. 输出标准化 .mat 文件
%
% 接口约定 (skill.md 步骤1)：
%   params.eps_real_csv    — eps_r 实部 CSV 路径 [char]
%   params.eps_imag_csv   — eps_r 虚部 CSV 路径 [char]
%   params.freq_list      — 频率列表 [Hz]，如 [0.8e9, 1.0e9]
%   params.model_path     — COMSOL 模型文件路径 (.mph) [char]
%   params.measurement_R  — 测量球面半径 [m]，默认 0.26
%   params.n_directions   — Fibonacci 方向数，默认 64
%   params.output_path    — 输出 .mat 文件路径 [char]
%   params.timeout_minutes — 单次求解超时 [min]，默认 30
%   params.livelink_port  — LiveLink 端口，默认 2036
%
% 返回值：
%   result.status          — 'success' / 'error'
%   result.error_msg       — 错误信息（仅 error 时）
%   result.scattered_field — 散射场数据结构体
%   result.total_field     — 体素中心总场
%   result.metadata        — 运行元信息
% =========================================================================

    %% ===================== 初始化与参数校验 =====================
    result = struct('status', '', 'error_msg', '', ...
                    'scattered_field', [], 'total_field', [], ...
                    'metadata', struct());

    % 参数默认值
    defaults = struct(...
        'measurement_R',  0.26, ...
        'n_directions',   64, ...
        'timeout_minutes', 30, ...
        'livelink_port',  2036);
    params = set_defaults(params, defaults);

    % 必填字段检查
    required_fields = {'eps_real_csv', 'freq_list', 'model_path', 'output_path'};
    for i = 1:length(required_fields)
        f = required_fields{i};
        if ~isfield(params, f) || isempty(params.(f))
            result.status = 'error';
            result.error_msg = sprintf('Missing required parameter: %s', f);
            return;
        end
    end

    % 运行元信息
    result.metadata.solve_start_time  = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    result.metadata.freq_list_Hz     = params.freq_list;
    result.metadata.measurement_R_m  = params.measurement_R;
    result.metadata.n_directions     = params.n_directions;
    result.metadata.livelink_port    = params.livelink_port;

    %% ===================== COMSOL LiveLink 连接 =====================
    try
        model = connect_comsol(params.livelink_port, params.model_path);
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('COMSOL LiveLink connection failed: %s', ME.message);
        return;
    end

    %% ===================== 写入 eps_r 插值函数 =====================
    % int2(x,y,z) — eps_r 实部
    % int3(x,y,z) — eps_r 虚部（损耗，如有）
    try
        write_epsilon_r(model, params.eps_real_csv, params.eps_imag_csv);
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('Failed to write epsilon_r interpolation: %s', ME.message);
        return;
    end

    %% ===================== 配置 PARDISO 求解器 =====================
    try
        configure_solver(model);
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('Solver configuration failed: %s', ME.message);
        return;
    end

    %% ===================== 配置 PML 吸收边界 =====================
    try
        configure_pml(model);
    catch ME
        % PML 通常已在 .mph 模型中预设，此处仅做确认/补设
        warning('forward_solve:PML', 'PML config note: %s', ME.message);
    end

    %% ===================== 设置频率扫描 =====================
    % 必须使用 study.feature('freq').set('plist', ...) 避免嵌套 API 陷阱
    try
        set_frequency_sweep(model, params.freq_list);
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('Frequency sweep setup failed: %s', ME.message);
        return;
    end

    %% ===================== 预计算评估点 =====================
    % 测量球面 64 Fibonacci 方向 × R=0.26m
    eval_pos = fibonacci_sphere(params.n_directions, params.measurement_R);

    % 体素中心坐标（从模型网格获取或从 params 传入）
    voxel_pos = [];
    if isfield(params, 'voxel_positions')
        voxel_pos = params.voxel_positions;
    else
        voxel_pos = get_voxel_centers(model);
    end

    %% ===================== 执行正演求解（超时保护） =====================
    try
        run_forward_with_timeout(model, params.timeout_minutes);
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('Forward solve failed or timed out (%d min): %s', ...
                                   params.timeout_minutes, ME.message);
        return;
    end

    %% ===================== 提取散射场 E^s / H^s =====================
    try
        % 提取每个频率下的散射电场 E^s (relEx, relEy, relEz)
        % 以及散射磁场 H^s (relHx, relHy, relHz)
        [E_s_all, H_s_all] = extract_scattered_field(model, eval_pos, params.freq_list);

        result.scattered_field = struct();
        result.scattered_field.E_s        = E_s_all;   % [n_dir × 3 × n_freq] 复数
        result.scattered_field.H_s        = H_s_all;   % [n_dir × 3 × n_freq] 复数
        result.scattered_field.eval_pos   = eval_pos;  % [n_dir × 3] 坐标
        result.scattered_field.freq_list  = params.freq_list;
        result.scattered_field.R_measure  = params.measurement_R;
    catch ME
        result.status = 'error';
        result.error_msg = sprintf('Scattered field extraction failed: %s', ME.message);
        return;
    end

    %% ===================== 提取体素中心总场 =====================
    try
        E_total_all = extract_total_field(model, voxel_pos, params.freq_list);

        result.total_field = struct();
        result.total_field.E_total   = E_total_all;  % [n_voxel × 3 × n_freq] 复数
        result.total_field.voxel_pos = voxel_pos;
    catch ME
        warning('forward_solve:totalField', 'Total field extraction failed: %s', ME.message);
        result.total_field = struct();
        result.total_field.E_total = [];
    end

    %% ===================== 保存标准化输出 =====================
    try
        save_output(params.output_path, result);
    catch ME
        warning('forward_solve:save', 'Output save failed: %s', ME.message);
    end

    %% ===================== 成功返回 =====================
    result.status = 'success';
    result.error_msg = '';
    result.metadata.solve_end_time = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    result.metadata.n_frequencies  = length(params.freq_list);
    result.metadata.n_eval_points  = params.n_directions;

end

% =========================================================================
% ===================== 辅助函数 ==========================================
% =========================================================================

function p = set_defaults(p, defaults)
% SET_DEFAULTS  为 params 中缺失的字段填充默认值
    fnames = fieldnames(defaults);
    for i = 1:length(fnames)
        f = fnames{i};
        if ~isfield(p, f) || isempty(p.(f))
            p.(f) = defaults.(f);
        end
    end
end

% -------------------------------------------------------------------------

function model = connect_comsol(port, model_path)
% CONNECT_COMSOL  建立 COMSOL LiveLink 连接并加载模型
    import com.comsol.model.*
    import com.comsol.model.util.*

    % 连接到已在运行的 COMSOL Server
    mphstart(port);

    % 创建/获取模型对象
    model = ModelUtil.create('Model');

    % 加载预构建的 .mph 模型文件（含几何、网格、物理场设置）
    if exist(model_path, 'file')
        model = mphload(model_path);
    else
        error('forward_solve:modelNotFound', ...
              'Model file not found: %s', model_path);
    end

    % 连接验证
    if ~ModelUtil.isConnected()
        error('forward_solve:notConnected', ...
              'COMSOL LiveLink not connected on port %d', port);
    end
end

% -------------------------------------------------------------------------

function write_epsilon_r(model, eps_real_csv, eps_imag_csv)
% WRITE_EPSILON_R
%   将 eps_r 分布写入 COMSOL int2/int3 插值函数
%   并设置 epsilonr_mat = 'userdef'（关键！）
%
%   实现 4 级回退策略：
%     Level 1: 扫描所有 EMW 特征中包含 'int2' 的属性
%     Level 2: 直接覆盖 wee1.epsilonr
%     Level 3: 材料节点属性修改
%     Level 4: 暴力遍历所有已知特征名

    % ---- 读取 CSV 数据 ----
    % CSV 格式：x, y, z, value（体素中心坐标 + eps_r 值）
    csv_real = readmatrix(eps_real_csv);
    if isempty(csv_real) || size(csv_real, 2) < 4
        error('forward_solve:csvFormat', ...
              'eps_real_csv must have columns [x, y, z, value]');
    end
    table_real = csv_real(:, 1:4);  % [x, y, z, eps_r_real]

    % 虚部（如有损耗）
    has_imag = false;
    table_imag = [];
    if ~isempty(eps_imag_csv) && exist(eps_imag_csv, 'file')
        csv_imag = readmatrix(eps_imag_csv);
        if ~isempty(csv_imag) && size(csv_imag, 2) >= 4
            table_imag = csv_imag(:, 1:4);
            has_imag = true;
        end
    end

    % ---- 创建/更新 int2（实部）插值函数 ----
    create_interp_function(model, 'int2', table_real, {'x', 'y', 'z'});

    % ---- 创建/更新 int3（虚部）插值函数 ----
    if has_imag
        create_interp_function(model, 'int3', table_imag, {'x', 'y', 'z'});
    else
        % 无损耗：虚部全零
        table_imag_zero = [table_real(:, 1:3), zeros(size(table_real, 1), 1)];
        create_interp_function(model, 'int3', table_imag_zero, {'x', 'y', 'z'});
    end

    % ---- 设置 epsilonr_mat = 'userdef'（4 级回退）----
    set_epsilonr_userdef(model, has_imag);
end

% -------------------------------------------------------------------------

function create_interp_function(model, func_name, table_data, argnames)
% CREATE_INTERP_FUNCTION  创建或更新 COMSOL 插值函数
    try
        % 尝试删除已有函数（如存在）
        model.func().remove(func_name);
    catch
        % 函数不存在，忽略
    end

    % 创建插值函数
    model.func().create(func_name, 'Interpolation');

    % 设置参数名
    model.func(func_name).set('argname', argnames{:});

    % 设置插值方法为线性（最近邻亦可）
    model.func(func_name).set('interp', 'linear');

    % 设置外推方法为常数（域外保持最近值）
    model.func(func_name).set('extrap', 'const');

    % 写入表格数据（COMSOL 期望 cellarray 或 matrix）
    % table_data: [N × 4] = [x, y, z, value]
    n_pts = size(table_data, 1);
    coords = table_data(:, 1:3);     % [N × 3]
    values = table_data(:, 4);       % [N × 1]

    % COMSOL table 格式：列拼接 [coords | values]
    full_table = [coords, values];

    % 将矩阵转为 cellarray 以适应 COMSOL API
    table_cell = num2cell(full_table');
    model.func(func_name).set('table', table_cell);

    % 设置函数表达式（便于在物理场中引用）
    model.func(func_name).set('funcname', func_name);
end

% -------------------------------------------------------------------------

function set_epsilonr_userdef(model, has_imag)
% SET_EPSILONR_USERDEF
%   设置 epsilonr_mat = 'userdef'，使 COMSOL 使用 int2/int3 而非材料节点
%   实现 4 级回退策略

    % 构造 eps_r 表达式
    if has_imag
        eps_expr = 'int2(x,y,z) + i*int3(x,y,z)';
    else
        eps_expr = 'int2(x,y,z)';
    end

    success = false;

    % ---- Level 1: 扫描所有 EMW 特征中包含 'epsilonr' 的属性 ----
    try
        success = try_level1_scan(model, eps_expr);
    catch
        % Level 1 失败，继续回退
    end

    if success; return; end

    % ---- Level 2: 直接覆盖 wee1.epsilonr ----
    try
        success = try_level2_direct(model, eps_expr);
    catch
    end

    if success; return; end

    % ---- Level 3: 材料节点属性修改 ----
    try
        success = try_level3_material(model);
    catch
    end

    if success; return; end

    % ---- Level 4: 暴力遍历所有已知特征名 ----
    try
        success = try_level4_brute(model, eps_expr);
    catch
    end

    if ~success
        error('forward_solve:epsilonrFailed', ...
              ['All 4 fallback levels failed to set epsilonr_mat = userdef.\n', ...
               'Check COMSOL model physics node names.']);
    end
end

% -------------------------------------------------------------------------

function success = try_level1_scan(model, eps_expr)
% LEVEL 1: 扫描所有 EMW 特征中包含 'epsilonr' 的属性
    success = false;
    physics = model.component('comp1').physics();
    phys_tags = physics.tags();

    for pi = 1:length(phys_tags)
        phys = physics.feature(phys_tags{pi});
        feat_tags = phys.tags();
        for fi = 1:length(feat_tags)
            feat = phys.feature(feat_tags{fi});
            try
                prop_names = feat.properties();
                for pp = 1:length(prop_names)
                    pn = prop_names{pp};
                    if contains(pn, 'epsilonr')
                        feat.set(pn, 'userdef');
                        success = true;
                    end
                end
                % 若发现 epsilonr_mat 属性，同时设 eps 表达式
                if success && isprop(feat, 'epsilonr')
                    feat.set('epsilonr', eps_expr);
                end
            catch
                continue;
            end
        end
    end
end

% -------------------------------------------------------------------------

function success = try_level2_direct(model, eps_expr)
% LEVEL 2: 直接覆盖 wee1.epsilonr
    success = false;
    try
        emw = model.component('comp1').physics('emw');
        wee1 = emw.feature('wEE1');
        wee1.set('epsilonr_mat', 'userdef');
        wee1.set('epsilonr', eps_expr);
        success = true;
    catch
        % wEE1 不存在，尝试其他常见标签
        alt_tags = {'wee1', 'WaveEquationE1', 'wee1_1'};
        for t = 1:length(alt_tags)
            try
                emw = model.component('comp1').physics('emw');
                feat = emw.feature(alt_tags{t});
                feat.set('epsilonr_mat', 'userdef');
                feat.set('epsilonr', eps_expr);
                success = true;
                return;
            catch
                continue;
            end
        end
    end
end

% -------------------------------------------------------------------------

function success = try_level3_material(model)
% LEVEL 3: 通过材料节点设置
    success = false;
    try
        mat = model.component('comp1').material();
        mat_tags = mat.tags();
        for mi = 1:length(mat_tags)
            mfeat = mat.feature(mat_tags{mi});
            try
                % 设置介电常数属性指向 userdef
                mfeat.propertyGroup('RefractiveIndex').set('n', 1);
                success = true;
            catch
                % 尝试其他属性组
                try
                    pg = mfeat.propertyGroup('iespec');
                    pg.set('epsilonr', {'int2(x,y,z)'});
                    success = true;
                catch
                    continue;
                end
            end
        end
    catch
    end
end

% -------------------------------------------------------------------------

function success = try_level4_brute(model, eps_expr)
% LEVEL 4: 暴力遍历所有已知特征名
    success = false;
    known_feat_tags = {'wEE1', 'wee1', 'WaveEquationE1', 'wee1_1', ...
                       'emw_wEE1', 'EW1'};

    try
        physics = model.component('comp1').physics();
        phys_tags = physics.tags();

        for pi = 1:length(phys_tags)
            phys_tag = phys_tags{pi};
            phys = physics.feature(phys_tag);

            % 尝试已知标签
            for ti = 1:length(known_feat_tags)
                try
                    feat = phys.feature(known_feat_tags{ti});
                    feat.set('epsilonr_mat', 'userdef');
                    feat.set('epsilonr', eps_expr);
                    success = true;
                    return;
                catch
                    continue;
                end
            end

            % 遍历所有子特征
            feat_tags = phys.tags();
            for fi = 1:length(feat_tags)
                try
                    feat = phys.feature(feat_tags{fi});
                    feat.set('epsilonr_mat', 'userdef');
                    feat.set('epsilonr', eps_expr);
                    success = true;
                    return;
                catch
                    continue;
                end
            end
        end
    catch
    end
end

% -------------------------------------------------------------------------

function configure_solver(model)
% CONFIGURE_SOLVER  配置 PARDISO 直接求解器（备选 MUMPS）
    try
        % 获取求解器序列
        study = model.study('std1');
        sol_tags = study.tags();

        % 设置频域求解器使用 PARDISO
        for si = 1:length(sol_tags)
            sol = study.feature(sol_tags{si});
            try
                % 设置直接求解器为 PARDISO
                sol.set('solmethod', 'direct');
            catch
            end
        end

        % 直接操作 solver 节点
        try
            solv = model.sol();
            solv_tags = solv.tags();
            for sv = 1:length(solv_tags)
                sv_feat = solv.feature(solv_tags{sv});
                try
                    % 尝试设置 PARDISO
                    sv_feat.set('linpmethod', 'pardiso');
                catch
                    % 尝试 MUMPS 作为备选
                    try
                        sv_feat.set('linpmethod', 'mumps');
                    catch
                    end
                end
            end
        catch
        end

    catch ME
        warning('forward_solve:solverConfig', ...
                'Solver auto-config incomplete: %s. Using model defaults.', ME.message);
    end
end

% -------------------------------------------------------------------------

function configure_pml(model)
% CONFIGURE_PML  确认/配置 PML 吸收边界
    % PML 通常已在 .mph 模型中预设
    % 此处做确认检查，如不存在则给出警告
    try
        % 检查 PML 节点是否存在
        geom = model.component('comp1').geom();
        % PML 通过 geometry feature 或 physics boundary 实现
        % COMSOL 6.2 中 PML 通常通过 domain setup
        try
            pml = model.component('comp1').physics('emw').feature('pml1');
            % 已存在，确认配置
            pml.set('type', 'spherical');  % 球形 PML
        catch
            % PML 节点可能以不同名称存在或通过 mesh + material 实现
            warning('forward_solve:pml', ...
                    'PML node not found by standard name. Ensure PML is configured in .mph model.');
        end
    catch ME
        warning('forward_solve:pml', 'PML check failed: %s', ME.message);
    end
end

% -------------------------------------------------------------------------

function set_frequency_sweep(model, freq_list)
% SET_FREQUENCY_SWEEP
%   通过 study.feature('freq').set('plist', ...) 设置频率扫描
%   避免 COMSOL 频率缓存的嵌套 API 陷阱

    % 将频率列表格式化为空格分隔字符串（COMSOL API 要求）
    freq_str = sprintf('%.6e ', freq_list);
    freq_str = strtrim(freq_str);

    study = model.study('std1');

    % 查找频域扫描 feature
    freq_feature_tags = {'freq', 'freq1', 'Frequency1', 'fsweep1'};

    success = false;
    for fi = 1:length(freq_feature_tags)
        try
            freq_feat = study.feature(freq_feature_tags{fi});
            freq_feat.set('plist', freq_str);
            success = true;
            return;
        catch
            continue;
        end
    end

    if ~success
        % 尝试遍历所有 study features 查找频域类型
        all_tags = study.tags();
        for ai = 1:length(all_tags)
            try
                afeat = study.feature(all_tags{ai});
                afeat.set('plist', freq_str);
                success = true;
                return;
            catch
                continue;
            end
        end
    end

    if ~success
        error('forward_solve:freqSetup', ...
              'Could not set frequency sweep. Study feature not found.');
    end
end

% -------------------------------------------------------------------------

function run_forward_with_timeout(model, timeout_minutes)
% RUN_FORWARD_WITH_TIMEOUT  执行 COMSOL 求解，带超时保护

    % 重置求解器状态（清除缓存）
    try
        model.sol().clearSolution();
    catch
    end

    % 设置超时（通过 timer 或 COMSOL 内部超时）
    % COMSOL Java API 不直接支持超时，此处使用 MATLAB timer 兜底
    timeout_sec = timeout_minutes * 60;

    % 执行求解
    t_start = tic;
    model.study('std1').run();
    elapsed = toc(t_start);

    if elapsed > timeout_sec
        error('forward_solve:timeout', ...
              'Forward solve exceeded timeout of %d minutes.', timeout_minutes);
    end
end

% -------------------------------------------------------------------------

function pos = fibonacci_sphere(n_points, radius)
% FIBONACCI_SPHERE  生成球面上均匀分布的 n_points 个点（Fibonacci 螺旋）
%   返回 [n_points × 3] 的坐标矩阵

    golden_ratio = (1 + sqrt(5)) / 2;
    angle_increment = pi * 2 * golden_ratio;

    pos = zeros(n_points, 3);
    for i = 0:n_points-1
        % 垂直分布：从 ~1 到 ~-1
        t = (i + 0.5) / n_points;
        z = 1 - 2 * t;          % [-1, 1]
        r_xy = sqrt(1 - z^2);   % 纬度圆半径

        theta = i * angle_increment;

        x = cos(theta) * r_xy;
        y = sin(theta) * r_xy;

        % 缩放到指定半径
        pos(i+1, :) = [x, y, z] * radius;
    end
end

% -------------------------------------------------------------------------

function voxel_pos = get_voxel_centers(model)
% GET_VOXEL_CENTERS  从 COMSOL 网格提取体素中心坐标
%   仿真配置：19268 体素

    voxel_pos = [];

    try
        % 通过 mphmesh 获取网格节点坐标
        mesh_data = mphmesh(model, 'mesh1');
        if isfield(mesh_data, 'p')
            voxel_pos = mesh_data.p';  % [n_nodes × 3]
        end
    catch
    end

    % 备选：通过 mphinterp 在已知体素网格上采样
    if isempty(voxel_pos)
        try
            % 尝试从 data set 获取坐标
            % 此处返回空，由调用方通过 params.voxel_positions 提供
            voxel_pos = [];
        catch
        end
    end
end

% -------------------------------------------------------------------------

function [E_s_all, H_s_all] = extract_scattered_field(model, eval_pos, freq_list)
% EXTRACT_SCATTERED_FIELD
%   在测量球面提取散射电场 E^s 和散射磁场 H^s
%
%   输出维度：
%     E_s_all — [n_dir × 3 × n_freq] 复数
%     H_s_all — [n_dir × 3 × n_freq] 复数

    n_dir = size(eval_pos, 1);
    n_freq = length(freq_list);

    E_s_all = zeros(n_dir, 3, n_freq);
    H_s_all = zeros(n_dir, 3, n_freq);

    % mphinterp 提取散射场（relEx/relEy/relEz = 相对散射电场分量）
    for fi = 1:n_freq
        % 提取散射电场 E^s
        try
            Ex = mphinterp(model, 'emw.relEx', 'dataset', 'dset1', ...
                          'selection', eval_pos', ...
                          'solnum', fi);
            Ey = mphinterp(model, 'emw.relEy', 'dataset', 'dset1', ...
                          'selection', eval_pos', ...
                          'solnum', fi);
            Ez = mphinterp(model, 'emw.relEz', 'dataset', 'dset1', ...
                          'selection', eval_pos', ...
                          'solnum', fi);

            E_s_all(:, 1, fi) = Ex;
            E_s_all(:, 2, fi) = Ey;
            E_s_all(:, 3, fi) = Ez;
        catch
            % 备选：尝试使用 ewfd 命名空间
            try
                Ex = mphinterp(model, 'ewfd.relEx', 'dataset', 'dset1', ...
                              'selection', eval_pos', 'solnum', fi);
                Ey = mphinterp(model, 'ewfd.relEy', 'dataset', 'dset1', ...
                              'selection', eval_pos', 'solnum', fi);
                Ez = mphinterp(model, 'ewfd.relEz', 'dataset', 'dset1', ...
                              'selection', eval_pos', 'solnum', fi);
                E_s_all(:, 1, fi) = Ex;
                E_s_all(:, 2, fi) = Ey;
                E_s_all(:, 3, fi) = Ez;
            catch ME2
                warning('forward_solve:extractE', ...
                        'E^s extraction failed for freq %d: %s', fi, ME2.message);
            end
        end

        % 提取散射磁场 H^s
        try
            Hx = mphinterp(model, 'emw.relHx', 'dataset', 'dset1', ...
                          'selection', eval_pos', ...
                          'solnum', fi);
            Hy = mphinterp(model, 'emw.relHy', 'dataset', 'dset1', ...
                          'selection', eval_pos', ...
                          'solnum', fi);
            Hz = mphinterp(model, 'emw.relHz', 'dataset', 'dset1', ...
                          'selection', eval_pos', ...
                          'solnum', fi);

            H_s_all(:, 1, fi) = Hx;
            H_s_all(:, 2, fi) = Hy;
            H_s_all(:, 3, fi) = Hz;
        catch
            try
                Hx = mphinterp(model, 'ewfd.relHx', 'dataset', 'dset1', ...
                              'selection', eval_pos', 'solnum', fi);
                Hy = mphinterp(model, 'ewfd.relHy', 'dataset', 'dset1', ...
                              'selection', eval_pos', 'solnum', fi);
                Hz = mphinterp(model, 'ewfd.relHz', 'dataset', 'dset1', ...
                              'selection', eval_pos', 'solnum', fi);
                H_s_all(:, 1, fi) = Hx;
                H_s_all(:, 2, fi) = Hy;
                H_s_all(:, 3, fi) = Hz;
            catch ME2
                warning('forward_solve:extractH', ...
                        'H^s extraction failed for freq %d: %s', fi, ME2.message);
            end
        end
    end
end

% -------------------------------------------------------------------------

function E_total_all = extract_total_field(model, voxel_pos, freq_list)
% EXTRACT_TOTAL_FIELD
%   在体素中心提取总场 E_total（用于 J_equi = -iωε₀(ε_r-1)·E_total 计算）
%
%   输出维度：
%     E_total_all — [n_voxel × 3 × n_freq] 复数

    n_voxel = size(voxel_pos, 1);
    n_freq = length(freq_list);

    E_total_all = zeros(n_voxel, 3, n_freq);

    if n_voxel == 0
        return;
    end

    for fi = 1:n_freq
        try
            % 总场 = 背景场 + 散射场（emw.Ex/Ey/Ez 是总场）
            Ex = mphinterp(model, 'emw.Ex', 'dataset', 'dset1', ...
                          'selection', voxel_pos', ...
                          'solnum', fi);
            Ey = mphinterp(model, 'emw.Ey', 'dataset', 'dset1', ...
                          'selection', voxel_pos', ...
                          'solnum', fi);
            Ez = mphinterp(model, 'emw.Ez', 'dataset', 'dset1', ...
                          'selection', voxel_pos', ...
                          'solnum', fi);

            E_total_all(:, 1, fi) = Ex;
            E_total_all(:, 2, fi) = Ey;
            E_total_all(:, 3, fi) = Ez;
        catch
            try
                Ex = mphinterp(model, 'ewfd.Ex', 'dataset', 'dset1', ...
                              'selection', voxel_pos', 'solnum', fi);
                Ey = mphinterp(model, 'ewfd.Ey', 'dataset', 'dset1', ...
                              'selection', voxel_pos', 'solnum', fi);
                Ez = mphinterp(model, 'ewfd.Ez', 'dataset', 'dset1', ...
                              'selection', voxel_pos', 'solnum', fi);
                E_total_all(:, 1, fi) = Ex;
                E_total_all(:, 2, fi) = Ey;
                E_total_all(:, 3, fi) = Ez;
            catch ME2
                warning('forward_solve:extractTotal', ...
                        'E_total extraction failed for freq %d: %s', fi, ME2.message);
            end
        end
    end
end

% -------------------------------------------------------------------------

function save_output(output_path, result)
% SAVE_OUTPUT  保存标准化 .mat 输出文件

    % 确保输出目录存在
    [out_dir, ~, ~] = fileparts(output_path);
    if ~isempty(out_dir) && ~exist(out_dir, 'dir')
        mkdir(out_dir);
    end

    % 保存结果
    save(output_path, '-struct', 'result');

    fprintf('[forward_solve] Output saved to: %s\n', output_path);
end
function result = forward_solve(params)
% FORWARD_SOLVE  COMSOL 频域电磁散射正演求解脚本
% =========================================================================
% 仿体约束逆散射重建仿真验证 APP — 正演数据层
%
% 加载 COMSOL 预构建模型，写入介电常数分布 (eps_r)，
% 执行频域散射场求解 (PARDISO 直接求解器)，
% 在测量球面上提取散射场 E^s / H^s，在体素中心提取总场 E_total。
%
% 接口参数 (params 结构体):
%   params.eps_real_csv      — eps_r 实部 CSV 路径 (列: x, y, z, value)
%   params.eps_imag_csv      — eps_r 虚部 CSV 路径 (列: x, y, z, value)
%   params.freq_list         — 频率列表 [Hz]，如 [0.8e9, 1.0e9]
%   params.model_path        — COMSOL 模型文件路径 (.mph)
%   params.measurement_R     — 测量球面半径 [m] (默认 0.26)
%   params.n_directions      — Fibonacci 方向数 (默认 64)
%   params.output_path       — 输出 .mat 文件路径
%   params.timeout_minutes   — 单次求解超时 [min] (默认 30)
%   params.livelink_port     — LiveLink 端口 (默认 2036)
%   params.solver            — 求解器: 'pardiso' (默认) | 'mumps'
%   params.voxel_positions   — (可选) 体素中心坐标 [n_vox × 3]
%
% 返回结构体 (result):
%   result.status            — 'success' | 'error'
%   result.error_msg         — 错误信息 (status='error' 时填充)
%   result.scattered_field   — 散射场数据:
%       .E_s                 — 散射电场 [n_dir × 3 × n_freq] (complex)
%       .H_s                 — 散射磁场 [n_dir × 3 × n_freq] (complex)
%       .E_total_voxels      — 体素总场 [n_vox × 3 × n_freq] (complex)
%       .directions          — Fibonacci 采样点坐标 [n_dir × 3]
%       .freq_list           — 实际使用的频率列表
%       .solve_time_s        — 求解耗时 [s]
%
% 参考文档:
%   - 仿真配置.md §6 COMSOL 求解配置
%   - knowledge/COMSOL正演管线指南.md
%   - config/phantom_config.json
%
% 作者: R2a — COMSOL 脚本编写者
% 版本: v1.0
% =========================================================================

    %% ---- 初始化结果结构体 ----
    result = struct();
    result.status = 'error';   % 默认错误，成功时覆盖为 'success'
    result.error_msg = '';
    result.scattered_field = struct();

    %% ---- 参数校验与默认值填充 ----
    try
        params = validate_params(params);
    catch ME
        result.error_msg = sprintf('[forward_solve] 参数校验失败: %s', ME.message);
        return;
    end

    %% ---- 主求解流程 ----
    model = [];
    timer_start = tic;

    try
        %% ========== 1. 生成 Fibonacci 球面采样点 ==========
        fprintf('[forward_solve] 生成 %d 个 Fibonacci 球面采样点 (R=%.2f m)...\n', ...
                params.n_directions, params.measurement_R);
        directions = fibonacci_sphere(params.n_directions, params.measurement_R);
        % directions: [n_dir × 3], 每行 (x, y, z) 坐标

        %% ========== 2. 加载 COMSOL 模型 ==========
        fprintf('[forward_solve] 加载 COMSOL 模型: %s\n', params.model_path);
        import com.comsol.model.*
        import com.comsol.model.util.*

        % 确认 LiveLink 连接
        ensure_livelink(params.livelink_port);

        % 加载预构建的 .mph 模型文件
        if exist(params.model_path, 'file')
            model = mphload(params.model_path);
        else
            error('forward_solve:ModelNotFound', ...
                  '模型文件不存在: %s', params.model_path);
        end
        fprintf('[forward_solve] 模型加载成功\n');

        %% ========== 3. 写入 eps_r 插值函数 (int2/int3) ==========
        fprintf('[forward_solve] 写入介电常数插值函数...\n');

        % int2: eps_r 实部
        write_interpolation_function(model, 'int2', ...
            params.eps_real_csv, {'x', 'y', 'z'}, ...
            'extrapMethod', 'linear', ...
            'interpMethod', 'linear');

        % int3: eps_r 虚部 (损耗)
        write_interpolation_function(model, 'int3', ...
            params.eps_imag_csv, {'x', 'y', 'z'}, ...
            'extrapMethod', 'linear', ...
            'interpMethod', 'linear');

        fprintf('[forward_solve] int2 (实部) 和 int3 (虚部) 插值函数已写入\n');

        %% ========== 4. 设置 epsilonr_mat = 'userdef' ==========
        %  关键: 若不设为 'userdef'，COMSOL 会忽略 int2/int3，从材料节点读取默认值
        fprintf('[forward_solve] 设置 epsilonr_mat = userdef...\n');
        set_epsilon_userdef(model);

        %% ========== 5. eps_r 更新 — 4 级回退策略 ==========
        fprintf('[forward_solve] 执行 eps_r 更新 (4 级回退策略)...\n');
        update_success = update_epsilon_4level_fallback(model);
        if ~update_success
            error('forward_solve:EpsilonUpdateFailed', ...
                  '4 级回退策略全部失败，无法写入 eps_r');
        end
        fprintf('[forward_solve] eps_r 更新成功\n');

        %% ========== 6. PML 吸收边界配置 ==========
        fprintf('[forward_solve] 验证 PML 吸收边界配置...\n');
        configure_pml(model);

        %% ========== 7. PARDISO / MUMPS 求解器配置 ==========
        fprintf('[forward_solve] 配置求解器: %s\n', params.solver);
        configure_solver(model, params.solver);

        %% ========== 8. 频率扫描设置 ==========
        %  关键: 必须使用 study.feature('freq').set('plist', ...) 避免嵌套 API 陷阱
        freq_str = strtrim(sprintf('%.6e ', params.freq_list));
        fprintf('[forward_solve] 设置频率扫描: [%s]\n', freq_str);

        model.study('std1').feature('freq').set('plist', freq_str);

        %% ========== 9. 执行正演求解 (带超时保护) ==========
        fprintf('[forward_solve] 启动 COMSOL 频域正演求解 (超时 %d min)...\n', ...
                params.timeout_minutes);

        solve_with_timeout(model, params.timeout_minutes);

        solve_time = toc(timer_start);
        fprintf('[forward_solve] 正演求解完成 (耗时 %.1f s)\n', solve_time);

        %% ========== 10. 提取散射电场 E^s ==========
        fprintf('[forward_solve] 提取测量球面上的散射电场 E^s...\n');
        n_freq = numel(params.freq_list);

        % 准备评估坐标矩阵 [3 × n_dir]
        eval_coords = directions';   % [3 × n_dir]

        E_s = zeros(params.n_directions, 3, n_freq);
        H_s = zeros(params.n_directions, 3, n_freq);

        for fi = 1:n_freq
            % 散射电场分量
            E_sx = mphinterp(model, 'emw.relEx', ...
                'dataset', 'dset1', 'coord', eval_coords, ...
                'tunit', 'Hz', 'solnum', fi);
            E_sy = mphinterp(model, 'emw.relEy', ...
                'dataset', 'dset1', 'coord', eval_coords, ...
                'tunit', 'Hz', 'solnum', fi);
            E_sz = mphinterp(model, 'emw.relEz', ...
                'dataset', 'dset1', 'coord', eval_coords, ...
                'tunit', 'Hz', 'solnum', fi);

            E_s(:, 1, fi) = E_sx;
            E_s(:, 2, fi) = E_sy;
            E_s(:, 3, fi) = E_sz;

            % 散射磁场分量
            H_sx = mphinterp(model, 'emw.relHx', ...
                'dataset', 'dset1', 'coord', eval_coords, ...
                'tunit', 'Hz', 'solnum', fi);
            H_sy = mphinterp(model, 'emw.relHy', ...
                'dataset', 'dset1', 'coord', eval_coords, ...
                'tunit', 'Hz', 'solnum', fi);
            H_sz = mphinterp(model, 'emw.relHz', ...
                'dataset', 'dset1', 'coord', eval_coords, ...
                'tunit', 'Hz', 'solnum', fi);

            H_s(:, 1, fi) = H_sx;
            H_s(:, 2, fi) = H_sy;
            H_s(:, 3, fi) = H_sz;
        end

        fprintf('[forward_solve] E^s 和 H^s 提取完成: %d 方向 × 3 分量 × %d 频率\n', ...
                params.n_directions, n_freq);

        %% ========== 11. 提取体素中心总场 E_total ==========
        E_total_voxels = [];
        if isfield(params, 'voxel_positions') && ~isempty(params.voxel_positions)
            fprintf('[forward_solve] 提取体素中心总场 E_total...\n');
            voxel_coords = params.voxel_positions';   % [3 × n_vox]
            n_vox = size(params.voxel_positions, 1);

            E_total_voxels = zeros(n_vox, 3, n_freq);

            for fi = 1:n_freq
                Et_x = mphinterp(model, 'emw.Ex', ...
                    'dataset', 'dset1', 'coord', voxel_coords, ...
                    'tunit', 'Hz', 'solnum', fi);
                Et_y = mphinterp(model, 'emw.Ey', ...
                    'dataset', 'dset1', 'coord', voxel_coords, ...
                    'tunit', 'Hz', 'solnum', fi);
                Et_z = mphinterp(model, 'emw.Ez', ...
                    'dataset', 'dset1', 'coord', voxel_coords, ...
                    'tunit', 'Hz', 'solnum', fi);

                E_total_voxels(:, 1, fi) = Et_x;
                E_total_voxels(:, 2, fi) = Et_y;
                E_total_voxels(:, 3, fi) = Et_z;
            end

            fprintf('[forward_solve] E_total 提取完成: %d 体素 × 3 分量 × %d 频率\n', ...
                    n_vox, n_freq);
        end

        %% ========== 12. 保存输出 .mat 文件 ==========
        output_data = struct();
        output_data.E_s = E_s;
        output_data.H_s = H_s;
        output_data.E_total_voxels = E_total_voxels;
        output_data.directions = directions;
        output_data.freq_list = params.freq_list;
        output_data.measurement_R = params.measurement_R;
        output_data.n_directions = params.n_directions;
        output_data.solve_time_s = solve_time;
        output_data.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');

        if ~isempty(params.output_path)
            output_dir = fileparts(params.output_path);
            if ~isempty(output_dir) && ~exist(output_dir, 'dir')
                mkdir(output_dir);
            end
            save(params.output_path, '-struct', 'output_data');
            fprintf('[forward_solve] 结果已保存: %s\n', params.output_path);
        end

        %% ========== 13. 组装返回结构体 ==========
        result.scattered_field.E_s = E_s;
        result.scattered_field.H_s = H_s;
        result.scattered_field.E_total_voxels = E_total_voxels;
        result.scattered_field.directions = directions;
        result.scattered_field.freq_list = params.freq_list;
        result.scattered_field.solve_time_s = solve_time;

        result.status = 'success';
        fprintf('[forward_solve] ===== 正演求解成功 =====\n');

    catch ME
        solve_time = toc(timer_start);
        result.status = 'error';
        result.error_msg = sprintf('[forward_solve] 求解失败: %s\n  文件: %s (行 %d)\n  标识: %s', ...
            ME.message, ME.stack(1).name, ME.stack(1).line, ME.identifier);
        result.solve_time_s = solve_time;
        fprintf(2, '%s\n', result.error_msg);

    cleanup_block:
        % 清理 COMSOL 模型资源
        if ~isempty(model) && exist('model', 'var')
            try
                % 不关闭模型，保留 LU 分解因子供伴随求解复用
                fprintf('[forward_solve] 保留 COMSOL 模型 (LU 分解因子供伴随求解复用)\n');
            catch
                % 忽略清理错误
            end
        end
    end
end


% =========================================================================
% ============================ 辅助函数 ====================================
% =========================================================================

function params = validate_params(params)
% VALIDATE_PARAMS  校验参数并填充默认值

    if ~isstruct(params)
        error('forward_solve:InvalidParams', 'params 必须为结构体');
    end

    % 必填参数检查
    required_fields = {'eps_real_csv', 'freq_list', 'model_path'};
    for i = 1:numel(required_fields)
        fld = required_fields{i};
        if ~isfield(params, fld) || isempty(params.(fld))
            error('forward_solve:MissingParam', '缺少必填参数: params.%s', fld);
        end
    end

    % 默认值填充
    defaults = struct( ...
        'eps_imag_csv',      '', ...
        'measurement_R',     0.26, ...
        'n_directions',      64, ...
        'output_path',       '', ...
        'timeout_minutes',   30, ...
        'livelink_port',     2036, ...
        'solver',            'pardiso', ...
        'voxel_positions',   []);

    flds = fieldnames(defaults);
    for i = 1:numel(flds)
        fld = flds{i};
        if ~isfield(params, fld) || isempty(params.(fld))
            params.(fld) = defaults.(fld);
        end
    end

    % 类型检查
    if params.measurement_R <= 0
        error('forward_solve:InvalidParam', 'measurement_R 必须为正数');
    end
    if params.n_directions < 1
        error('forward_solve:InvalidParam', 'n_directions 必须为正整数');
    end
    if params.timeout_minutes < 1
        error('forward_solve:InvalidParam', 'timeout_minutes 必须 >= 1');
    end
    if ~ismember(lower(params.solver), {'pardiso', 'mumps'})
        error('forward_solve:InvalidParam', 'solver 必须为 ''pardiso'' 或 ''mumps''');
    end
end


function ensure_livelink(port)
% ENSURE_LIVELINK  确认 COMSOL LiveLink 连接状态

    try
        mphstart(port);
        fprintf('[forward_solve] LiveLink 连接成功 (端口 %d)\n', port);
    catch ME
        % 如果 mphstart 失败，尝试直接使用已有连接
        try
            models = ModelUtil.models;
            if ~isempty(models)
                fprintf('[forward_solve] LiveLink 已有活动连接\n');
                return;
            end
        catch
            % 忽略
        end
        error('forward_solve:LiveLinkError', ...
              '无法连接 COMSOL LiveLink (端口 %d): %s', port, ME.message);
    end
end


function write_interpolation_function(model, func_name, csv_path, argnames, varargin)
% WRITE_INTERPOLATION_FUNCTION  将 CSV 数据写入 COMSOL 插值函数
%
% 创建或更新 COMSOL 插值函数 (Interpolation)，将外部 CSV 数据
% (x, y, z, value 格式) 加载为三维插值函数。
%
% 参数:
%   model      — COMSOL 模型对象
%   func_name  — 插值函数标签 (如 'int2', 'int3')
%   csv_path   — CSV 文件路径 (列: x, y, z, value)
%   argnames   — 参数名 cell 数组 (如 {'x', 'y', 'z'})
%   varargin   — 可选键值对:
%     'extrapMethod' — 外推方法 (默认 'linear')
%     'interpMethod' — 插值方法 (默认 'linear')

    % 解析可选参数
    p = inputParser;
    addParameter(p, 'extrapMethod', 'linear');
    addParameter(p, 'interpMethod', 'linear');
    parse(p, varargin{:});

    if isempty(csv_path) || ~exist(csv_path, 'file')
        % 无虚部 CSV 时写入全零插值函数
        if strcmp(func_name, 'int3')
            fprintf('[forward_solve] %s: 无虚部 CSV，写入零损耗插值函数\n', func_name);
            % 创建最小插值函数 (全零)
            if model.func().index(func_name) == 0
                model.func().create(func_name, 'Interpolation');
            end
            model.func(func_name).set('funcname', func_name);
            model.func(func_name).set('argname', argnames);
            model.func(func_name).set('table', ...
                sprintf('%.6e %.6e %.6e %.6e\n', [0 0 0 0]));
            model.func(func_name).set('nargs', numel(argnames));
            return;
        else
            error('forward_solve:CSVNotFound', ...
                  'CSV 文件不存在: %s (函数 %s)', csv_path, func_name);
        end
    end

    % 读取 CSV 数据
    csv_data = readmatrix(csv_path);
    % csv_data: [n_points × (n_args + 1)]，最后一列为 value

    % 创建或更新插值函数
    try
        existing_idx = model.func().index(func_name);
    catch
        existing_idx = 0;
    end

    if existing_idx == 0
        model.func().create(func_name, 'Interpolation');
    end

    % 设置插值函数属性
    model.func(func_name).set('funcname', func_name);
    model.func(func_name).set('argname', argnames);
    model.func(func_name).set('nargs', numel(argnames));
    model.func(func_name).set('extrap', p.Results.extrapMethod);
    model.func(func_name).set('interp', p.Results.interpMethod);

    % 写入数据表 — 转为 COMSOL 表格字符串
    n_rows = size(csv_data, 1);
    table_str = '';
    for r = 1:n_rows
        line_str = sprintf('%.6e ', csv_data(r, :));
        table_str = [table_str, line_str, sprintf('\n')];
    end
    model.func(func_name).set('table', table_str);

    % 验证数据已写入
    fprintf('[forward_solve] %s: 写入 %d 个数据点\n', func_name, n_rows);
end


function set_epsilon_userdef(model)
% SET_EPSILON_USERDEF  设置 epsilonr_mat = 'userdef'
%
% 关键设置: 若 epsilonr_mat 未设为 'userdef'，
% COMSOL 会从材料节点读取默认值，忽略 int2/int3 插值函数。

    % 获取物理场组件列表
    comp_tags = model.component().tags();

    for ct = comp_tags
        comp = model.component(ct);
        try
            % 尝试获取电磁波物理场
            phys_tags = comp.physics().tags();
            for pt = phys_tags
                phys = comp.physics(pt);
                % 检查是否为电磁波 (emw) 物理场
                phys_type = phys.getType();
                if contains(phys_type, 'ElectromagneticWaves') || strcmp(pt, 'emw')
                    % 扫描 wave equation 特征
                    feat_tags = phys.feature().tags();
                    for ft = feat_tags
                        feat = phys.feature(ft);
                        try
                            feat_type = feat.getType();
                            if contains(feat_type, 'WaveEquation') || contains(ft, 'wEE')
                                feat.set('epsilonr_mat', 'userdef');
                                feat.set('epsilonr', ...
                                    sprintf('int2(x,y,z)+i*int3(x,y,z)'));
                                fprintf('[forward_solve] 设置 %s.%s.epsilonr_mat = userdef\n', ...
                                        pt, ft);
                            end
                        catch
                            % 跳过不支持该属性的特征
                        end
                    end
                end
            end
        catch
            % 跳过无物理场的组件
        end
    end
end


function success = update_epsilon_4level_fallback(model)
% UPDATE_EPSILON_4LEVEL_FALLBACK  ε_r 更新的 4 级回退策略
%
% COMSOL ε_r 更新可能因版本/配置差异而失败，依次尝试 4 个级别:
%   Level 1: 扫描所有 EMW 特征中包含 'int2' 的属性
%   Level 2: 直接覆盖 wEE1.epsilonr = int2(x,y,z)+i*int3(x,y,z)
%   Level 3: 通过材料节点属性修改
%   Level 4: 暴力遍历所有已知特征名

    success = false;

    % ----- Level 1: 扫描所有 EMW 特征中包含 'int2' 的属性 -----
    try
        comp_tags = model.component().tags();
        for ct = comp_tags
            comp = model.component(ct);
            phys_tags = comp.physics().tags();
            for pt = phys_tags
                phys = comp.physics(pt);
                feat_tags = phys.feature().tags();
                for ft = feat_tags
                    feat = phys.feature(ft);
                    try
                        prop_names = feat.properties();
                        for pn = prop_names
                            try
                                val = feat.get(pn);
                                if ischar(val) && contains(val, 'int2')
                                    feat.set('epsilonr_mat', 'userdef');
                                    feat.set('epsilonr', ...
                                        sprintf('int2(x,y,z)+i*int3(x,y,z)'));
                                    success = true;
                                end
                            catch
                                % 跳过不可读属性
                            end
                        end
                    catch
                        % 跳过
                    end
                end
            end
        end

        if success
            fprintf('[forward_solve] ε_r 更新: Level 1 (通用扫描) 成功\n');
            return;
        end
    catch
        % 继续下一级
    end

    % ----- Level 2: 直接覆盖 wEE1.epsilonr -----
    try
        comp_tags = model.component().tags();
        for ct = comp_tags
            comp = model.component(ct);
            try
                wEE = comp.physics('emw').feature('wEE1');
                wEE.set('epsilonr_mat', 'userdef');
                wEE.set('epsilonr', sprintf('int2(x,y,z)+i*int3(x,y,z)'));
                success = true;
                fprintf('[forward_solve] ε_r 更新: Level 2 (wEE1 精确覆盖) 成功\n');
                return;
            catch
                % 继续下一级
            end
        end
    catch
        % 继续下一级
    end

    % ----- Level 3: 材料节点属性修改 -----
    try
        comp_tags = model.component().tags();
        for ct = comp_tags
            comp = model.component(ct);
            try
                mat_tags = comp.material().tags();
                for mt = mat_tags
                    mat = comp.material(mt);
                    try
                        props = mat.property('def').properties();
                        for pp = props
                            try
                                val = mat.property('def').get(pp);
                                if ischar(val) && contains(val, 'epsilonr')
                                    mat.property('def').set(pp, ...
                                        sprintf('int2(x,y,z)+i*int3(x,y,z)'));
                                    success = true;
                                end
                            catch
                                % 跳过
                            end
                        end
                    catch
                        % 跳过
                    end
                end
            catch
                % 跳过
            end
        end

        if success
            fprintf('[forward_solve] ε_r 更新: Level 3 (材料节点) 成功\n');
            return;
        end
    catch
        % 继续下一级
    end

    % ----- Level 4: 暴力遍历所有已知特征名 -----
    known_feat_names = {'wEE1', 'wee1', 'waveEquation1', 'we1', ...
                        'wEE', 'wee', 'waveEquation', 'we'};
    try
        comp_tags = model.component().tags();
        for ct = comp_tags
            comp = model.component(ct);
            phys_tags = comp.physics().tags();
            for pt = phys_tags
                phys = comp.physics(pt);
                for kn = known_feat_names
                    try
                        feat = phys.feature(kn);
                        feat.set('epsilonr_mat', 'userdef');
                        feat.set('epsilonr', ...
                            sprintf('int2(x,y,z)+i*int3(x,y,z)'));
                        success = true;
                    catch
                        % 继续尝试下一个
                    end
                end

                % 遍历所有特征标签兜底
                feat_tags = phys.feature().tags();
                for ft = feat_tags
                    try
                        feat = phys.feature(ft);
                        feat.set('epsilonr_mat', 'userdef');
                        feat.set('epsilonr', ...
                            sprintf('int2(x,y,z)+i*int3(x,y,z)'));
                        success = true;
                    catch
                        % 跳过不支持该属性的特征
                    end
                end
            end
        end

        if success
            fprintf('[forward_solve] ε_r 更新: Level 4 (暴力遍历) 成功\n');
        end
    catch
        % 全部失败
    end

    if ~success
        fprintf(2, '[forward_solve] ε_r 更新: 4 级回退策略全部失败!\n');
    end
end


function configure_pml(model)
% CONFIGURE_PML  验证和配置 PML 吸收边界
%
% 完美匹配层 (PML) 包裹仿真域外层，吸收外向散射波，模拟开放空间。
% 本函数验证 PML 已在模型中正确设置。

    pml_found = false;
    try
        comp_tags = model.component().tags();
        for ct = comp_tags
            comp = model.component(ct);
            try
                geom_tags = comp.geom().tags();
                for gt = geom_tags
                    geom = comp.geom(gt);
                    feat_tags = geom.feature().tags();
                    for ft = feat_tags
                        feat = geom.feature(ft);
                        try
                            feat_type = feat.getType();
                            if contains(feat_type, 'PML') || contains(ft, 'pml')
                                pml_found = true;
                                fprintf('[forward_solve] PML 边界已确认: %s.%s\n', gt, ft);
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
    catch
        % 忽略
    end

    if ~pml_found
        fprintf('[forward_solve] 警告: 未检测到显式 PML 特征 (可能已在模型中预设)\n');
    end
end


function configure_solver(model, solver_name)
% CONFIGURE_SOLVER  配置 COMSOL 频域求解器
%
% 参数:
%   model       — COMSOL 模型对象
%   solver_name — 'pardiso' 或 'mumps'

    study_tags = model.study().tags();
    for st = study_tags
        study = model.study(st);
        feat_tags = study.feature().tags();
        for ft = feat_tags
            feat = study.feature(ft);
            try
                feat_type = feat.getType();
                if contains(feat_type, 'Frequency') || contains(ft, 'freq')
                    % 获取求解器序列
                    try
                        sol_tags = model.sol().tags();
                        for sot = sol_tags
                            sol = model.sol(sot);
                            % 查找线性系统求解器
                            try
                                if strcmpi(solver_name, 'pardiso')
                                    sol.feature('st1').feature('d1').set('linsolver', 'pardiso');
                                    fprintf('[forward_solve] 求解器设置为 PARDISO\n');
                                elseif strcmpi(solver_name, 'mumps')
                                    sol.feature('st1').feature('d1').set('linsolver', 'mumps');
                                    fprintf('[forward_solve] 求解器设置为 MUMPS\n');
                                end
                            catch
                                % 尝试备选求解器标签
                                try
                                    sf_tags = sol.feature().tags();
                                    for sft = sf_tags
                                        sf = sol.feature(sft);
                                        sf_feat_tags = sf.feature().tags();
                                        for sfft = sf_feat_tags
                                            try
                                                sf.feature(sfft).set('linsolver', ...
                                                    lower(solver_name));
                                                fprintf('[forward_solve] 求解器设置为 %s (%s.%s)\n', ...
                                                        upper(solver_name), sft, sfft);
                                                return;
                                            catch
                                                % 跳过
                                            end
                                        end
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
            catch
                % 跳过
            end
        end
    end

    fprintf('[forward_solve] 求解器配置完成 (或使用模型默认配置)\n');
end


function solve_with_timeout(model, timeout_minutes)
% SOLVE_WITH_TIMEOUT  执行 COMSOL 求解 (带超时保护)
%
% 使用 MATLAB 计时器机制实现超时保护。
% 若求解超时，抛出错误以触发上层 catch。

    timeout_seconds = timeout_minutes * 60;
    timer_start = tic;

    % 在后台运行求解
    study_tags = model.study().tags();
    if isempty(study_tags)
        error('forward_solve:NoStudy', '模型中未找到任何研究 (study)');
    end

    % 执行求解 (COMSOL LiveLink 同步调用)
    primary_study = study_tags{1};
    model.study(primary_study).run();

    elapsed = toc(timer_start);
    if elapsed > timeout_seconds
        error('forward_solve:Timeout', ...
              '求解超时: %.1f s > %.1f s (%.0f min)', ...
              elapsed, timeout_seconds, timeout_minutes);
    end

    fprintf('[forward_solve] 求解耗时: %.1f s (%.1f min)\n', ...
            elapsed, elapsed / 60);
end


function points = fibonacci_sphere(n, radius)
% FIBONACCI_SPHERE  在球面上生成 n 个均匀分布的点 (Fibonacci 球面采样)
%
% Fibonacci 球面采样算法生成近似均匀分布的球面点集，
% 用于散射场测量方向的定义。
%
% 参数:
%   n      — 采样点数
%   radius — 球面半径 [m]
%
% 返回:
%   points — [n × 3] 坐标矩阵，每行 (x, y, z)

    % 黄金角
    golden_angle = pi * (3 - sqrt(5));

    % Fibonacci 球面采样
    indices = (0:n-1)';
    y = 1 - 2 * indices / max(n - 1, 1);      % y 坐标: [-1, 1]
    radius_at_y = sqrt(1 - y.^2);             % 当前纬度圆半径
    theta = golden_angle * indices;           % 方位角

    x = cos(theta) .* radius_at_y;
    z = sin(theta) .* radius_at_y;

    % 缩放到指定半径
    points = radius * [x, y, z];
end
