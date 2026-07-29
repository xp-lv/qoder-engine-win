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
p.R_sphere  = 0.09;                % 测量球面半径 m（与管线2一致）
p.N_theta   = 12;                  % theta 采样数（与管线2一致）
p.N_phi     = 24;                  % phi 采样数（与管线2一致）
p.N_surface = p.N_theta * p.N_phi; % = 288 个采样点

%% ---- k 空间光锥采样 ----
p.N_k       = 16;                  % 光锥方向采样数（与管线2一致）

%% ---- 散射体与体素 ----
p.a_scatter  = 0.06;               % 散射体球半径 m（与管线2一致）
p.voxel_size = 0.01;               % 体素边长 ~lambda/30 m

%% ---- 迭代参数（伴随法）----
p.max_iter     = 10;               % 最大迭代次数
p.eps_tol      = 0.05;             % 残差收敛阈值（★ H031: Gate A eps_tol 从 0.2 收紧至 0.05，防止 eps_r 残差过早触发收敛导致 hole_pos 迭代空间不足）
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
% ★ 切换到管线2的 2layer.mph 模型（与管线2完全一致）
% 模型位于 COMSOL/pipline_adjoint/2layer.mph
p.comsol_model_path = fullfile(p.base_path, '..', 'pipline_adjoint', '2layer.mph');
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
p.cavity_eps_r_true    = 5.0;        % 主体真值 ε_r
p.cavity_hole_pos_true = [0.03, 0.02, 0.01]; % 真值空洞中心 [m]（偏心）
p.cavity_eps_r_init    = 3.0;        % 反演初始猜测 ε_r（真值5，初值3）
p.cavity_hole_pos_init = [0.0, 0.0, 0.0];     % 反演初始猜测空洞中心 [m]
p.cavity_mu_eps_r      = 1.0;        % ★ H029 迁移: Armijo mu=1.0（验证管线确认最佳初始步长，原值 0.5）
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
p.cavity_hybrid_fd_x   = false;      % H017: 废弃 hybrid FD（由 cavity_continuous_bi 替代；H015/H016 FD 路径已穷尽）
p.cavity_fd_delta_x    = 0.005;      % H015: x 分量 FD 中心差分扰动量 [m]（保留供 H017 FD 符号交叉验证参考）
p.cavity_fd_delta_x_fallback = 0.01;  % H015 Round11 P-01: FD fallback 升级 δ_x [m]（|g_FD_x| < min_magnitude 时触发自动升级重算）
p.cavity_fd_x_min_magnitude  = 1e4;   % H015 Round11 P-01: g_FD_x 最小有效量级阈值（低于此值视为伪信号，触发 δ_x 升级）
p.cavity_fd_geo_preflight   = true;   % H017 P-04: 几何预判短路（±δ_x 不改变体素归属时跳过正演，数学精确 g_FD_x≡0；向后兼容默认 true）

%% ---- H017: 连续边界积分梯度策略（analytical_continuous_boundary_integral）----
% H017 核心改动：将空洞位置梯度从 FD 估计（H015/H016 hybrid_fd，已穷尽）重构为
%   解析形状导数连续边界积分。在 COMSOL FEM 求解的连续球形空洞边界上通过 mphinterp
%   提取 E_adj/E_fwd 场值，在 N~200-500 Fibonacci 球面采样点上数值求积。
%   dF/dx_hole = -Σ_k (ε_body−ε_cavity)·k0²·Re(E_fwd·E_adj)·n_x,k·w_k / N_freq （上升方向）
%   下降方向 g_pos = +Σ_k (ε_body−ε_cavity)·k0²·Re(E_fwd·E_adj)·n_k·w_k / N_freq
% 根因：voxel 级几何方案下 x 方向体素对称性硬约束——FD 路径无法打破
%   （H015 δ_x=0.005m g_FD_x≈0，H016 δ_x=0.01m fallback |g_FD_x|~0.1，差 5 个数量级）。
%   连续边界积分的积分域和被积函数均随 x_hole 连续变化，无需体素翻转。
% 关键优势：①积分域和被积函数连续变化 ②零额外正演（mphinterp 后处理） ③三分量统一框架
p.cavity_continuous_bi    = true;     % H017: 启用连续边界积分梯度（替代 hybrid_fd）
p.cavity_bi_N             = 300;      % Fibonacci 球面采样点数（200-500，等面积求积）
p.cavity_bi_fd_crosscheck = false;    % H018: FD 符号交叉验证已完成（H017 sign_consistent=true），关闭以节省 2 次额外正演

