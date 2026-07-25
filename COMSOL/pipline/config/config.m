function p = config()
%CONFIG 全局参数配置（inverse_SCATTER2.0）
%   Usage: p = config()
%   所有参数集中管理，按功能域分组。

%% ---- 物理常数 ----
p.c       = 299792458;            % 真空光速 m/s
p.eps0    = 8.854187817e-12;      % 真空介电常数 F/m
p.mu0     = 4*pi*1e-7;            % 真空磁导率 H/m
p.eta0    = sqrt(p.mu0/p.eps0);   % 自由空间波阻抗 ~377 Ohm

%% ---- 频率 ----
p.freq     = 1e9;                 % 工作频率 1 GHz
p.omega    = 2*pi*p.freq;         % 角频率
p.k0       = p.omega / p.c;       % 自由空间波数
p.lambda   = p.c / p.freq;        % 波长

%% ---- 背景场配置 ----
% type: 'planewave' | 'gaussian'
% 平面波参数
p.background.type        = 'planewave';
p.background.amplitude   = 1.0;       % 振幅 V/m
p.background.polarization = [0, 0, 1]; % polarization (matches COMSOL model: E along Z)
p.background.k_direction  = [1, 0, 0]; % propagation direction (matches COMSOL model: k along X)
% 高斯波束额外参数（type='gaussian' 时生效）
p.background.waist       = 0.1;       % 束腰半径 m
p.background.focus       = [0, 0, 0]; % 焦斑位置 [x,y,z] m

%% ---- 测量球面（S21 采样网格）----
p.R_sphere  = 0.26;                % 测量球面半径 m（匹配 mph intS(D) 积分面）
p.N_theta   = 48;                  % theta 采样数（非均匀）
p.N_phi     = 96;                  % phi 采样数（均匀）
p.N_surface = p.N_theta * p.N_phi; % = 4608 个采样点

%% ---- k 空间光锥采样 ----
p.N_k       = 64;                  % 光锥方向采样数

%% ---- 散射体与体素 ----
p.a_scatter  = 0.13;               % 散射体球半径 m
p.voxel_size = 0.01;               % 体素边长 ~lambda/30 m

%% ---- 迭代参数（伴随法）----
p.max_iter     = 10;               % 最大迭代次数
p.eps_tol      = 0.2;              % 残差收敛阈值（Born 残差底线 ~0.11）
p.mu_init      = 0.15;             % 梯度下降初始步长（H003: 0.05→0.15，3倍以打破H002残差冻结死锁，使Δ控制点系数>mphinterp数值灵敏度阈值）
p.mu_min       = 1e-6;             % 线搜索最小步长
p.mu_max       = 0.5;              % 线搜索最大步长
p.ls_decay     = 0.5;              % 线搜索步长衰减因子
p.ls_armijo    = 0.1;              % Armijo 条件系数（B03 未用,保留兼容）
p.ls_max_trials = 8;               % 线搜索最大尝试次数

