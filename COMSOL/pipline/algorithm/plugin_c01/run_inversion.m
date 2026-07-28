function state = run_inversion(model, voxel, lc, grid, p)
%RUN_INVERSION C01 插件统一入口
%   支持两种模式：
%     (1) cavity_mode=false（默认）: 原始 C01 复数均匀球反演
%     (2) cavity_mode=true (H012):   均匀主体 + 偏心空洞位置反演
%
%   输入:
%       model   COMSOL 模型对象（须已 mphload）
%       voxel   体素结构（须已 fem_mesh_utils）
%       lc      LightConeData（含 k_dir, dOmega）
%       grid    测量网格
%       p       config（须含 C01 专属参数）
%   输出:
%       state   反演状态

fprintf('========== [plugin_c01] 反演启动 ==========\n');

addpath(fullfile(p.base_path, 'algorithm'));

%% ---- H012: 均匀主体 + 偏心空洞位置反演 ----
if isfield(p, 'cavity_mode') && p.cavity_mode
    fprintf('[plugin_c01] H012 模式: 均匀主体 + 偏心空洞位置反演\n');

    % H012 几何参数默认值
    if ~isfield(p, 'cavity_R_hole'),       p.cavity_R_hole = 0.03; end
    if ~isfield(p, 'cavity_eps_r_true'),   p.cavity_eps_r_true = 5.0; end
    if ~isfield(p, 'cavity_hole_pos_true'),p.cavity_hole_pos_true = [0.03, 0.02, 0.01]; end
    if ~isfield(p, 'cavity_eps_r_init'),   p.cavity_eps_r_init = 3.0; end
    if ~isfield(p, 'cavity_hole_pos_init'),p.cavity_hole_pos_init = [0.0, 0.0, 0.0]; end
    if ~isfield(p, 'cavity_mu_eps_r'),     p.cavity_mu_eps_r = 0.5; end
    if ~isfield(p, 'cavity_mu_hole_pos'),  p.cavity_mu_hole_pos = 0.02; end   % H014: 0.005→0.02
    if ~isfield(p, 'cavity_freqs'),        p.cavity_freqs = [1.0e9]; end
    if ~isfield(p, 'rel_err_floor'),       p.rel_err_floor = 1e-12; end
    if ~isfield(p, 'cavity_fd_check'),      p.cavity_fd_check = false; end      % 管线维护 Round10: 默认关闭（H014 审计已完成）
    if ~isfield(p, 'cavity_fd_check_iter'), p.cavity_fd_check_iter = 1; end     % 管线维护 Round10: FD-check 执行轮次
    if ~isfield(p, 'cavity_fd_delta'),      p.cavity_fd_delta = 0.001; end      % H014: FD 扰动量 [m]
    if ~isfield(p, 'cavity_hybrid_fd_x'), p.cavity_hybrid_fd_x = false; end    % H015: 默认关闭（H017: 由 continuous_bi 替代）
    if ~isfield(p, 'cavity_fd_delta_x'),  p.cavity_fd_delta_x = 0.005; end     % H015: x 分量 FD 扰动量 [m]
    if ~isfield(p, 'cavity_continuous_bi'),    p.cavity_continuous_bi = false; end   % H017: 连续边界积分（默认关闭，config.m 设 true 启用）
    if ~isfield(p, 'cavity_bi_N'),             p.cavity_bi_N = 300; end          % H017: Fibonacci 球面采样点数
    if ~isfield(p, 'cavity_bi_fd_crosscheck'), p.cavity_bi_fd_crosscheck = false; end % H017: FD 符号交叉验证
    if ~isfield(p, 'cavity_h018_dual_component'), p.cavity_h018_dual_component = false; end % H018: 双组件（默认关闭）
    if ~isfield(p, 'cavity_h018_target_step'),     p.cavity_h018_target_step = 0.01; end     % H018 A: 物理位移目标
    if ~isfield(p, 'cavity_h018_target_step_min'), p.cavity_h018_target_step_min = 0.001; end % H018 A: backtracking 下界
    if ~isfield(p, 'cavity_h018_mu_hole_upper'),   p.cavity_h018_mu_hole_upper = 0.05; end   % H018 A: 步长上界
    if ~isfield(p, 'cavity_h018_near_zero_grad'),  p.cavity_h018_near_zero_grad = 1e-12; end % H018 A: 近零梯度守卫
    if ~isfield(p, 'cavity_convergence_decouple'), p.cavity_convergence_decouple = false; end % Round14 A-03: 收敛判据解耦（默认关闭）
    if ~isfield(p, 'cavity_hole_stable_tol'),     p.cavity_hole_stable_tol = 0.05; end      % Round14 A-03: hole_pos 稳定性阈值（相对变化率 5%）
    if ~isfield(p, 'cavity_h019_multi_obj_q'),  p.cavity_h019_multi_obj_q = false; end    % H019: 多目标 Q 判据（默认关闭）
    if ~isfield(p, 'cavity_h019_w_cos'),        p.cavity_h019_w_cos = 0.4; end            % H019: Q 权重 cos θ
    if ~isfield(p, 'cavity_h019_w_hole'),       p.cavity_h019_w_hole = 0.4; end           % H019: Q 权重 hole_err
    if ~isfield(p, 'cavity_h019_w_eps'),        p.cavity_h019_w_eps = 0.2; end            % H019: Q 权重 eps_r_err
    if ~isfield(p, 'cavity_h019_hole_err_ref'), p.cavity_h019_hole_err_ref = 0.037; end   % H019: hole_err 归一化参考 [m]
    if ~isfield(p, 'cavity_h019_eps_r_ref'),    p.cavity_h019_eps_r_ref = 1.0; end        % H019: eps_r_err 归一化参考
    if ~isfield(p, 'cavity_h020_dual_gate'),                p.cavity_h020_dual_gate = false; end             % H020: 双门独立收敛（默认关闭）
    if ~isfield(p, 'cavity_h020_hole_stability_window'),    p.cavity_h020_hole_stability_window = 2; end      % H020 Gate B: hole_err 稳定性滑窗（连续轮数）
    if ~isfield(p, 'cavity_h020_hole_stability_threshold'), p.cavity_h020_hole_stability_threshold = 0.10; end % H020 Gate B: hole_err 变化率阈值 10%
    if ~isfield(p, 'cavity_h021_eps_r_freeze'),          p.cavity_h021_eps_r_freeze = false; end          % H021: eps_r 冻结（默认关闭，config.m 设 true 启用）
    if ~isfield(p, 'cavity_h021_dF_earlystop'),          p.cavity_h021_dF_earlystop = false; end          % Round17: dF 机器精度早停（默认关闭，config.m 设 true 启用）
    if ~isfield(p, 'cavity_h021_dF_machine_eps'),        p.cavity_h021_dF_machine_eps = 1e-10; end        % Round17: 机器精度阈值（|dF|<此值判定为离散化不敏感）
    if ~isfield(p, 'cavity_h021_dF_rel_threshold'),      p.cavity_h021_dF_rel_threshold = 0.005; end       % Round19: dF 相对阈值（|dF|/F_old<此值判定为低效步）
    if ~isfield(p, 'cavity_h022_sdf'),                   p.cavity_h022_sdf = true; end                    % H022: SDF 软边界 epsilon 映射（默认开启，config.m 已设 true）
    if ~isfield(p, 'cavity_h022_sdf_delta'),             p.cavity_h022_sdf_delta = 0.008; end             % H022: 软边界半宽 δ [m]
    if ~isfield(p, 'cavity_h022_sysreject_earlystop'),  p.cavity_h022_sysreject_earlystop = false; end   % Round18: 系统性 reject 早停（默认关闭，config.m 设 true 启用）
    if ~isfield(p, 'cavity_h022_sysreject_N'),          p.cavity_h022_sysreject_N = 4; end               % Round18: 连续同号 reject 阈值（达到即 break）
    if ~isfield(p, 'cavity_h022_sysreject_dF_floor'),   p.cavity_h022_sysreject_dF_floor = 1e-8; end     % Round18: dF 物理量级下限（|dF|<此值不计数，与 Round17 缓冲）
    if ~isfield(p, 'cavity_h023_sdf_aware'),          p.cavity_h023_sdf_aware = true; end              % H023: SDF-aware 伴随体积积分（默认开启，config.m 已设 true）
    if ~isfield(p, 'cavity_h023_transition_factor'), p.cavity_h023_transition_factor = 2.0; end        % H023: 过渡带半宽因子（|d_i|<factor·δ 内计算梯度）
    if ~isfield(p, 'cavity_h024_diagnostic'),    p.cavity_h024_diagnostic = false; end   % H024: 梯度诊断分解（默认关闭，config.m 设 true 启用）
    if ~isfield(p, 'cavity_h024_diag_iter'),     p.cavity_h024_diag_iter = 2; end        % H024: 诊断执行迭代轮
    if ~isfield(p, 'cavity_h024_l1_delta'),      p.cavity_h024_l1_delta = 1e-6; end      % H024 L1: 链式法则数值差分步长 [m]
    if ~isfield(p, 'cavity_h024_l2_n_voxels'),   p.cavity_h024_l2_n_voxels = 6; end      % H024 L2: 代表性体素数
    if ~isfield(p, 'cavity_h024_l2_delta_eps'),  p.cavity_h024_l2_delta_eps = 0.01; end  % H024 L2: ε_i 微扰量
    if ~isfield(p, 'cavity_h025_residual_gap'), p.cavity_h025_residual_gap = true; end   % H025: residual_gap_monitoring（默认开启，复用 H024 L2 born_ratio 零额外正演）
    if ~isfield(p, 'cavity_h025_l2_cache'),      p.cavity_h025_l2_cache = true; end      % Round20: L2 诊断跨实验缓存（默认开启，命中跳过冗余正演）

    % 输出目录
    if ~isfield(p, 'dir_result_C01')
        p.dir_result_C01 = fullfile(p.dir_result, 'C01_cavity');
        if ~exist(p.dir_result_C01, 'dir'), mkdir(p.dir_result_C01); end
    end

    state = C01_cavity_inversion_loop(voxel, lc, grid, model, p);

    fprintf('========== [plugin_c01] H012 反演完成 ==========\n');
    fprintf('  eps_r=%.4f, hole=[%.4f,%.4f,%.4f], pos_err=%.4fm, converged=%d\n', ...
        state.eps_r_body, state.hole_pos(1), state.hole_pos(2), state.hole_pos(3), ...
        state.hole_position_error, state.converged);
    return;