%% ---- H018 v2: 双组件稳定化（梯度归一化 + best_intermediate 保护）----
% H018 v2 保持 H017 cavity 4 参数几何配置与 CBI 梯度框架完全不变，
% 采用双组件并行方案消除 H017 暴露的 hole_err 终态震荡（iter2 最优 0.0182m→iter4 恶化 0.0534m）。
%
% 组件 A（梯度归一化·动力学层）：将空洞位置步长从固定 mu_hole=0.02 升级为
%   自适应缩放 Δx_hole = target_step × g_hole / ||g_hole||（target_step=0.01m），
%   使步长与 CBI 梯度量级（|g_hole|~1e7）显式解耦。当前代码已归一化方向
%   （dir_pos = g_pos/||g_pos||），故 mu_hole_try = target_step 即可实现物理位移目标。
%   含振荡检测 backtracking（连续 2 轮 hole_err 增加→target_step 减半，下界 0.001m）
%   和近零梯度守卫（||g_hole||<1e-12 时 Δx_hole=0）。
%
% 组件 B（best_intermediate 保护·终态层）：在迭代循环中维护 best_state
%   （以 hole_err 为判定指标），反演终止时返回 best_state 而非 final state，
%   提供数学保证：终态 hole_err ≤ 历史最优 hole_err（必然不差于 H017 iter2 的 0.0182m）。
%   纯安全网零回归风险，与组件 A 机制正交可安全并行。
p.cavity_h018_dual_component  = true;   % H018 v2: 启用双组件（true=组件A+B并行，false=退化为H017固定步长）
p.cavity_h018_target_step     = 0.03;   % H030: 物理位移目标 0.01→0.03（3 倍，匹配空洞位移需求 0.037m，H013 建议区间 0.02-0.05 中值）
p.cavity_h018_target_step_min = 0.001;  % 组件 A: backtracking 下界 [m]（防无限缩减）
p.cavity_h018_mu_hole_upper   = 0.05;   % 组件 A: 自适应步长上界 [m]（收敛后期 ||g||→0 时防发散）
p.cavity_h018_near_zero_grad  = 1e-12;  % 组件 A: 近零梯度守卫阈值（||g_hole|| 低于此值时 Δx_hole=0）

%% ---- H019: 多目标综合质量判据 Q（best_intermediate 判据升级）----
% H019 将组件 B best_intermediate 的终态选择判据从单一 hole_err 升级为多目标综合质量判据 Q：
%   Q = w_cos·cos θ + w_hole·max(0, 1−hole_err/hole_err_ref) + w_eps·max(0, 1−eps_r_err/eps_r_ref)
% cos θ 作为综合方向一致性指标（J_obs vs J_hyp）天然捕捉 eps_r 与 hole 的协同质量，
% 纳入判据后 best_intermediate 从'位置单目标极端'升级为'综合 Pareto 最优'。
% 触发背景：H018 v2 实验暴露残差 eps_r 与位置 hole_err 反相关（多目标失配），
% 单目标 hole_err 判据可能选中位置最优但材料/cos θ 退化的态。
p.cavity_h019_multi_obj_q   = true;    % H019: 启用多目标 Q 判据（true=Q判据, false=退化为H018 v2 hole_err单目标）
p.cavity_h019_w_cos         = 0.4;     % Q 权重: cos θ（综合方向一致性，核心质量保证）
p.cavity_h019_w_hole        = 0.4;     % Q 权重: hole_err 项（位置为核心反演目标）
p.cavity_h019_w_eps         = 0.2;     % Q 权重: eps_r_err 项（材料约束，eps_r 连续五轮 90% 恢复故权重略低）
p.cavity_h019_hole_err_ref  = 0.037;   % hole_err 归一化参考值 [m]（初始位置误差 norm([0,0,0]-[0.03,0.02,0.01])）
p.cavity_h019_eps_r_ref     = 1.0;     % eps_r_err 归一化参考值（相对误差 eps_r_true=5.0）

