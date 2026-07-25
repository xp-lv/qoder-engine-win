function state = run_inversion(model, voxel, lc, grid, p)
%RUN_INVERSION A12 插件统一入口
%   将 A12_multi_freq_inversion 的核心逻辑封装为统一签名
%
%   输入:
%       model   COMSOL 模型对象（须已 mphload）
%       voxel   体素结构（须已 fem_mesh_utils）
%       lc      LightConeData（含 k_dir, dOmega）
%       grid    测量网格
%       p       config（须含 A12 专属参数）
%   输出:
%       state   反演状态（含 history_residual, epsilon_r, converged 等）

fprintf('========== [plugin_a12] 反演启动 ==========\n');

% A12 专属参数默认值
if ~isfield(p, 'n_cx'), p.n_cx = 10; end
if ~isfield(p, 'n_cy'), p.n_cy = 10; end
if ~isfield(p, 'n_cz'), p.n_cz = 5; end
if ~isfield(p, 'bspline_order'), p.bspline_order = 3; end
if ~isfield(p, 'lambda_tv'), p.lambda_tv = 1e-4; end
if ~isfield(p, 'rel_err_floor'), p.rel_err_floor = 1e-12; end

% H002: 自适应早停软闸门（若 config.m 未指定则启用默认值，与假设链 early_stop_config 对齐）
if ~isfield(p, 'early_stop_enabled'),         p.early_stop_enabled = true; end
if ~isfield(p, 'early_stop_window'),          p.early_stop_window = 3; end
if ~isfield(p, 'early_stop_rel_improvement'), p.early_stop_rel_improvement = 0.005; end
if ~isfield(p, 'early_stop_monitor'),         p.early_stop_monitor = 'residual_history'; end
if ~isfield(p, 'early_stop_action'),          p.early_stop_action = 'break_and_set_converged_true'; end

% A12 专属输出目录
if ~isfield(p, 'dir_result_A12')
    p.dir_result_A12 = fullfile(p.dir_result, 'A12');
    if ~exist(p.dir_result_A12, 'dir'), mkdir(p.dir_result_A12); end
end
p.max_iter = 10;   % H002: 硬上界安全网（早停软闸门触发后的兆底，保持 10 不变以隔离迭代策略变量）
p.eps_tol = 1e-6;  % A12 数据残差硬收敛阈值（与 H001 一致，隔离变量）

freqs = [1e9, 2e9, 3e9];
N_freq = length(freqs);

%% B-spline 参数化算子
addpath(fullfile(p.base_path, 'algorithm'));
B_op = exp07a_bspline_param(voxel, p);
N_c = size(B_op, 2);
c_init = 4.0 * ones(N_c, 1);

%% 预计算各频率的 J_obs
N_k = size(lc.k_dir, 1);
J_obs_perp_multi = cell(1, N_freq);
for fi = 1:N_freq
    p_freq = p;
    p_freq.freq = freqs(fi);
    p_freq.omega = 2*pi*p_freq.freq;
    p_freq.k0 = p_freq.omega / p_freq.c;
    p_freq.lambda = p_freq.c / p_freq.freq;

    voxel.epsilon_r(voxel.mask_interior) = 5.0;
    [E_total, ~, ~] = solve_forward(model, voxel, p_freq);
    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, p_freq);
    J_obs_perp_multi{fi} = lc_obs.J_obs_perp;
end

%% 调用 A12 反演主循环
state = A12_inversion_loop(voxel, lc, J_obs_perp_multi, freqs, grid, model, p, B_op, c_init);

fprintf('========== [plugin_a12] 反演完成 ==========\n');
fprintf('  最终残差: %.6e, 收敛: %d\n', state.residual, state.converged);

end
