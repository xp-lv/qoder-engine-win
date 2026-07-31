function p = config()
%CONFIG 极简伴随法开发配置（pipline_adjoint）
%   ★ 目标：降规模快速验证伴随法精确性，验证通过后再提升规模 ★
%
%   与原 pipline/config.m 的核心差异：
%     1. 2层几何模型（内球散射体 + 外球空气PML），替代3层复杂结构
%     2. 大幅降规模：体素~30、测量点~200、k方向~16
%     3. 程序化构建模型（build_lightweight_model.m），不依赖预设 .mph
%     4. 专注于单参数（eps_r）验证，暂不含 cavity/hole 几何参数

%% ---- 物理常数 ----
p.c       = 299792458;
p.eps0    = 8.854187817e-12;
p.mu0     = 4*pi*1e-7;
p.eta0    = sqrt(p.mu0/p.eps0);

%% ---- 频率 ----
p.freq     = 1e9;
p.omega    = 2*pi*p.freq;
p.k0       = p.omega / p.c;
p.lambda   = p.c / p.freq;

%% ---- ★ 极简 2 层几何模型 ----
% 内层球：散射体区域
p.R_inner   = 0.06;     % 散射体内球半径 [m]
% 外层球：空气 + PML
p.R_air     = 0.12;     % 空气层外边界 [m]
p.pml_thick = 0.04;     % PML 层厚度 [m]
p.R_outer   = p.R_air + p.pml_thick;  % 总外半径 = 0.16m
% 测量球面（在空气层内）
p.R_sphere  = 0.09;     % 测量球面半径 [m]

%% ---- 降规模采样 ----
p.N_theta   = 12;       % theta 采样数（原 48 → 12）
p.N_phi     = 24;       % phi 采样数（原 96 → 24）
p.N_surface = p.N_theta * p.N_phi;  % = 288 个测量点（原 4608）

%% ---- k 空间光锥采样 ----
p.N_k       = 16;       % 光锥方向数

%% ---- 散射体与体素 ----
p.a_scatter  = p.R_inner;  % 散射体球半径 = 内层球半径
p.voxel_size = 0.02;       % 体素边长（原 0.01 → 0.02，更粗网格）
% 预计内部体素：球体积 / 体素体积 ≈ (4/3π·0.06³) / 0.02³ ≈ 113
% 实际 FEM 单元数取决于网格划分

%% ---- 背景场配置 ----
p.background.type        = 'planewave';
p.background.amplitude   = 1.0;
p.background.polarization = [0, 0, 1];  % E along Z
p.background.k_direction  = [1, 0, 0];  % k along X

%% ---- 验证参数 ----
% 真值配置：均匀球 eps_r_true
p.eps_r_true  = 5.0;    % 真值介电常数
p.eps_r_init  = 3.0;    % 初始猜测

%% ---- 数值保护 ----
p.E_threshold = 1e-6;
p.F_obs_min   = 1e-60;

%% ---- 项目路径 ----
p.base_path = fileparts(fileparts(mfilename('fullpath')));

%% ---- COMSOL LiveLink ----
p.comsol_port = 2036;
% 模型文件（程序化构建后保存）
p.comsol_model_path = fullfile(p.base_path, '2layer.mph');

%% ---- 数据路径 ----
p.dir_data   = fullfile(p.base_path, 'data');
p.dir_result = fullfile(p.dir_data, 'results');
for d = {p.dir_data, p.dir_result}
    if ~exist(d{1}, 'dir'), mkdir(d{1}); end
end

%% ---- 梯度公式选择 ----
% 'bilinear'  = Re(E·λ)   无共轭（COMSOL 复对称刚度矩阵正确公式）
% 'hermitian' = Re(conj(E)·λ)  共轭（旧版，已知错误）
p.gradient_dot = 'bilinear';

%% ---- FD 验证参数 ----
p.fd_deltas_eps = [0.1, 0.01, 0.001];   % eps_r FD 步长序列
p.fd_delta_ref  = 0.001;                  % 参考步长（最小）

%% ============ H033: 复数高对比度反演参数 ============
% epoch: complex_high_contrast_20m5j
% 符号约定: COMSOL ε_r = int1 + i*int2 = ε_re + j·ε_im
% 物理惯例: ε_r = ε' - jε''，真值 20-5j → ε_re=20, ε_im=-5

% --- 真值（复数 ε_r = 20-5j，对比度 20:1，tan δ=0.25）---
p.eps_r_true_re = 20.0;                   % 真值实部（COMSOL int1）
p.eps_r_true_im = -5.0;                   % 真值虚部（COMSOL int2，负=损耗）
p.eps_r_true_complex = p.eps_r_true_re + 1j * p.eps_r_true_im;

% --- 初始猜测（偏离真值，测试完整反演能力）---
p.eps_r_init_re = 12.0;                   % 初值实部
p.eps_r_init_im = -3.0;                   % 初值虚部
p.eps_r_init_complex = p.eps_r_init_re + 1j * p.eps_r_init_im;