%% ---- H020: 双门独立收敛判据（convergence criterion from single-gate to dual-gate）----
% H020 唯一变更：全局收敛触发判据从单门 residual-based（F_cheb < eps_tol=0.2）
%   升级为双门独立收敛——Gate A residual AND Gate B hole_err 稳定性。
%   Gate A: residual F_cheb < eps_tol=0.2（与 H012-H019 完全一致，保持不变）
%   Gate B: hole_err 稳定性——连续 hole_stability_window 轮 |Δhole_err|/hole_err < hole_stability_threshold
%   全局收敛 = Gate A AND Gate B（双门同时满足才触发 converged=true）
% 触发背景：H019 实验暴露 residual（eps_r 主导）在 iter3 即收敛（F_cheb=0.062 << eps_tol=0.2），
%   但 hole_err 序列 0.0374→0.0277→0.0314→0.0404 仍在震荡（iter1 后 |Δhole_err|/hole_err = 13.6%/28.6% 远超 10% 稳定性阈值）。
%   单门 residual 收敛过早截断了 hole 优化空间。Gate B 强制 hole_err 稳定后才终止，给 hole 额外迭代预算。
% 三重终止兜底：max_iter=10 / LS 全 reject 早停（Round15）/ Q 判据 best_state 兜底（H019 组件 B）
p.cavity_h020_dual_gate              = true;    % H020: 启用双门独立收敛（true=Gate_A AND Gate_B，false=退化为 H019 单门 residual）
p.cavity_h020_hole_stability_window  = 2;       % H020 Gate B: hole_err 稳定性滑窗（连续 N 轮变化率均达标）
p.cavity_h020_hole_stability_threshold = 0.10;  % H020 Gate B: hole_err 变化率阈值（|Δhole_err|/hole_err < 10%）

%% ---- H021: eps_r 冻结机制（eps_r freeze after Gate A first satisfied）----
% H021 唯一变更：在 H020 双门独立收敛基础上新增 eps_r 冻结机制。
% 当 Gate A（F_cheb < eps_tol=0.2）首次满足时设置 eps_r_frozen=true，
% 后续迭代跳过 eps_r 梯度计算与参数更新，仅更新 hole 位置三分量。
% 触发背景：H020 双门收敛机制验证成功（Gate B 正确检测 hole_err 震荡并延迟收敛），
%   但 hole_err 终态 0.0404m 仍超标——根因：Gate A 满足后 eps_r 仍每轮参与 Armijo 更新，
%   微小 eps_r 变化经正演场 E_fwd 传导扰动 hole CBI 梯度景观导致 hole_err 震荡。
%   eps_r 冻结使正演场完全恒定，hole 在数学上严格的稳定梯度景观下独立收敛。
% 与 CBI/组件A/组件B/Q判据/GateB 五层正交，不改变任何已有机制。
p.cavity_h021_eps_r_freeze = true;    % H021: 启用 eps_r 冻结（true=Gate A 首次满足后冻结 eps_r，false=退化为 H020）

