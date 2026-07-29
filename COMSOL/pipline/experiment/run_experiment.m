function state = run_experiment(plugin_name)
%RUN_EXPERIMENT 统一反演实验调度入口
%   state = run_experiment('plugin_a12')
%   state = run_experiment('plugin_basic')
%   state = run_experiment('plugin_c01')
%   state = run_experiment()  % 使用 config.m 中的 p.inversion_plugin
%
%   此脚本是 M3 实验执行者的统一调用入口：
%   1. setup + config + mphstart + mphload
%   2. fem_mesh_utils 提取体素
%   3. 设真值 eps_r
%   4. solve_forward 正演
%   5. extract_scattered + lightcone_project 计算 J_obs
%   6. fibonacci_sphere 构建光锥方向
%   7. 加载插件目录，调用 run_inversion(model, voxel, lc, grid, p)
%
%   插件随插随用：
%   - 新建 algorithm/plugin_xxx/run_inversion.m 即可
%   - 在 config.m 中设 p.inversion_plugin = 'plugin_xxx'
%   - 或直接传参 run_experiment('plugin_xxx')

if nargin < 1 || isempty(plugin_name)
    p_tmp = config();
    if isfield(p_tmp, 'inversion_plugin')
        plugin_name = p_tmp.inversion_plugin;
    else
        error('run_experiment:no_plugin', '请指定插件名或 在 config.m 中设置 p.inversion_plugin');
    end
end

fprintf('\n');
fprintf('=========================================================\n');
fprintf('  run_experiment — 插件化反演实验                          \n');
fprintf('  Plugin: %-48s\n', plugin_name);
fprintf('=========================================================\n\n');

%% Step 0: 初始化
setup();
p = config();
if ~isfield(p, 'rel_err_floor')
    p.rel_err_floor = 1e-12;
end

fprintf('[Step 0] pipline root: %s\n', p.base_path);
fprintf('[Step 0] Plugin: %s\n', plugin_name);

%% Step 1: COMSOL LiveLink
fprintf('\n=== Step 1: COMSOL LiveLink ===\n');
% [管线维护 H029-P0] COMSOL Server 存活性预检查
% mphstart 在 Server 未启动时抛出晦涩的 Java ConnectException，实验执行者易误判为代码 bug。
% 此处在 mphstart 前探测端口连通性，给出明确的中文错误提示。
% [管线维护 H031-P0] 错误提示新增辅助脚本指引（start_comsol_server.ps1），
% 消除实验执行者手动查找 comsolmphserver.exe 路径的摩擦（H029-H031 连续 3 次实验遇到此问题）。
% （逆散射规范第 5 节：COMSOL Server 需独立终端长期运行于 port 2036）
try
    comsol_sock = java.net.Socket('localhost', p.comsol_port);
    comsol_sock.close();
catch
    error('run_experiment:comsol_server_down', ...
        ['COMSOL Server 未在 localhost:%d 运行。\n', ...
         '请先在独立终端启动：comsolmphserver.exe -port %d（需长期运行，非临时启动）。\n', ...
         '或使用辅助脚本（自动探测安装路径 + 后台启动 + 等待就绪）：\n', ...
         '  powershell -ExecutionPolicy Bypass -File experiment/start_comsol_server.ps1\n', ...
         '（此为 mphstart 前的预检查，避免 mphstart 抛出 Java ConnectException 造成误判）'], ...
         p.comsol_port, p.comsol_port);
end
fprintf('[Step 1] COMSOL Server alive on port %d\n', p.comsol_port);
try
    mphstart(p.comsol_port);
catch ME
    if ~contains(ME.message, 'Already connected')
        rethrow(ME);
    end
end
model = mphload(p.comsol_model_path);
fprintf('[Step 1] Model loaded: %s\n', p.comsol_model_path);

%% Step 2: FEM mesh
fprintf('\n=== Step 2: fem_mesh_utils ===\n');
voxel = fem_mesh_utils(model, p, p.a_scatter);
N_v = length(voxel.epsilon_r);
N_in = sum(voxel.mask_interior);
fprintf('[Step 2] Total elements: %d, Inner: %d\n', N_v, N_in);