%% ---- H004/H005: Zhang-Hager 非单调线搜索参数 ----
% H004: 将 plugin_a12 A12_linesearch.m 中 Armijo 单调回溯替换为 Zhang-Hager 非单调：
%   接受准则由 f(x_k+αd) ≤ f(x_k)+c₁·α∇fᵀd 放宽为 f(x_k+αd) ≤ R_k+c₁·α∇fᵀd，
%   其中 R_k = η_ls·R_{k-1}+(1-η_ls)·f(x_k) 为近期残差衰减加权平均。
%   理论收敛保证：Zhang & Hager 2004。
% H005: 收紧 Zhang-Hager 两个核心参数（相对 H004 的唯一变更点）：
%   - c1: 0.0001→0.01（100 倍收紧，恢复至标准 Armijo 充分下降常数 [0.01,0.1] 下界）。
%     H004 c1=0.0001 过度宽松（下降项 c1·μ·||g||² ≈ 2.5e-7 可忽略），导致 uphill 步被接受、
%     控制点配置漂移、cos θ 从 0.671 崩塌至 -0.087。c1=0.01 使下降项 ≈ 2.5e-5，具备实际约束力。
%   - η_ls: 0.85→0.7（有效记忆窗口从 ~7 步缩短至 ~3.3 步，加速 R_k 向当前残差收敛）。
%     H004 η_ls=0.85 衰减过慢（5 步后仍保留 44% 初始值），对残差上升容忍窗口过大。
%   两者协同：保留非单调逃离驻点能力的同时抑制过度游走。预期 cos θ 恢复至 ≥0.5。
p.ls_strategy         = 'armijo_monotone';           % H007: 回退至 H003 Armijo 单调（cos θ=0.671 迄今最优基线；ZH η_ls=0 退化为纯单调）
p.ls_nonmonotone_eta  = 0.0;                         % H007: η_ls=0 → R_ref=F_cheb 恒等，ZH 非单调退化为 Armijo 单调接受准则
p.ls_armijo_c1        = 0.0001;                      % H007: Armijo c1 系数（与 H007 optimization_config 一致；H003 基线宽松 Armijo）
p.ls_mu_floor         = 1e-4;                        % H005-fix 保留: micro-step 早停阈值（效率优化，不改变算法接受准则，独立于 H007 变量）
%% ---- A12 B-spline 参数化 + TV 正则化（H007 核心变更）----
% H007 唯一实质变更：λ_tv 0.01→0.024（2.4 倍增强 TV 正则化），改善 Jacobian 条件数以提升梯度方向可靠性。
% B-spline 密度 K=75（n_cx=5, n_cy=5, n_cz=3）与 H003 完全一致，隔离正则化单一变量。
% λ=0.024 推导：若 H006 将 K 从 75 提升至 180（2.4 倍），则等效 λ 缩放为 0.01×180/75=0.024 维持每自由度约束力。
p.n_cx       = 5;       % B-spline x 方向控制点数（H003 基线 K=75 = 5×5×3）
p.n_cy       = 5;       % B-spline y 方向控制点数
p.n_cz       = 3;       % B-spline z 方向控制点数
p.lambda_tv  = 0.024;   % H007: TV 正则化强度（H003 基线 0.01→0.024，2.4 倍增强）

p.grad_clip    = 10.0;             % 梯度硬截断上限
p.step_cap     = 0.5;              % per-component 步长上限 (B03 simple descent)
p.alpha_reweight = 1.0;            % 逐k重加权指数 (0=均匀, 0.5=温和, 1=线性, 2=强力)

%% ---- 自适应早停软闸门 (H002: adaptive early stopping) ----
% 替代固定 max_iter 硬终止策略：迭代循环中监控残差停滞并自动终止。
% 触发条件：滑动窗口 W 内连续 W 个相对残差改善率 |Δr|/r 全部低于停滞阈值 δ。
% max_iter 仍保留为硬上界安全网（防发散兜底）。
% 注意：state.iteration 反映实际终止轮数（早停触发轮 或 max_iter），而非恒为 max_iter。
p.early_stop_enabled             = false;   % H003/H004: 保持关闭（H003 隔离步长变量；H004 隔离线搜索单一变量，固定 max_iter=10）
p.early_stop_window              = 3;       % 滑动窗口 W：检查连续 W 个改善率
p.early_stop_rel_improvement     = 0.005;   % 停滞阈值 δ：改善率 < δ 视为停滞 (0.5%)
p.early_stop_monitor             = 'residual_history';                              % 监控指标（残差历史）
p.early_stop_action              = 'break_and_set_converged_true';                  % 终止动作

%% ---- exp69 v1 per-k 加权（2026-06-10 集成，默认关闭保 50 个老 exp 零影响）----
% weight_strategy: 'uniform'(老路径,等价旧行为)| 'adaptive'(exp69 v1,per-k 自适应加权)
%  - 'uniform':  走 build_adjoint_source.m,dOmega 不变 → 与 8 个 success exp 数值一致
%  - 'adaptive': 走 per_k_weighted_adjoint_source.m,dOmega -> w_k.*dOmega,w_k=1/F_k^p
p.weight_strategy       = 'uniform';   % 默认 'uniform'(老行为),新实验用 'adaptive' 或 'chebyshev'
p.weight_min            = 0.01;        % 自适应权重下限(防爆)
p.weight_max            = 100.0;       % 自适应权重上限(防爆)
p.weight_update_interval = 1;          % 每 N 轮重算 w_k(1=每轮,3=按 ADR-005 §2.1 隔轮)