%% ---- H021-Round17: dF 机器精度早停（post-freeze LS trial 效率优化）----
% 触发：H021 needs_optimization。eps_r 冻结后 LS trial dF 降至机器精度（~1e-16），
%   在数值噪声中做 accept/reject 判定，浪费 3 次正演（~15s，占总耗时 5%）。
% 根因：hole 位置 sub-voxel 移动不改变离散化 epsilon 分布（相同 cavity 体素），
%   正演问题完全相同 → residual 恒定 → Armijo 在舍入误差级噪声中操作。
% 机制：线搜索 trial 中检测 |dF| < 机器精度阈值，判定为"离散化不敏感步"并终止线搜索：
%   dF<=0 仍 accept（残差不上升）但立即 break；dF>0 不 decay mu 直接 break（避免无意义试探）。
% 阈值 1e-10 比 F_cheb(~6e-2) 小 8 个数量级，远超物理下降量级（收敛时 dF>=1e-6），误伤风险极低。
p.cavity_h021_dF_earlystop    = true;    % Round17: 启用 dF 机器精度早停
p.cavity_h021_dF_machine_eps  = 1e-10;   % Round17: 机器精度阈值（|dF|<此值判定为离散化不敏感）
p.cavity_h021_dF_rel_threshold = 0.005;  % Round19: dF 相对阈值（|dF|/F_old<0.5% 时判定为低效步，SDF 场景物理量级 dF 防护）

%% ---- Round23: Gate A 触发轮 LS shortcircuit（H032 needs_optimization P1）----
% H032 建议扩展 Round19 frozen-LS shortcircuit 至 Gate A 触发轮（eps_r 刚冻结的当轮）。
% 触发背景：H032 iter4 Gate A 首次触发后 eps_r 冻结，但该轮 hole_pos LS 仍跑 4 trials 全 reject
%   （F_try=0.0146/0.0097/0.0065/0.0051 vs old=0.0039754 全部上升，浪费 4 次正演 ~48s）。
% 机制：Gate A 触发轮标记 shortcircuit，LS trial==1 时与 Round19 条件并联触发，跳过该轮全部 LS trial。
% 仅跳过参数更新，不影响 Gate B 收敛判定/迭代推进/best-state tracking。不改变能力契约。
p.cavity_gate_a_ls_shortcircuit = true;   % Round23: Gate A 触发轮跳过 post-freeze 第一轮 LS（H032 iter4 4次确定性 reject 防护，节省 ~48s/轮）

%% ---- H022: SDF sub-voxel 软边界连续化（epsilon 映射）----
% H022 唯一变更：将 cavity epsilon 映射从硬二值体素分配（body ε_r OR cavity ε=1）
%   升级为符号距离函数（SDF）sub-voxel 软边界连续化。
%   对每个内部体素 i：d_i=|r_i-r_hole|-R_hole（符号距离，负=腔内，正=体内），
%   ε_i=ε_r+(1.0-ε_r)·H_smooth(d_i)，H_smooth(d)=0.5·(1-tanh(d/δ))。
%   δ=0.008m（~1/3 体素尺寸 0.024m），使正演 epsilon 连续依赖 hole 位置，
%   恢复残差对 sub-voxel hole 移动的梯度反馈（dF/d(r_hole)≠0）。
% 触发背景：H021 冻结实验证伪 eps_r-hole 耦合根因——冻结后 residual 恒定 dF~1e-16，
%   离散化正演对 sub-voxel hole 位置完全不敏感（7 cavity voxels 不变→ε分布不变→正演相同）。
%   SDF 使 hole 移动→符号距离连续变化→ε连续变化→正演场连续变化→residual 连续变化。
% 与 CBI/组件A/组件B/Q判据/双门/eps_r冻结/Armijo 七层正交，仅改 epsilon 赋值方式。
p.cavity_h022_sdf       = true;     % H022: 启用 SDF 软边界 epsilon 映射（true=SDF连续化, false=硬二值退化为H021）
p.cavity_h022_sdf_delta = 0.008;    % H022: 软边界半宽 δ [m]（~1/3 体素尺寸 0.024m，平衡连续敏感性与物理精度）

%% ---- H030-Round21: 连续 reject 早停阈值（迭代轮级）----
% H029 参数化（默认 3），H030 二次验证后默认降至 2。
% 连续 N 轮 LS 全 reject 且参数态不变时，第 N+1 轮极大概率也 reject（确定性重演）。
% best-state tracking 保证不丢最优态。设 3 可恢复旧行为基线。
p.cavity_reject_threshold    = 2;       % Round21: 连续 reject 阈值（达到即提前终止迭代）