end

%% ---- 原始 C01: 复数均匀球反演 ----
fprintf('[plugin_c01] 原始模式: 复数均匀球反演\n');

% C01 专属参数默认值
if ~isfield(p, 'n_cx'), p.n_cx = 2; end
if ~isfield(p, 'n_cy'), p.n_cy = 3; end
if ~isfield(p, 'n_cz'), p.n_cz = 4; end
if ~isfield(p, 'bspline_order'), p.bspline_order = 3; end
if ~isfield(p, 'lambda_tv'), p.lambda_tv = 0.0; end
if ~isfield(p, 'rel_err_floor'), p.rel_err_floor = 1e-12; end

% C01 单频
freqs = [1.0e9];
N_freq = length(freqs);

%% B-spline 参数化算子
B_op = exp07a_bspline_param(voxel, p);
N_c = size(B_op, 2);
c_init = (4.0 - 4.0j) * ones(N_c, 1);  % C01 复数冷启动

%% 预计算 J_obs（复数真值 eps_r = 5.0 - 5.0j）
J_obs_perp_multi = cell(1, N_freq);
for fi = 1:N_freq
    p_freq = p;
    p_freq.freq = freqs(fi);
    p_freq.omega = 2*pi*p_freq.freq;
    p_freq.k0 = p_freq.omega / p_freq.c;
    p_freq.lambda = p_freq.c / p_freq.freq;

    voxel.epsilon_r(voxel.mask_interior) = 5.0 - 5.0j;
    [E_total, ~, ~] = solve_forward(model, voxel, p_freq);
    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, p_freq);
    J_obs_perp_multi{fi} = lc_obs.J_obs_perp;
end

%% 调用 C01 反演主循环
state = C01_inversion_loop(voxel, lc, J_obs_perp_multi, freqs, grid, model, p, B_op, c_init);

fprintf('========== [plugin_c01] 反演完成 ==========\n');
fprintf('  最终残差: %.6e, 收敛: %d\n', state.residual, state.converged);

end