%% ---- exp03 chebyshev_v2 加权 (2026-06-11 新增) ----
% chebyshev_v2: min max F_k + 软最大化 EMA, plan §3.2
%  - weight_strategy='chebyshev' 时, build_adjoint_source 仍走 uniform 路径
%    (8 个 success exp 兼容), 但 cost 计算用 chebyshev 软最大化:
%    F_cheb = η·max(F_k) + (1-η)·mean(F_k), F_cheb_ema = α·F_cheb + (1-α)·F_cheb_ema_prev
%  - V5 等价性预检验 (用户新增, plan §3.2 ③.bis): 每轮 64k 上算
%    F_k = |J_obs_perp - J_hyp_perp|²/|J_obs_perp|², 检查 max F_k < tol_equivalence,
%    不通过则立即停止反演 (state.stop_reason='V5_equivalence_failed')
p.chebyshev_eta        = 0.1;         % 切比雪夫软最大化系数 (max F_k 权重)
p.chebyshev_ema_alpha  = 0.3;         % EMA 平滑系数
p.tol_equivalence      = 1.0e-3;      % V5 等价性预检验阈值 (max F_k 上限)

%% ---- ε_r 物理约束 ----
p.eps_r_min  = 1.0;                % ε_r 实部下界
p.eps_r_max  = 50.0;               % ε_r 实部上界
p.eps_r_imag_max = 20.0;           % ε_r 虚部上界（损耗）

%% ---- 数值保护 ----
p.E_threshold = 1e-6;              % 除法 E 场阈值 V/m
p.F_obs_min   = 1e-60;             % F_obs 最小值防零除

%% ---- 项目根路径（pipline 自包含：此脚本所在目录的上级 = pipline/）----
p.base_path = fileparts(fileparts(mfilename('fullpath')));

%% ---- COMSOL LiveLink ----
p.comsol_port       = 2036;        % LiveLink 通信端口
% 模型文件位于 pipline 父目录（COMSOL/livelink_model.mph），pipline 自包含引用
p.comsol_model_path = fullfile(p.base_path, '..', 'livelink_model.mph');
if ~exist(p.comsol_model_path, 'file')
    error('config:ModelNotFound', 'COMSOL 模型文件不存在: %s', p.comsol_model_path);
end

%% ---- 数据路径（pipline 内部，首次运行自动创建）----
p.dir_data   = fullfile(p.base_path, 'data');
p.dir_raw    = fullfile(p.dir_data, 'raw');
p.dir_result = fullfile(p.dir_data, 'results');
p.dir_live   = fullfile(p.dir_result, 'live');
p.dir_recon  = fullfile(p.dir_data, 'reconstructed');
% 自动创建数据目录（pipline 自包含）
for d = {p.dir_data, p.dir_raw, p.dir_result, p.dir_live, p.dir_recon}
    if ~exist(d{1}, 'dir'), mkdir(d{1}); end
end

%% ---- 真值验证阈值（迭代前强制校验 J_obs ≈ J_hyp）----
p.truth_verify_ratio_range = [0.85, 1.15];  % |J_hyp|/|J_obs| 允许范围
p.truth_verify_corr_min    = 0.95;          % per-k 向量相关性下限

%% ---- 可视化 ----
p.viz_enabled         = true;      % 是否启用实时可视化
p.viz_save_screenshots = true;     % 是否保存每轮迭代截图

%% ---- H012: 均匀主体 + 偏心空洞位置反演（plugin_c01 扩展）----
% H012 核心几何：均匀主体 R=0.13m（ε_r 均匀）+ 偏心空洞（固定大小，位置待反演）
% 参数从 B-spline 75 控制点降至 3~4 参数（ε_r + 空洞位置 x,y,z）。
% 启用后 plugin_c01 进入 cavity_mode，调用 C01_cavity_inversion_loop。
p.cavity_mode          = true;       % H012: 启用 body+cavity 参数化
p.cavity_R_hole        = 0.03;       % 空洞半径 [m]（固定先验，~1 个介质波长）
p.cavity_eps_r_true    = 5.0;        % 主体真值 ε_r（用于生成 J_obs）
p.cavity_hole_pos_true = [0.03, 0.02, 0.01]; % 真值空洞中心 [m]（偏心）
p.cavity_eps_r_init    = 3.0;        % 反演初始猜测 ε_r
p.cavity_hole_pos_init = [0.0, 0.0, 0.0];     % 反演初始猜测空洞中心 [m]
p.cavity_mu_eps_r      = 0.5;        % ε_r 步长（材料梯度独立归一化）
p.cavity_mu_hole_pos   = 0.02;       % H014: 位置步长 0.005→0.02（4倍，吸收效率建议 A-02；配合梯度方向修正加速 hole 收敛，原 0.005 相对需位移 0.037m 过小 7 倍）
p.cavity_freqs         = [1.0e9];    % H012 单频 1 GHz