%% ---- H032: hole_pos 步长 backtracking 自适应减半 ----
% H032 唯一变更：将 hole_pos 步长策略从固定 target_step=0.03 改为 backtracking 自适应减半。
% 当某步被 Armijo 线搜索接受（F_try < F_cheb）但导致 hole_err 回弹（hole_err_new > hole_err_prev）时，
% hole_pos 步长自动减半重试（0.03→0.015→0.0075→0.00375，最多 3 次减半）。
% 与现有 Armijo 线搜索互补不冲突：Armijo 基于 F 整体目标（eps_r 贡献主导）判断接受/拒绝，
% H032 基于 hole_err 几何指标判断 hole_pos 步长是否过冲。
% 触发背景：H031 实测 iter2→iter3 hole_err +106.7% 回弹（0.0177→0.0366m），固定大步长在近真值处过冲振荡。
% 与 H018 A（跨迭代振荡检测减半）区别：H032 在同一迭代的线搜索内即时减半（更精细的 per-step 控制）。
p.cavity_h032_backtrack      = true;   % H032: 启用 hole_pos backtracking 减半（true=步长自适应减半, false=退化为固定步长）
p.cavity_h032_max_halvings   = 3;      % H032: 最大减半次数（0.03→0.015→0.0075→0.00375）

%% ---- H022-Round18: 系统性 reject 早停（H023 needs_optimization 正式启用）----
% 触发：H023 needs_optimization。H022 已编码 Round18 机制但 config.m 未设 true，
%   致 H023 iter3+iter4 各跑满 8 次 LS trial 全 reject（16 次浪费/~128s/23%）。
% 机制：同一轮线搜索内连续 N=4 次 trial 全部 reject 且 dF 物理量级同号 → 梯度方向系统性错误，提前终止。
% 预期效果：H023 iter3 从 8 次→4 次 trial（省 4 次正演），iter4 从 8 次→0 次（冻结后 LS 短路）。
p.cavity_h022_sysreject_earlystop = true;   % Round18: 启用系统性 reject 早停（H022 已编码，H023 正式启用）
p.cavity_h022_sysreject_N         = 4;      % Round18: 连续同号 reject 阈值（达到即 break）
p.cavity_h022_sysreject_dF_floor  = 1e-8;   % Round18: dF 物理量级下限（|dF|<此值不计数，与 Round17 缓冲）

%% ---- H023: SDF-aware 伴随体积积分（hole 位置梯度升级）----
% H023 唯一变更：将 hole 位置梯度从 CBI 硬边界球面积分（∂Ω_cav 上 Re(E_adj·E_fwd)·n dS）
%   升级为 SDF 过渡带伴随体积积分（Ω_transition 上 Re(E_adj·E_fwd)·(dε/d_r_hole) dV）。
%   链式法则穿过 tanh 软边界：dε_i/d_r_hole=(1−ε_r)·0.5·sech²(d_i/δ)/δ·(r_i−r_hole)/|r_i−r_hole|，
%   使梯度与 H022 SDF 正演模型严格一致（消除 H022 条件_1 cos=−0.3082 方向反向不匹配）。
% 触发背景：H022 SDF 核心假设 CONFIRMED（dF/d_hole 从 ~1e-16 恢复至 5.74），但 CBI 硬边界梯度
%   与 SDF 软边界正演不匹配（条件_1 cos<0），致 cos θ 退化 0.859→0.506、iter3 LS 8 次全 reject。
%   H023 直接治理梯度−正演一致性根因，预期条件_1 cos>0.95、cos θ 恢复突破 0.92。
% 与 SDF 正演/组件A/组件B/Q判据/双门/eps_r冻结/Armijo 八层正交，仅改 hole 位置梯度公式。
p.cavity_h023_sdf_aware         = true;   % H023: 启用 SDF-aware 体积积分（true=替代CBI, false=退化为H022 CBI球面积分）
p.cavity_h023_transition_factor = 2.0;    % H023: 过渡带半宽因子（|d_i|<factor·δ 内计算梯度，sech²天然集中）