%% Step 3: 设真值 eps_r
if isfield(p, 'cavity_eps_r_true')
    voxel.epsilon_r(voxel.mask_interior) = p.cavity_eps_r_true;
    fprintf('[Step 3] Inner eps_r set to %s\n', num2str(p.cavity_eps_r_true));
else
    voxel.epsilon_r(voxel.mask_interior) = 5.0;
    fprintf('[Step 3] Inner eps_r set to 5.0 (default)\n');
end

%% Step 4: 正演求解
fprintf('\n=== Step 4: solve_forward ===\n');
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
fprintf('[Step 4] |E| mean=%.4e\n', mean(abs(E_total(:,1))));

%% Step 5: J_obs（COMSOL 表面等效定理）
fprintf('\n=== Step 5: J_obs (surface equivalent) ===\n');
grid = build_measurement_grid(p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
fprintf('[Step 5] |J_obs| mean=%.4e\n', mean(vecnorm(lc.J_obs_perp, 2, 2)));

%% Step 6: 光锥方向
lc.k_dir = fibonacci_sphere(p.N_k);
lc.k_vec = p.k0 * lc.k_dir;

%% Step 7: 加载插件并运行反演
fprintf('\n=== Step 6: Load plugin and run inversion ===\n');
plugin_dir = fullfile(p.base_path, 'algorithm', plugin_name);
if ~exist(plugin_dir, 'dir')
    error('run_experiment:plugin_not_found', ...
        '插件目录不存在: %s\n请在 algorithm/ 下创建 %s/run_inversion.m', ...
        plugin_dir, plugin_name);
end
addpath(plugin_dir);
fprintf('[Step 6] Plugin loaded: %s\n', plugin_dir);

state = run_inversion(model, voxel, lc, grid, p);

%% Step 8: 输出三件套
fprintf('\n=== Step 7: Three-piece metrics ===\n');

% H012 兼容：如果插件在内部重新定义了 truth phantom（如 cavity_mode），
% 则使用 state.J_obs_truth 作为三件套的 J_obs 基准（而非 Step 5 的均匀球 J_obs）
if isfield(state, 'J_obs_truth') && ~isempty(state.J_obs_truth)
    J_obs_eval = state.J_obs_truth;
    fprintf('  [Three-piece] 使用 state.J_obs_truth (插件内部 truth)\n');
else
    J_obs_eval = lc.J_obs_perp;
end

% cos θ（J_obs vs J_hyp 方向一致性）
if isfield(state, 'history_J_hyp') && size(state.history_J_hyp, 3) >= 1
    J_hyp_final = state.history_J_hyp(:, :, end);
elseif isfield(state, 'history_J_hyp') && ndims(state.history_J_hyp) == 2
    J_hyp_final = state.history_J_hyp;
else
    J_hyp_final = J_obs_eval;
end
cos_theta = mean(dot(J_obs_eval, J_hyp_final, 2) ./ ...
    (vecnorm(J_obs_eval, 2, 2) .* max(vecnorm(J_hyp_final, 2, 2), 1e-60)));
fprintf('  cos theta (mean): %.6f\n', cos_theta);

% F_cheb（Chebyshev 残差）
F_k = sum(abs(J_obs_eval - J_hyp_final).^2, 2) ./ ...
      max(sum(abs(J_obs_eval).^2, 2), p.rel_err_floor) / 6;
F_cheb = p.chebyshev_eta * max(F_k) + (1 - p.chebyshev_eta) * mean(F_k);
fprintf('  F_cheb: %.6f\n', F_cheb);

% 收敛信息
fprintf('  Converged: %d, Iterations: %d, Final residual: %.6e\n', ...
    state.converged, state.iteration, state.residual);

fprintf('\n=========================================================\n');
fprintf('  Experiment complete (plugin: %s)\n', plugin_name);
fprintf('=========================================================\n');

end