%% ---- H014: 有限差分位置梯度方向审计（plugin_c01 内部诊断，可配置）----
% H014 核心改动：在 cavity_fd_check_iter 指定的迭代轮对 hole_pos 施加 ±delta 中心差分扰动
% （6 次额外正演），计算数值参考梯度 g_FD=∂F/∂p，与解析 shape derivative 位置梯度逐分量比较方向一致性。
% 诊断目标：确认 g_pos 是否编码下降方向 -∂F/∂p（与 g_eps 约定一致）。
% 物理推导表明原公式 +jump_eps/dr·Σ g_bnd·n_x 实为 +∂F/∂p（上升方向），
% 需取负号才是下降方向。FD 审计提供数值确认。
%
% 【管线维护 Round10 / H014 实验效率建议】FD-check 默认关闭。
%   H014 已完成梯度方向审计（conclusion=confirmed_bug_fixed），后续实验无需重复 FD-check，
%   每次可节省 ~15-19% 诊断耗时（6 次额外 COMSOL 正演，~120-180s）。
%   仅在假设显式要求梯度方向验证时手动设为 true。
p.cavity_fd_check      = false;      % 默认关闭（H014 审计已完成）；true=启用 FD 方向审计
p.cavity_fd_check_iter = 1;          % 在第 N 轮迭代执行 FD-check（默认 1，向后兼容）
p.cavity_fd_delta      = 0.001;      % FD 中心差分扰动量 [m]（~体素尺寸 1/10，平衡数值精度与扰动信号）

%% ---- H015: 混合位置梯度策略（hybrid_analytical_fd）----
% H015 核心改动：y/z 分量保留 H014 解析 shape derivative 梯度（FD-check 已验证方向正确），
%   x 分量将解析梯度替换为中心有限差分梯度（δ_x=0.005m，跨越体素边界）。
% 根因：H014 FD-check 揭示 x 方向解析梯度为伪信号（g_FD_x≈0 而 g_analytical_x=9.83e6），
%   voxel 级几何方案下 δ=1e-3m 微扰不触发 x 方向 cavity_mask 变更（体素 ~0.02-0.05m），
%   边界积分退化为数值噪声。δ_x=0.005m=1/4 体素下界，确保 ≥1 个边界体素归属翻转。
% 成本：每迭代 2 次额外正演（x+δ_x, x−δ_x），max_iter=10 共 20 次额外正演（~20-40min 增量）。
p.cavity_hybrid_fd_x   = true;       % H015: 启用 x 分量有限差分梯度（混合策略）
p.cavity_fd_delta_x    = 0.005;      % H015: x 分量 FD 中心差分扰动量 [m]（1/4 体素下界）
p.cavity_fd_delta_x_fallback = 0.01;  % H015 Round11 P-01: FD fallback 升级 δ_x [m]（|g_FD_x| < min_magnitude 时触发自动升级重算）
p.cavity_fd_x_min_magnitude  = 1e4;   % H015 Round11 P-01: g_FD_x 最小有效量级阈值（低于此值视为伪信号，触发 δ_x 升级）

%% ---- 反演算法插件（随插随用）----
% 通过 run_experiment.m 统一调度，切换此参数即可更换算法
% 可用插件：
%   'plugin_basic'  - 基础伴随梯度法（core_inversion/inversion_loop）
%   'plugin_a12'    - A12 B-spline + TV 多频反演
%   'plugin_c01'    - C01 复数均匀球反演（H012: cavity_mode=true → body+cavity）
% 新建插件：在 algorithm/ 下创建 plugin_xxx/run_inversion.m
p.inversion_plugin = 'plugin_c01';   % H012: 切换至 plugin_c01 + cavity_mode

end
