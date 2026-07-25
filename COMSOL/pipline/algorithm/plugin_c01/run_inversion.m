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
    if ~isfield(p, 'cavity_hybrid_fd_x'), p.cavity_hybrid_fd_x = false; end    % H015: 默认关闭（向后兼容；config.m 设 true 时启用）
    if ~isfield(p, 'cavity_fd_delta_x'),  p.cavity_fd_delta_x = 0.005; end     % H015: x 分量 FD 扰动量 [m]

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