%% ---- H024: 梯度公式逐层分解诊断模块（diagnostic decomposition）----
% H024 唯一变更：在 SDF-aware 梯度计算后新增三层诊断模块，不修改梯度公式本身。
% 诊断目标：将 cos(g_SDF_aware, g_FD)=−0.0920 的系统性偏差归因至唯一层级。
% L1: dε_i/d_r_hole 链式法则逐体素验证（解析 vs 数值中心差分，零额外正演）
% L2: ∂F/∂ε_i Born 近似 FD 验证（6 代表体素 ε_i 微扰，~36 次额外正演）
% L3: 逐频梯度分解 + −k0² 加权修正梯度构造（零额外正演，数据重排）
% 诊断性假设——不改变优化动力学，H023 SDF-aware 公式完全保持不变。
p.cavity_h024_diagnostic       = true;   % H024: 启用梯度诊断分解（true=执行三层诊断, false=跳过）
p.cavity_h024_diag_iter        = 2;      % H024: 诊断执行迭代轮（iter=2，梯度景观演化后验证）
p.cavity_h024_l1_delta         = 1e-6;   % H024 L1: 链式法则数值中心差分步长 [m]
p.cavity_h024_l2_n_voxels      = 6;      % H024 L2: 代表性体素数（过渡带内/边界/外各 2 个）
p.cavity_h024_l2_delta_eps     = 0.01;   % H024 L2: ε_i 微扰量（Born 近似 FD 验证）

%% ---- Round20 (H025 needs_optimization): L2 诊断跨实验缓存 ----
% H025 实验执行者观察：H024 L2 诊断 12 次额外正演占 iter2 耗时 84%（总反演 331.6s 的 52%），
%   其中 5/6 体素与 H024 跨实验 6 位有效数字完全一致 → 冗余正演。
% 引入持久化缓存（data/l2_diag_cache.mat）：以 (hole_pos, 全局 inner ε_r, d_eps, freqs, v_idx, J_obs)
%   的 SHA-256 指纹为键缓存 born_ratio，跨实验命中时跳过 COMSOL 正演。
% 纯效率优化——不改变诊断逻辑/梯度公式/能力契约（H025 证 Born 因子非偏差根因 residual_gap=-7.24 orders）。
% 单客户端串行运行（COMSOL Server 单客户端模式），无并发写冲突。
p.cavity_h025_l2_cache         = true;   % Round20: L2 诊断跨实验缓存（true=启用，命中跳过冗余正演）

%% ---- Round 22: 精确全 Maxwell 伴随法（表面双源）----
% build_adjoint_source_fullmaxwell 返回 Js + Ms 双源，solve_adjoint 创建 SurfaceCurrent + SurfaceMagneticCurrentDensity
% 替代旧 Born 近似的简化反向投影（忽略极化投影核）
% 参见：z-workspace/inverse-v3/SurfaceMagneticCurrentDensity_使用说明.md
% 实测验证：COMSOL/pipline/experiment/probe_magnetic_current_v2.m
p.exact_adjoint_r22             = true;   % Round22: 精确伴随（true=表面双源/false=旧Born体积电流）

%% ---- 反演算法插件（随插随用）----
% 通过 run_experiment.m 统一调度，切换此参数即可更换算法
% 可用插件：
%   'plugin_basic'  - 基础伴随梯度法（core_inversion/inversion_loop）
%   'plugin_a12'    - A12 B-spline + TV 多频反演
%   'plugin_c01'    - C01 复数均匀球反演（H012: cavity_mode=true → body+cavity）
% 新建插件：在 algorithm/ 下创建 plugin_xxx/run_inversion.m
p.inversion_plugin = 'plugin_c01';   % H012: 切换至 plugin_c01 + cavity_mode（H017: continuous_bi; H018: dual_component; H019: multi_obj_Q）

end