% --- Tikhonov 先验（偏离真值 [12,-3]，测试反演鲁棒性）---
p.eps_r_prior_re = 12.0;
p.eps_r_prior_im = -3.0;
p.lambda_prior   = 0.01;                  % Tikhonov 正则化系数（基准值，H035 及之前单一权重）

% --- H036: Tikhonov 先验权重实虚部分离（解除先验对实部数据梯度的过度压制）---
% 命题: H035 实验证明标定漂移已修复（末次 1.07×）但 ε_re 仍停滞 69.4%（13.88），
%       根因为 λ_prior 对 ε_re 方向过度压制——g_prior_re=2·λ_prior·(ε_re-20) 量级显著，
%       与数据梯度叠加触发 Armijo 步长坍缩→ε_re 停滞。
% 修复: 实部先验权重降低 5 倍使数据梯度获得主导权；虚部保持不变（ε_im 已达 100.6%）。
p.lambda_prior_re = p.lambda_prior / 5;   % 实部先验权重（降低 5×，使数据梯度主导 ε_re 收敛）
p.lambda_prior_im = p.lambda_prior;       % 虚部先验权重（保持不变，g_prior_im≈0 不受影响）

% --- 步长控制（高对比度防过冲）---
p.mu_init_complex = 0.5;                  % 初始步长
p.damping_init    = 0.3;                  % 初始阻尼因子（×0.3 逐步恢复）
p.damping_recover = 1.3;                  % 每轮阻尼恢复因子
p.max_halvings    = 5;                    % backtracking 最大减半次数（吸收 H032 P0 建议）

% --- 迭代控制 ---
p.max_iter_complex = 15;                  % 复数反演最大迭代
p.eps_tol_complex  = 0.15;                % 收敛阈值 sqrt(F)

% --- FD sign 验证（H033 最关键验收指标）---
p.fd_sign_threshold = 0.80;              % FD sign 通过率阈值
p.fd_deltas_complex = [0.5, 0.1, 0.01, 0.001]; % 多步长 FD（维护 H033-P1：截断 1e-4 噪声陷阱，该步长已低于 COMSOL 双精度有效灵敏度）

%% ============ H033 needs_optimization 维护参数（管线维护者固化）============
% P0: mphstart 连接健壮性
p.mphstart_retry   = true;               % mphstart 失败自动重试 1 次（mphstop + mphstart，吸收偶发端口抖动）
% P1: FD 验证效率
p.fd_early_stop    = true;               % FD 前 2 个粗步长 sign 全一致则跳过细步长（减少纯验证正演开销）
% P2: backtracking 饱和处理
p.saturation_early_stop_n   = 3;         % 连续 N 轮 backtracking 全饱和（无接受步）则提前终止主循环
p.saturation_short_circuit = true;       % 上轮全 reject 且参数变化<1e-6 时短路本轮 5 次 trial（确定性重演）

%% ============ H034/H035: FD 梯度标定参数 ============
% ★ 原理 §12 声明：伴随法给出精确梯度，无需 Born 近似。
%   FD 标定是补偿 J_hyp Born FT 近似引入的系统性幅度偏差的手段。
%   伴随源系数修正后（原理 §7.1 因子 2），幅度偏差应显著降低。
%   若伴随梯度足够精确，可设 fd_scale_enable=false 关闭标定。
% epoch: complex_high_contrast_20m5j (round 2→3)
% H034: 修复 H033 Wirtinger 解析梯度幅值失配（re 低估 40×, im 低估 541×）
%        首轮用 central FD 标定 scale_re/scale_im
% H035: 将 H034 单次首轮标定升级为周期性重新标定（每 K 轮在当前 ε_r 处重算
%        scale_re/scale_im 并替换旧系数），修复 H034 标定系数漂移（3.16×）根因
p.fd_scale_enable          = true;   % 启用 FD 梯度标定（H034/H035 核心机制）
p.fd_calib_delta           = 0.01;   % FD 标定步长（0.01 经 H033 验证稳定，避免 1e-4 噪声陷阱）
p.scale_constancy_check_iter = 5;    % [H034 legacy] 单次恒定性复检迭代轮数；H035 周期性重新标定后由逐周期 drift 追踪取代
p.fd_recalib_period        = 3;      % [H035] 周期性重新标定间隔 K（每 K 轮在当前 ε_r 处重算 scale_re/scale_im 并替换）
p.scale_max                = 500;    % [H039] FD 标定系数 signed-scale 幅值裁剪上限

%% ============ solve_adjoint_matlab 所需参数 ============
p.mphmatrix_symmetry = 'on';  % COMSOL 接受值: on|off|auto|hermitian。复对称 Kc 用 'on' 利用对称性
p.use_decomposition = true;           % 使用 MATLAB decomposition 缓存 LU 分解

end
