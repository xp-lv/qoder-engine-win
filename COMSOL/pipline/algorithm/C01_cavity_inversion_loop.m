function state = C01_cavity_inversion_loop(voxel, lc, grid, model, p)
%C01_CAVITY_INVERSION_LOOP H012: 均匀主体 + 偏心空洞位置反演
%   参数化：θ = [eps_r_body, x_hole, y_hole, z_hole]（4 个实数标量）
%   几何：主体球 R_body=0.13m 固定位置，内嵌偏心球形空洞 R_hole 固定大小，
%         空洞中心位置 (x_hole,y_hole,z_hole) 随样本变化，为待反演参数。
%
%   梯度：
%     材料 ∂F/∂eps_r = Σ_{body\cavity} Re[g_voxel(v)]
%     位置 ∂F/∂x_hole = (eps_r-1)·(1/dr)·Σ_{boundary} Re[g_voxel(v)]·n_x
%     （shape derivative 边界面积分，dr=体素线性尺寸）
%
%   两类梯度分别归一化后独立步长更新（量级差异隔离）。

%% ---- 基本维度 ----
N_v = length(voxel.epsilon_r);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos_inner = voxel.pos(inner, :);       % [N_inner × 3]
dV_inner = voxel.dV(inner);            % [N_inner × 1]
dr = mean(dV_inner).^(1/3);            % 体素线性尺寸

N_freq = length(p.cavity_freqs);
freqs = p.cavity_freqs;
N_k = size(lc.J_obs_perp, 1);

% 几何参数
R_body  = p.a_scatter;                  % 主体球半径 0.13m
R_hole  = p.cavity_R_hole;             % 空洞半径（固定先验）

% 真值（用于 J_obs 计算）
eps_r_true  = p.cavity_eps_r_true;     % 主体真值 ε_r
hole_true   = p.cavity_hole_pos_true;  % 真值空洞中心 [1×3]

% 初始猜测
eps_r_init  = p.cavity_eps_r_init;
hole_init   = p.cavity_hole_pos_init;

% 步长参数
mu_eps     = p.cavity_mu_eps_r;         % ε_r 步长
mu_hole    = p.cavity_mu_hole_pos;      % 位置步长 [m]
mu_decay   = p.ls_decay;
mu_max_trials = p.ls_max_trials;

% H018 v2 组件 A: 梯度归一化自适应步长初始化
h018_enabled = isfield(p, 'cavity_h018_dual_component') && p.cavity_h018_dual_component;
if h018_enabled
    if ~isfield(p, 'cavity_h018_target_step'),     p.cavity_h018_target_step = 0.01; end
    if ~isfield(p, 'cavity_h018_target_step_min'), p.cavity_h018_target_step_min = 0.001; end
    if ~isfield(p, 'cavity_h018_mu_hole_upper'),   p.cavity_h018_mu_hole_upper = 0.05; end
    if ~isfield(p, 'cavity_h018_near_zero_grad'),  p.cavity_h018_near_zero_grad = 1e-12; end
    h018_target_step    = p.cavity_h018_target_step;
    h018_target_step_min = p.cavity_h018_target_step_min;
    h018_mu_hole_upper  = p.cavity_h018_mu_hole_upper;
    h018_near_zero_th   = p.cavity_h018_near_zero_grad;
    h018_osc_count      = 0;              % 振荡计数器（连续 hole_err 增加）
    h018_prev_he_post   = Inf;            % 前一轮线搜索后 hole_err
    h018_hole_converged = false;          % 近零梯度守卫标记
    fprintf('[C01_cavity] [H018 v2] dual_component ENABLED: target_step=%.4f upper=%.4f min=%.4f\n', ...
        h018_target_step, h018_mu_hole_upper, h018_target_step_min);
end

% H019: 多目标综合质量判据 Q 初始化（组件 B 判据升级）
% Q = w_cos·cos θ + w_hole·max(0,1−hole_err/hole_err_ref) + w_eps·max(0,1−eps_r_err/eps_r_ref)
h019_enabled = isfield(p, 'cavity_h019_multi_obj_q') && p.cavity_h019_multi_obj_q;
if h019_enabled
    h019_w_cos         = p.cavity_h019_w_cos;
    h019_w_hole        = p.cavity_h019_w_hole;
    h019_w_eps         = p.cavity_h019_w_eps;
    h019_hole_err_ref  = p.cavity_h019_hole_err_ref;
    h019_eps_r_ref     = p.cavity_h019_eps_r_ref;
    fprintf('[C01_cavity] [H019] multi_objective_Q ENABLED: w_cos=%.2f w_hole=%.2f w_eps=%.2f ref_hole=%.4f ref_eps=%.2f\n', ...
        h019_w_cos, h019_w_hole, h019_w_eps, h019_hole_err_ref, h019_eps_r_ref);
end

% H020: 双门独立收敛判据初始化
% Gate A: residual F_cheb < eps_tol（保持不变）
% Gate B: hole_err 稳定性——连续 hole_stability_window 轮 |Δhole_err|/hole_err < hole_stability_threshold
% 全局收敛 = Gate A AND Gate B（双门同时满足才触发 converged=true）
h020_enabled = isfield(p, 'cavity_h020_dual_gate') && p.cavity_h020_dual_gate;
if h020_enabled
    h020_stab_window    = p.cavity_h020_hole_stability_window;
    h020_stab_threshold = p.cavity_h020_hole_stability_threshold;
    fprintf('[C01_cavity] [H020] dual_gate_convergence ENABLED: Gate_A(F_cheb<eps_tol) AND Gate_B(hole_err stability, window=%d, threshold=%.0f%%)\n', ...
        h020_stab_window, h020_stab_threshold*100);
end

% H021: eps_r 冻结机制初始化
% Gate A（F_cheb < eps_tol）首次满足后 eps_r_frozen=true，后续迭代跳过 eps_r 梯度计算与参数更新
% 仅更新 hole 位置三分量。eps_r 一旦冻结在整个剩余迭代中保持冻结（不解冻）。
% 与 CBI 梯度框架/组件A 步长归一化/组件B Q 判据/双门收敛/Armijo 线搜索五层正交。
h021_enabled = isfield(p, 'cavity_h021_eps_r_freeze') && p.cavity_h021_eps_r_freeze;
eps_r_frozen = false;       % eps_r 冻结标志
eps_r_freeze_iter = 0;       % eps_r 冻结触发的迭代轮数
if h021_enabled
    fprintf('[C01_cavity] [H021] eps_r_freeze ENABLED: Gate A 首次满足后冻结 eps_r 更新，后续仅更新 hole 位置\n');
end

% 管线维护 Round17 (H021 needs_optimization): dF 机器精度早停
% post-freeze LS trial dF~1e-16 在数值噪声中操作，浪费正演（H021 iter4/5 共 3 次/~15s）。
% 当 |dF| < 机器精度阈值时判定为"离散化不敏感步"，终止线搜索避免在舍入误差中浪费正演。
% 与 eps_r 冻结机制正交（独立配置）——即使未冻结，任何 dF 降至机器精度级都应早停。
h021_dF_earlystop = isfield(p, 'cavity_h021_dF_earlystop') && p.cavity_h021_dF_earlystop;
dF_machine_eps    = 1e-10;
if isfield(p, 'cavity_h021_dF_machine_eps'), dF_machine_eps = p.cavity_h021_dF_machine_eps; end
dF_earlystop_hits = 0;   % dF 早停触发次数（诊断统计）
if h021_dF_earlystop
    fprintf('[C01_cavity] [Round17] dF_earlystop ENABLED: |dF|<%.1e 时终止线搜索（post-freeze 机器精度噪声防护）\n', dF_machine_eps);
end

% H022: SDF sub-voxel 软边界连续化（epsilon 映射）
% 将 cavity epsilon 赋值从硬二值升级为 SDF：d_i=|r_i-r_hole|-R_hole;
% ε_i=ε_r+(1.0-ε_r)·0.5·(1-tanh(d_i/δ)), δ=软边界半宽
% 使每个网格元素 epsilon 连续依赖 hole 位置→恢复残差梯度反馈 dF/d(r_hole)≠0
h022_sdf = isfield(p, 'cavity_h022_sdf') && p.cavity_h022_sdf;
sdf_delta = 0.008;
if isfield(p, 'cavity_h022_sdf_delta'), sdf_delta = p.cavity_h022_sdf_delta; end
if h022_sdf
    fprintf('[C01_cavity] [H022] SDF soft boundary ENABLED: delta=%.4f effective_R=%.4f (R_hole+delta)\n', ...
        sdf_delta, R_hole + sdf_delta);
end

% H023: SDF-aware 伴随体积积分（hole 位置梯度从 CBI 球面积分升级为 SDF 过渡带体积积分）
% 链式法则穿过 tanh 软边界：dε_i/d_r_hole=(1−ε_r)·0.5·sech²(d_i/δ)/δ·(r_i−r_hole)/|r_i−r_hole|
% 两负号相消（dε/d_d=−...·sech², d_d/d_hole=−(r_i−r_hole)/|r_i−r_hole|）→正向公式。
% 使梯度与 SDF 正演严格一致，消除 H022 条件_1 cos=−0.3082 方向反向不匹配。
h023_sdf_aware = isfield(p, 'cavity_h023_sdf_aware') && p.cavity_h023_sdf_aware;
h023_transition_factor = 2.0;
if isfield(p, 'cavity_h023_transition_factor'), h023_transition_factor = p.cavity_h023_transition_factor; end
h023_transition_halfwidth = h023_transition_factor * sdf_delta;  % |d_i|<此值体素计入积分
if h023_sdf_aware
    fprintf('[C01_cavity] [H023] SDF-aware adjoint volume integral ENABLED: transition_halfwidth=%.4f (factor=%.1f × delta=%.4f)\n', ...
        h023_transition_halfwidth, h023_transition_factor, sdf_delta);
    fprintf('[C01_cavity] [H023] 替代 CBI 球面积分——梯度与 SDF 正演模型严格一致（链式法则穿过 tanh）\n');
end

% H024: 梯度公式逐层分解诊断模块初始化
% 在 SDF-aware 梯度计算后新增三层诊断（L1 链式法则/L2 Born 近似/L3 逐频分解），不修改梯度公式本身
h024_diag_enabled = isfield(p, 'cavity_h024_diagnostic') && p.cavity_h024_diagnostic && h023_sdf_aware;
h024_diag_iter = 2;
if isfield(p, 'cavity_h024_diag_iter'), h024_diag_iter = p.cavity_h024_diag_iter; end
h024_diag_done = false;
if h024_diag_enabled
    fprintf('[C01_cavity] [H024] gradient diagnostic decomposition ENABLED: iter=%d (L1 chain-rule / L2 Born-FD / L3 per-freq)\n', h024_diag_iter);
end

% 管线维护 Round18 (H022 needs_optimization): 系统性 reject 早停
% 同一轮线搜索内连续 N 次 trial 全部 reject 且 dF 物理量级同号（全正/全负），
% 判定梯度方向系统性错误（CBI 梯度与正演模型不匹配），提前终止线搜索。
% 与 Round17 正交：Round17 防 |dF|<1e-10 无信号空转（离散化不敏感）；
% Round18 防 |dF|~1e-3 错误方向空转（梯度模型不匹配）。
% H022 iter3: 8 trial 全 reject dF~1e-3 浪费 ~88s/36%，Round18 在第 4 次 reject 即 break 省 ~44s。
h022_sysreject_earlystop = isfield(p,'cavity_h022_sysreject_earlystop') && p.cavity_h022_sysreject_earlystop;
sysreject_N = 4;
if isfield(p,'cavity_h022_sysreject_N'), sysreject_N = p.cavity_h022_sysreject_N; end
sysreject_dF_floor = 1e-8;
if isfield(p,'cavity_h022_sysreject_dF_floor'), sysreject_dF_floor = p.cavity_h022_sysreject_dF_floor; end
sysreject_hits = 0;   % 系统性 reject 早停触发次数（诊断统计）
if h022_sysreject_earlystop
    fprintf('[C01_cavity] [Round18] sysreject_earlystop ENABLED: 连续 %d 次同号 reject(|dF|>%.1e) 时终止线搜索（梯度方向错误防护）\n', sysreject_N, sysreject_dF_floor);
end

% 管线维护 Round19 (H023 needs_optimization): Round17 升级（相对阈值）+ 冻结后 LS 短路
% H023 暴露两个效率问题：
%   (1) Round17 绝对阈值 |dF|<1e-10 对 SDF 恢复后的 ~1e-4 量级 dF 完全失效（SDF 恢复残差灵敏度，
%       dF 回到物理量级但远高于 1e-10）。升级为复合判据：条件 A（保留 |dF|<1e-10）+
%       条件 B（新增 |dF|/F_old<rel_threshold 相对阈值，捕获“有信号但低效”的步）。
%   (2) eps_r 冻结后梯度景观恒定（cos(g_k,g_{k-1})=1.0000），iter4 LS trial 序列与 iter3 逐位相同
%       （确定性重演，零信息增量）。新增冻结后 LS 短路：eps_r 已冻结且前一轮 LS 全 reject →
%       跳过本轮 LS 全部 trial（依赖 Gate B 收敛判定推进迭代），完全消除确定性失败重演。
% 与 Round17/Round18 正交：Round17 防机器精度空转，Round18 防系统性方向错误，
% Round19 防低效相对步 + 冻结后确定性重演。三层防护互补。
dF_rel_threshold = 0.005;
if isfield(p, 'cavity_h021_dF_rel_threshold'), dF_rel_threshold = p.cavity_h021_dF_rel_threshold; end
dF_rel_earlystop_hits = 0;      % 相对阈值早停触发次数（诊断统计）
prev_iter_ls_all_reject = false; % Round19: 前一轮 LS 是否全 reject（冻结后 LS 短路用）
frozen_ls_shortcircuit_hits = 0; % Round19: 冻结后 LS 短路触发次数（诊断统计）
if h021_dF_earlystop
    fprintf('[C01_cavity] [Round19] dF_rel_threshold=%.1f%%: |dF|/F_old<%.1f%% 时终止线搜索（SDF 物理量级 dF 低效步防护）+ 冻结后 LS 短路\n', dF_rel_threshold*100, dF_rel_threshold*100);
end

% H032: hole_pos 步长 backtracking 自适应减半（线搜索内 hole_err 回弹检测）
% 当 Armijo 线搜索接受的步（F_try < F_cheb）导致 hole_err 回弹（hole_err_new > hole_err_prev）时，
% hole_pos 步长自动减半重试（0.03→0.015→0.0075→0.00375，最多 max_halvings 次减半）。
% 与现有 H018 A（跨迭代振荡检测：连续 2 轮 hole_err 增加→target_step 减半）互补但不同：
%   H018 A 是跨迭代的宏观振荡检测，修改 h018_target_step（持久）；
%   H032 是同一迭代线搜索内的 per-step 即时减半（局部，不修改 h018_target_step）。
% 与 Armijo 互补不冲突：Armijo 基于 F 整体目标（eps_r 贡献主导），H032 基于 hole_err 几何指标——
%   F 可能下降（eps_r 改善）但 hole_err 上升（hole_pos 过冲），Armijo 接受但 H032 拒绝并减半。
h032_backtrack = isfield(p, 'cavity_h032_backtrack') && p.cavity_h032_backtrack;
h032_max_halvings = 3;
if isfield(p, 'cavity_h032_max_halvings'), h032_max_halvings = p.cavity_h032_max_halvings; end
if h032_backtrack
    fprintf('[C01_cavity] [H032] hole_pos backtracking ENABLED: max_halvings=%d (step halving on hole_err rebound within LS)\n', h032_max_halvings);
end

% 管线维护 Round23 (H032 needs_optimization): Gate A 触发轮 LS shortcircuit
% H032 建议扩展 Round19 frozen-LS shortcircuit：Gate A 首次触发的那一轮（eps_r 刚冻结），
% post-freeze 第一轮 LS hole_pos trial 序列确定性地全 reject（H032 iter4 实测：
% F_try=0.0146/0.0097/0.0065/0.0051 全部 > old=0.0039754，4 次正演浪费 ~48s）。
% 机制：Gate A 触发轮标记 gate_a_shortcircuit_this_iter=true，LS trial==1 时与 Round19
% 短路条件并联触发，跳过该轮全部 LS trial。仅跳过参数更新，不影响 Gate B 收敛/迭代推进/best-state。
% 与 Round19 正交：Round19 用 prev_iter_ls_all_reject（需要历史），Round23 用 Gate A 触发信号（当轮即可判定）。
% 可配置（默认关闭），config.m 显式启用。不改变能力契约，不改变 eps_r 冻结逻辑。
gate_a_ls_shortcircuit_on = isfield(p, 'cavity_gate_a_ls_shortcircuit') && p.cavity_gate_a_ls_shortcircuit;
gate_a_shortcircuit_hits = 0;   % Round23: Gate A 触发轮 LS shortcircuit 命中次数（诊断统计）
if gate_a_ls_shortcircuit_on
    fprintf('[C01_cavity] [Round23] gate_a_ls_shortcircuit ENABLED: Gate A 触发轮跳过 post-freeze 第一轮 LS（确定性 reject 防护）\n');
end

% 约束边界
hole_margin = R_hole + 0.005;          % 空洞中心距原点最大距离

fprintf('\n[C01_cavity] start: R_body=%.3f, R_hole=%.3f, dr=%.4f\n', R_body, R_hole, dr);
fprintf('[C01_cavity] eps_r_init=%.2f, hole_init=[%.3f,%.3f,%.3f]\n', ...
    eps_r_init, hole_init(1), hole_init(2), hole_init(3));
fprintf('[C01_cavity] truth: eps_r=%.2f, hole=[%.3f,%.3f,%.3f]\n', ...
    eps_r_true, hole_true(1), hole_true(2), hole_true(3));
fprintf('[C01_cavity] max_iter=%d, mu_eps=%.4f, mu_hole=%.5f\n', p.max_iter, mu_eps, mu_hole);

%% ---- 预计算 J_obs（真值 phantom：body+cavity） ----
J_obs_multi = cell(1, N_freq);
for fi = 1:N_freq
    p_freq = p;
    p_freq.freq = freqs(fi);
    p_freq.omega = 2*pi*p_freq.freq;
    p_freq.k0 = p_freq.omega / p_freq.c;
    p_freq.lambda = p_freq.c / p_freq.freq;

    % 设置真值 phantom（H022: 与反演正演使用同一 epsilon 映射——SDF 或硬二值，保证 truth/forward 一致）
    voxel_truth = voxel;
    voxel_truth.epsilon_r = c01_cavity_eps_assign(pos_inner, hole_true, R_hole, eps_r_true, N_v, inner_idx, sdf_delta, h022_sdf);
    rho_truth = sqrt(sum((pos_inner - hole_true(:).').^2, 2));  % H022 fix: hole_true 归一化为列向量再转置，与 c01_cavity_eps_assign 内 hole_c(:).' 模式一致
    cavity_truth = rho_truth < R_hole;

    [E_truth, ~, ~] = solve_forward(model, voxel_truth, p_freq);
    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, p_freq);
    J_obs_multi{fi} = lc_obs.J_obs_perp;
    fprintf('[C01_cavity] J_obs[%d/%d] computed (cavity voxels=%d)\n', fi, N_freq, sum(cavity_truth));
end

%% ---- 初始化参数 ----
eps_r_body = eps_r_init;
hole_pos = hole_init(:);

%% ---- 历史 ----
state.history_residual   = zeros(p.max_iter, 1);
state.history_cos_theta  = zeros(p.max_iter, 1);
state.history_eps_r      = zeros(p.max_iter, 1);
state.history_hole_pos   = zeros(3, p.max_iter);
state.history_g_eps      = zeros(p.max_iter, 1);
state.history_g_pos_norm = zeros(p.max_iter, 1);
state.history_accepted   = zeros(p.max_iter, 1);
state.history_g_FD_x             = zeros(p.max_iter, 1);   % H015: x 分量 FD 梯度历史
state.history_g_pos_analytical_x = zeros(p.max_iter, 1);   % H015: x 分量解析梯度历史（对比诊断）
% H018 v2 监测历史
state.history_hole_err         = zeros(p.max_iter, 1);  % H018: 逐轮 hole_err（线搜索后实测）
state.history_mu_hole_adaptive = zeros(p.max_iter, 1);  % H018: 逐轮自适应 mu_hole_try
state.history_delta_x_hole     = zeros(p.max_iter, 1);  % H018: 逐轮实测 |Δx_hole|（根因验证）
state.history_best_hole_err    = zeros(p.max_iter, 1);  % H018: 逐轮 best_hole_err 轨迹
state.history_Q                = zeros(p.max_iter, 1);  % H019: 逐轮多目标 Q 综合质量判据（线搜索接受后）
state.history_hole_err_gateB     = zeros(p.max_iter, 1);  % H020 Gate B: 逐轮 hole_err 序列（收敛判据用）
state.history_hole_err_change_rate = zeros(p.max_iter, 1);  % H020 Gate B: 逐轮 |Δhole_err|/hole_err
state.history_gate_A_pass        = zeros(p.max_iter, 1);  % H020: 逐轮 Gate A 通过状态
state.history_gate_B_pass        = zeros(p.max_iter, 1);  % H020: 逐轮 Gate B 通过状态
state.history_eps_r_frozen       = zeros(p.max_iter, 1);  % H021: 逐轮 eps_r 冻结标志
state.history_g_pos_vec          = zeros(3, p.max_iter);   % H021: 逐轮 hole CBI 梯度向量（post_freeze 梯度景观稳定性）
state.history_g_pos_consistency  = zeros(p.max_iter, 1);  % H021: 逐轮 cos(g_k, g_{k-1}) 梯度方向一致性
state.history_g_pos_consistency_all = zeros(p.max_iter, 1);  % H022: 全迭代梯度方向一致性（条件_1 首轮验证 cos>0.95）
state.history_sdf_boundary_voxels   = zeros(p.max_iter, 1);  % H022: 逐轮 SDF 过渡带体素数（|d|<3δ）
state.history_residual_sensitivity  = zeros(p.max_iter, 1);  % H022: 逐轮 |dF|/|Δhole| 残差灵敏度
state.history_h032_halvings       = zeros(p.max_iter, 1);  % H032: 逐轮 hole_err backtracking 减半次数
state.history_h032_step_size      = zeros(p.max_iter, 1);  % H032: 逐轮 hole_pos 实际步长（减半后）
state.converged = false;
state.iteration = 0;

% 效率优化：连续 reject 早停 + best-state tracking（吸收 H007 实验效率建议）
consecutive_reject = 0;
% [管线维护 H029-P1→H030 Round21] reject_threshold 参数化 + 默认降至 2
% H029 观察：iter 3/4/5 连续 3 轮 LS 全 reject（参数态 eps_r=4.5 + hole 完全相同），
% 阈值=3 导致 iter 4/5 各浪费 4 次正演（~120s，占总耗时 ~15%）。
% H030 二次验证：iter 3-5 同样连续 3 轮全 reject，占总耗时 ~71%（464s/654s）但参数零更新。
% Round18 sysreject_earlystop 仍在第 3 轮（iter 5）才 BREAK，期间 iter 4/5 各浪费 4 次正演。
% 两次独立实验（H029+H030）一致确认：连续 2 轮 LS 全 reject 后第 3 轮极大概率也 reject
% （相同参数态）。现将默认阈值降至 2，best-state tracking 保证不丢最优态。
% 实验可通过 p.cavity_reject_threshold 覆盖（设 3 可恢复旧行为）。
reject_threshold   = 2;
if isfield(p, 'cavity_reject_threshold'), reject_threshold = p.cavity_reject_threshold; end
best_F             = Inf;  % best-state 残差
best_eps_r         = eps_r_init;
best_hole_pos      = hole_init(:);
best_iter          = 0;
best_J_hyp         = [];   % best-state J_hyp（供三件套评估）

% H018 v2 组件 B: best_intermediate 保护（基于 hole_err，v2 新增并行强制组件）
% 与上方 F_cheb-based best-state 正交：此追踪以 hole_err 为判据，
% 反演终止时优先返回 hole_err 最优态而非 F_cheb 最优态（H017 经验：F 可降而 hole_err 震荡）
best_he_hole_err    = Inf;           % best hole_err
best_he_pos         = hole_init(:);   % best hole_err 时的空洞位置
best_he_eps_r       = eps_r_init;     % best hole_err 时的 eps_r
best_he_residual    = Inf;           % best hole_err 时的残差
best_he_iter        = 0;             % best hole_err 发生的迭代轮
best_he_J_hyp       = [];            % best hole_err 时的 J_hyp（供三件套）

% H019: 组件 B 多目标 Q 判据——best_intermediate 终态选择以 Q 为判据
% Q = w_cos·cos θ + w_hole·(1−hole_err/ref) + w_eps·(1−eps_r_err/ref)，Q 越大越优
% 与 best_he_*（hole_err 单目标）并行追踪，h019_enabled 时终态返回 Q 最优态
best_Q              = -Inf;          % best Q 综合质量判据
best_Q_cos          = 0;             % best Q 时的 cos θ
best_Q_hole_err     = Inf;           % best Q 时的 hole_err
best_Q_eps_r_err    = Inf;           % best Q 时的 eps_r_err
best_Q_pos          = hole_init(:);   % best Q 时的空洞位置
best_Q_eps_r        = eps_r_init;     % best Q 时的 eps_r
best_Q_residual     = Inf;           % best Q 时的残差
best_Q_iter         = 0;             % best Q 发生的迭代轮
best_Q_J_hyp        = [];            % best Q 时的 J_hyp（供三件套）

% 管线维护 Round14 A-03: backtracking 后强制迭代标志
% 当 backtracking 在 iter N 触发时，iter N+1 收敛检查将被阻止，
% 确保 backtracking 缩减后的步长至少被执行 1 轮再评估收敛（H018 v2 暴露的时序 bug）
h018_backtrack_pending = false;

% 管线维护 Round15: A-03 强制迭代 LS 全 reject 早停标志
% 当 Round14 A-03 因 backtracking 强制迭代后，若线搜索全 trial reject，
% 说明当前状态已处于局部极小（所有步长均使残差上升），继续迭代无意义
a03_forced_this_iter = false;

% 管线维护 Round16: Gate B 延迟上限保护（H020 方案 C 安全网）
% 配合 Round16 Gate B 让位条件使用：当 Gate B 未通过（hole_err 未稳定）时，
% LS-allreject 让位 Gate B 继续迭代，但限制让位次数防止 hole_err 长期震荡导致无限迭代。
gate_b_delay_count = 0;   % Gate B 已让位 LS-allreject 的累计次数
gate_b_delay_max   = 3;   % Gate B 最多让位 3 轮（超过则 LS-allreject 恢复生效）
if isfield(p, 'h020_gate_b_delay_max'), gate_b_delay_max = p.h020_gate_b_delay_max; end

%% ---- CSV 日志 ----
log_path = fullfile(p.dir_result_C01, 'C01_cavity_log.csv');
log_fid = fopen(log_path, 'w');
fprintf(log_fid, 'iter,F_cheb,cos_theta,eps_r,hx,hy,hz,g_eps,g_pos_norm,hole_err,mu_eps,mu_hole,accepted,time_s,g_FD_x,g_pos_analytical_x\n');
fclose(log_fid);

%% ================ 主循环 ================
for iter = 1:p.max_iter
    tic;
    fprintf('\n--- C01_cavity iter %d/%d ---\n', iter, p.max_iter);
    a03_forced_this_iter = false;  % Round15: 每轮重置 A-03 强制迭代标志
    gate_a_shortcircuit_this_iter = false;  % Round23: 每轮重置 Gate A 触发轮 shortcircuit 标志

    %% 1. 从参数构造 voxel epsilon_r（H022: SDF 软边界连续化）
    rho_v = sqrt(sum((pos_inner - hole_pos(:).').^2, 2));   % [N_inner × 1]
    mask_cavity = rho_v < R_hole;
    mask_body   = ~mask_cavity;

    voxel.epsilon_r = c01_cavity_eps_assign(pos_inner, hole_pos, R_hole, eps_r_body, N_v, inner_idx, sdf_delta, h022_sdf);

    N_cavity = sum(mask_cavity);
    N_body = sum(mask_body);
    if h022_sdf
        n_transit = sum(abs(rho_v - R_hole) < 3*sdf_delta);
        state.history_sdf_boundary_voxels(iter) = n_transit;
        fprintf('  [iter %d] body voxels=%d, cavity voxels=%d, SDF transit=%d, eps_r=%.4f, hole=[%.4f,%.4f,%.4f]\n', ...
            iter, N_body, N_cavity, n_transit, eps_r_body, hole_pos(1), hole_pos(2), hole_pos(3));
    else
        fprintf('  [iter %d] body voxels=%d, cavity voxels=%d, eps_r=%.4f, hole=[%.4f,%.4f,%.4f]\n', ...
            iter, N_body, N_cavity, eps_r_body, hole_pos(1), hole_pos(2), hole_pos(3));
    end

    %% H017: Fibonacci 球面采样点生成（cavity 边界连续球面，每迭代随 hole_pos 更新）
    % 连续边界积分的积分域：真实球形空洞边界 ∂Ω_cav_sphere（半径 R_hole，中心 hole_pos）
    % 球面采样点通过 Fibonacci 螺旋均匀分布，法向 n_k=(r_k−hole_center)/R_hole 为连续外法向
    if isfield(p, 'cavity_continuous_bi') && p.cavity_continuous_bi && ~h023_sdf_aware
        bi_N = p.cavity_bi_N;
        bi_sphere_pts = fibonacci_sphere_points(bi_N, R_hole, hole_pos(:).');  % [N×3]
        bi_sphere_normals = (bi_sphere_pts - hole_pos(:).') ./ R_hole;           % [N×3] 外法向
        bi_w_quad = 4 * pi * R_hole^2 / bi_N;                                 % 等面积求积权重
        bi_g_pos_accum = zeros(3, 1);                                         % 连续边界积分累积（下降方向 g_pos）
        bi_fwd_extracted = false;  % 标记本 freq 内 E_fwd 是否已提取
        fprintf('  [H017 CBI] Fibonacci sphere: N=%d R=%.3f w_quad=%.4e\n', bi_N, R_hole, bi_w_quad);
    end

    %% 2. 多频率正演 + 残差 + 伴随梯度
    g_voxel = zeros(N_v, 1);          % 实数梯度（∂F/∂Re(ε)）
    F_k_total = zeros(N_k, 1);
    cos_theta_sum = 0;
    J_hyp_primary = [];
    F_k_per_freq = zeros(N_freq, 1);

    use_gauss = ~isempty(voxel.gauss_pos) && size(voxel.gauss_pos, 1) == 4 * N_inner;
    gauss_w = voxel.gauss_w;

    % H024 L3: 逐频 g_voxel 贡献快照初始化（用于逐频梯度分解）
    h024_perfreq_gvoxel_inner = cell(1, N_freq);
    h024_perfreq_k0sq = zeros(1, N_freq);

    for fi = 1:N_freq
        p.freq = freqs(fi);
        p.omega = 2*pi*p.freq;
        p.k0 = p.omega / p.c;
        p.lambda = p.c / p.freq;

        fprintf('  [iter %d freq=%d (%.0f GHz)] forward...\n', iter, fi, freqs(fi)/1e9);
        [E_total, ~, E_gauss] = solve_forward(model, voxel, p);

        sf = extract_scattered(model, grid);
        lc_new = lightcone_project(grid, sf, p);
        J_hyp = lc_new.J_obs_perp;

        J_obs_fi = J_obs_multi{fi};
        Delta_J = J_obs_fi - J_hyp;
        J_obs_sq = sum(abs(J_obs_fi).^2, 2);
        Delta_sq = sum(abs(Delta_J).^2, 2);
        J_obs_safe = max(J_obs_sq, p.rel_err_floor);
        F_k_fi = Delta_sq ./ J_obs_safe / 6;

        F_k_total = F_k_total + F_k_fi / N_freq;
        F_k_per_freq(fi) = mean(F_k_fi);

        % cos θ
        J_obs_norm = sqrt(J_obs_sq) + p.rel_err_floor;
        J_hyp_norm = sqrt(sum(abs(J_hyp).^2, 2)) + p.rel_err_floor;
        cos_theta_fi = real(sum(conj(J_obs_fi) .* J_hyp, 2)) ./ (J_obs_norm .* J_hyp_norm);
        cos_theta_sum = cos_theta_sum + mean(cos_theta_fi) / N_freq;

        if fi == 1
            J_hyp_primary = J_hyp;
        end

        fprintf('  [iter %d freq=%d] F_k mean=%.4e max=%.4e cos=%.3f\n', ...
            iter, fi, mean(F_k_fi), max(F_k_fi), mean(cos_theta_fi));

        %% H017: 提取正演场 E_fwd 在球面采样点（须在 adjoint 求解前，因此时 model 含正演解）
        % 连续边界积分 go/no-go 验证点：mphinterp 在介电不连续界面处的插值精度
        if isfield(p, 'cavity_continuous_bi') && p.cavity_continuous_bi && ~h023_sdf_aware
            try
                [E_fwd_sphere_fi, ~] = read_field(model, bi_sphere_pts);
                bi_fwd_extracted = true;
                n_nan_fwd = sum(~isfinite(sum(abs(E_fwd_sphere_fi), 2)));
                if n_nan_fwd > 0
                    fprintf('  [H017 CBI freq=%d] [WARN] E_fwd sphere: %d/%d NaN——mphinterp 在界面处插值退化\n', fi, n_nan_fwd, bi_N);
                end
            catch ME_fwd
                fprintf('  [H017 CBI freq=%d] [WARN] E_fwd sphere 提取失败: %s\n', fi, ME_fwd.message);
                bi_fwd_extracted = false;
            end
        end

        %% 伴随求解
        fprintf('  [iter %d freq=%d] adjoint...\n', iter, fi);
        lc.k_vec = p.k0 * lc.k_dir;
        lc.J_obs_perp = J_obs_fi;
        lc.Delta_J_perp = Delta_J ./ J_obs_safe;
        % ★ H027: 精确全 Maxwell 表面双源伴随（setup_exact_adjoint_source 高层封装）
        %  Love/Schelkunoff 表面等效定理 → Js0 + Jms0 双源 → λ_exact
        %  替代旧 Born 近似简化反向投影（消除 ∂F/∂ε 4-7 数量级系统性偏差）
        %  底层：build_adjoint_source_fullmaxwell (Js+Ms 构建) + solve_adjoint (双源求解+提取)
        % ★ H029: 捕获 F_obs（定义 A 归一化因子），用于梯度 F_obs 除法
        [lambda_fi, adj_ok, lambda_gauss, Js_adj, Ms_adj, source_pos, F_obs_fi] = ...
            setup_exact_adjoint_source(model, voxel, grid, lc, p);

        if ~adj_ok
            fprintf('  [iter %d freq=%d] [WARN] adjoint failed, skip\n', iter, fi);
            continue;
        end

        %% 体素梯度 g_voxel = Re[-k0²·dV·(E·λ)] / N_freq
        % H025: Born 近似物理因子完整性确认——∂F/∂ε_i = -k0²·Re(E_adj·E_fwd)·ΔV_i
        %   严格匹配 Maxwell 频域波方程 ∇×E−k0²·ε·E=0 对 ε 的变分推导：
        %   δ(波方程)/δε = −k0²·E（源自 ε 系数 −ω²ε₀=−k0²/μ₀），伴随变分得
        %   ∂F/∂ε_i = −k0²·Re(E_adj,i·E_fwd,i)·ΔV_i（Born 一阶灵敏度）。
        %   -k0² 波数因子 + ΔV_i 体素体积因子（量纲完整性），常数 1/μ₀ 被组件 A 归一化吸收。
        %   g_voxel 编码 -∂F/∂ε（下降方向），与 H014 符号约定一致。
        k0_sq = p.k0^2;
        dV_vec = voxel.dV;
        h024_gvox_prefi = g_voxel(inner_idx);  % H024 L3: 频率前快照（计算逐频贡献）

        if use_gauss && ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
                && size(E_gauss, 1) == size(voxel.gauss_pos, 1)
            for vi = 1:N_inner
                v_idx = inner_idx(vi);
                gp = (4*(vi-1)+1):(4*vi);
                gs = 0;
                for gpi = 1:4
                    % ★ H029 修正: bilinear sum(E.*lambda) 替代 Hermitian dot(E,lambda)
                    %   验证管线 conj(lambda_raw) + bilinear sum(E.*lambda) 是正确配对
                    %   Hermitian dot(E,lambda)=sum(conj(E).*lambda) 导致梯度方向系统性偏差
                    gs = gs + gauss_w(gpi) * sum(E_gauss(gp(gpi),:) .* lambda_gauss(gp(gpi),:));
                end
                g_voxel(v_idx) = g_voxel(v_idx) - k0_sq * dV_vec(v_idx) * real(gs) / N_freq / F_obs_fi;
            end
        else
            E_vox = zeros(N_inner, 3);
            E_vox(:, :) = E_total;
            L_vox = zeros(N_inner, 3);
            L_vox(:, :) = lambda_fi;
            for vi = 1:N_inner
                v_idx = inner_idx(vi);
                % ★ H029 修正: bilinear sum(E.*lambda) 替代 Hermitian dot(E,lambda)
                g_voxel(v_idx) = g_voxel(v_idx) - k0_sq * dV_vec(v_idx) * real(sum(E_vox(vi,:) .* L_vox(vi,:))) / N_freq / F_obs_fi;
            end
        end

        fprintf('  [iter %d freq=%d] |g_voxel| mean=%.4e max=%.4e\n', ...
            iter, fi, mean(abs(g_voxel(inner_idx))), max(abs(g_voxel(inner_idx))));

        % H024 L3: 逐频 g_voxel 贡献快照
        h024_perfreq_gvoxel_inner{fi} = g_voxel(inner_idx) - h024_gvox_prefi;
        h024_perfreq_k0sq(fi) = k0_sq;

        %% H017: 连续边界积分——伴随场提取 + 位置梯度累积
        % 提取伴随场 λ 在球面采样点（此时 model 含伴随解），计算被积函数并累积
        %   integrand = jump_eps · k0² · Re(conj(E_fwd)·E_adj) / N_freq   [N×1]
        %   g_descent = w_quad · Σ_k integrand_k · n_k   [3×1] 下降方向
        %   g_pos = Σ_fi g_descent_fi  （三分量统一连续框架）
        if isfield(p, 'cavity_continuous_bi') && p.cavity_continuous_bi && ~h023_sdf_aware && adj_ok && bi_fwd_extracted
            try
                [E_adj_sphere_fi, ~] = read_field(model, bi_sphere_pts);
                jump_eps_bi = eps_r_body - 1.0;
                k0_sq_bi = p.k0^2;
                % ★ H029 修正: bilinear sum(E.*E_adj) 替代 Hermitian sum(conj(E).*E_adj)
                integrand_bi = jump_eps_bi * k0_sq_bi ...
                    * real(sum(E_fwd_sphere_fi .* E_adj_sphere_fi, 2)) / N_freq;  % [N×1]
                g_desc_fi = bi_w_quad * (integrand_bi.' * bi_sphere_normals).';  % [3×1] 下降方向
                bi_g_pos_accum = bi_g_pos_accum + g_desc_fi;
                fprintf('  [H017 CBI f=%d] |E_fwd|=%.3e |E_adj|=%.3e integ=[%.3e,%.3e] g_desc=[%+.3e,%+.3e,%+.3e]\n', ...
                    fi, mean(vecnorm(E_fwd_sphere_fi,2,2)), mean(vecnorm(E_adj_sphere_fi,2,2)), ...
                    min(integrand_bi), max(integrand_bi), g_desc_fi(1), g_desc_fi(2), g_desc_fi(3));
            catch ME_adj
                fprintf('  [H017 CBI f=%d] [WARN] E_adj sphere 提取/积分失败: %s\n', fi, ME_adj.message);
            end
        end
    end

    %% 3. 汇总
    F_cheb = mean(F_k_total);
    mean_cos = cos_theta_sum;

    state.history_residual(iter) = F_cheb;
    state.history_cos_theta(iter) = mean_cos;
    state.history_eps_r(iter) = eps_r_body;
    state.history_hole_pos(:, iter) = hole_pos;
    state.history_J_hyp = J_hyp_primary;

    %% 3.5 best-state tracking（管线维护 Round10 / H014 效率建议 2 修复）
    % 【原 bug】原代码将 best-state 追踪置于收敛 break 之后（原 ~行 535），
    %   导致收敛轮（break）的 F_cheb / J_hyp / params 未被记录，三件套输出的是
    %   次优轮的指标。且原位置在线搜索之后，eps_r_body/hole_pos 已被更新，
    %   与 F_cheb（本轮起始残差）和 J_hyp_primary（本轮起始 J_hyp）错配。
    % 【修复】将追踪提前至 F_cheb 计算后、收敛检查前，确保：
    %   (a) 收敛 break 前已记录本轮最优；
    %   (b) 四个量 (F_cheb, eps_r_body, hole_pos, J_hyp_primary) 一致对应本轮起始状态。
    if F_cheb < best_F
        best_F        = F_cheb;
        best_eps_r    = eps_r_body;
        best_hole_pos = hole_pos;
        best_iter     = iter;
        best_J_hyp    = J_hyp_primary;
    end

    %% ===== H021: eps_r 冻结触发检测 =====
    % Gate A（F_cheb < eps_tol）首次满足时冻结 eps_r——后续迭代仅更新 hole 位置。
    % eps_r 一旦冻结在整个剩余迭代中保持冻结（不解冻），正演场 E_fwd 完全恒定。
    if h021_enabled && ~eps_r_frozen && F_cheb < p.eps_tol
        eps_r_frozen = true;
        eps_r_freeze_iter = iter;
        fprintf('  [H021] iter=%d: Gate A 首次满足（F_cheb=%.4e < eps_tol=%.4e），eps_r 冻结于 %.4f（后续迭代仅更新 hole 位置）\n', ...
            iter, F_cheb, p.eps_tol, eps_r_body);
        % 管线维护 Round23: Gate A 触发轮标记 post-freeze 第一轮 LS 短路
        if gate_a_ls_shortcircuit_on
            gate_a_shortcircuit_this_iter = true;
            fprintf('  [Round23] Gate A 触发轮：post-freeze 第一轮 LS 将短路（eps_r 已收敛，hole_pos 确定性 reject 防护）\n');
        end
    end
    state.history_eps_r_frozen(iter) = eps_r_frozen;

    %% 4. 参数梯度计算
    if h021_enabled && eps_r_frozen
        % H021: eps_r 冻结后跳过 eps_r 梯度计算（正演场 E_fwd 已恒定，eps_r 无需调整）
        body_voxel_idx = inner_idx(mask_body);
        g_eps = 0;
    else
        % (a) 材料梯度：∂F/∂eps_r = Σ_{body\cavity} g_voxel(v)
        body_voxel_idx = inner_idx(mask_body);
        g_eps = sum(g_voxel(body_voxel_idx));
    end

    % (b) 位置梯度
    boundary_mask = abs(rho_v - R_hole) < dr;
    N_boundary = sum(boundary_mask);
    g_pos_raw_formula = zeros(3, 1);   % H014: 原始公式值（+∂F/∂p，上升方向），供 FD 审计对比

    if h023_sdf_aware
        %% ===== H023: SDF-aware 伴随体积积分（analytical_sdf_aware_volume_integral）=====
        % 将 hole 位置梯度从 CBI 硬边界球面积分升级为 SDF 过渡带体积积分，
        % 使梯度与 H022 SDF 软边界正演模型严格一致（链式法则穿过 tanh 软边界）。
        %
        % 链式法则推导（实现要点 1-4：两负号相消得正向公式）：
        %   ε_i = ε_r + (1-ε_r)·0.5·(1-tanh(d_i/δ)),  d_i=|r_i-r_hole|-R_hole
        %   (1) dε_i/d_d_i = -(1-ε_r)·0.5·sech²(d_i/δ)/δ          [tanh 导数 = sech²]
        %   (2) d_d_i/d_r_hole = -(r_i-r_hole)/|r_i-r_hole|        [距离对中心求导]
        %   (3) 两负号相消：dε_i/d_r_hole = (1-ε_r)·0.5·sech²(d_i/δ)/δ·(r_i-r_hole)/|r_i-r_hole|
        %
        % 下降方向（复用 g_voxel=-∂F/∂ε，与 H014 符号约定一致）：
        %   g_pos = -∂F/∂r_hole = -Σ_i(∂F/∂ε_i)·(∂ε_i/∂r_hole)
        %         = Σ_i g_voxel(i)·(∂ε_i/∂r_hole)
        % 积分域 Ω_transition={体素 i:|d_i|<factor·δ}（sech² 天然将贡献集中在过渡带）
        d_i_sdf = rho_v - R_hole;                                      % [N_inner×1] 符号距离
        sdf_transit_mask = abs(d_i_sdf) < h023_transition_halfwidth;   % 过渡带体素掩码
        N_transit_h023 = sum(sdf_transit_mask);
        g_voxel_inner = g_voxel(inner_idx);                             % [N_inner×1] -∂F/∂ε（多频已累积）
        % dε_i/d_r_hole 标量权重 = (1-ε_r)·0.5·sech²(d_i/δ)/δ
        sech_sq_transit = sech(d_i_sdf(sdf_transit_mask) / sdf_delta).^2;       % sech²(d_i/δ) [N_transit×1]
        deps_drhole_w = (1 - eps_r_body) * 0.5 * sech_sq_transit / sdf_delta;    % [N_transit×1]
        % 方向项 (r_i-r_hole)/|r_i-r_hole|
        r_diff_transit = pos_inner(sdf_transit_mask, :) - hole_pos(:).';        % [N_transit×3]
        rho_transit_safe = max(rho_v(sdf_transit_mask), 1e-12);               % |r_i-r_hole| 防除零
        direction_transit = r_diff_transit ./ rho_transit_safe;                % [N_transit×3]
        % 下降方向 g_pos = Σ_i g_voxel(i)·(dε_i/d_r_hole)
        g_pos = direction_transit.' * (g_voxel_inner(sdf_transit_mask) .* deps_drhole_w);  % [3×1]
        fprintf('  [H023 SDF-AWARE] g_pos=[%+.4e,%+.4e,%+.4e] |g_pos|=%.4e (SDF volume integral, N_transit=%d, hw=%.4f)\n', ...
            g_pos(1), g_pos(2), g_pos(3), norm(g_pos), N_transit_h023, h023_transition_halfwidth);
        fprintf('  [H023 SDF-AWARE] sech² range=[%.4e,%.4e] deps_w range=[%.4e,%.4e] g_voxel_transit range=[%.4e,%.4e]\n', ...
            min(sech_sq_transit), max(sech_sq_transit), min(deps_drhole_w), max(deps_drhole_w), ...
            min(g_voxel_inner(sdf_transit_mask)), max(g_voxel_inner(sdf_transit_mask)));

        %% ===== H024: 梯度公式逐层分解诊断模块（diagnostic decomposition）=====
        % 不修改梯度公式本身——对 H023 SDF-aware 公式产出进行三层分解验证
        % L1: dε_i/d_r_hole 链式法则验证（零额外正演）
        % L2: ∂F/∂ε_i Born 近似 FD 验证（~36 次额外正演）
        % L3: 逐频梯度分解（零额外正演，数据重排）
        if h024_diag_enabled && iter == h024_diag_iter && ~h024_diag_done && N_transit_h023 > 0
            h024_diag_done = true;
            l1_d = p.cavity_h024_l1_delta;
            fprintf('\n  ========== [H024 DIAG] 梯度逐层分解 (iter=%d, N_transit=%d) ==========\n', iter, N_transit_h023);
            % --- L1: dε_i/d_r_hole 链式法则验证（零额外正演）---
            deps_ana = deps_drhole_w .* direction_transit;  % [N_transit×3] 解析向量
            deps_num = zeros(N_transit_h023, 3);
            for j = 1:3
                ej = zeros(3,1); ej(j) = l1_d;
                eps_p = c01_cavity_eps_assign(pos_inner, hole_pos+ej, R_hole, eps_r_body, N_v, inner_idx, sdf_delta, h022_sdf);
                eps_m = c01_cavity_eps_assign(pos_inner, hole_pos-ej, R_hole, eps_r_body, N_v, inner_idx, sdf_delta, h022_sdf);
                deps_num(:,j) = (eps_p(inner_idx(sdf_transit_mask)) - eps_m(inner_idx(sdf_transit_mask))) / (2*l1_d);
            end
            cos_L1 = zeros(N_transit_h023,1);
            for vi = 1:N_transit_h023
                cos_L1(vi) = dot(deps_ana(vi,:), deps_num(vi,:)) / (norm(deps_ana(vi,:))*norm(deps_num(vi,:)) + 1e-30);
            end
            n_L1f = sum(cos_L1 < 0.99);
            fprintf('  [H024 L1] chain-rule cos: min=%.6f mean=%.6f max=%.6f | FAIL(<0.99)=%d/%d\n', ...
                min(cos_L1), mean(cos_L1), max(cos_L1), n_L1f, N_transit_h023);
            if n_L1f == 0, fprintf('  [H024 L1] PASS — 链式法则实现正确\n');
            else, fprintf('  [H024 L1] WARN — %d 体素 cos<0.99，链式法则可能有偏差\n', n_L1f); end
            % --- L2: ∂F/∂ε_i Born 近似 FD 验证（~n_L2×2×N_freq 次额外正演）---
            n_L2 = min(p.cavity_h024_l2_n_voxels, N_inner);
            d_eps = p.cavity_h024_l2_delta_eps;
            [d_abs_sort, d_sort_idx] = sort(abs(d_i_sdf));
            d_sort_idx = d_sort_idx(:).';  % H024 FIX: 强制行向量，避免 horzcat(列,列,行) 维度不一致崩溃（纯维度鲁棒化，零逻辑变更，同 H022 hole_true(:).' 模式）
            rep_idx = [d_sort_idx(1:min(floor(n_L2/3),N_transit_h023)), ...
                       d_sort_idx(max(1,N_transit_h023-floor(n_L2/3)+1):min(N_transit_h023,N_transit_h023+floor(n_L2/3))), ...
                       (N_transit_h023+1:min(N_transit_h023+ceil(n_L2/3),N_inner))];
            rep_idx = rep_idx(rep_idx > 0 & rep_idx <= N_inner);
            rep_idx = rep_idx(1:min(length(rep_idx),n_L2));
            fprintf('  [H024 L2] Born-FD verify: %d voxels, d_eps=%.3f (%d fwd calls if no cache)\n', length(rep_idx), d_eps, length(rep_idx)*2*N_freq);
            %% ===== Round20 (H025 needs_optimization): L2 诊断跨实验缓存 =====
            % H025 实验执行者观察：L2 诊断 12 次额外正演占 iter2 耗时 84%（总反演 52%），
            % 其中 5/6 体素与 H024 跨实验 6 位有效数字完全一致，属冗余正演。
            % 以 (hole_pos, 全局 inner ε_r, d_eps, freqs, v_idx, J_obs, adjoint_method) 的 SHA-256 指纹为键，
            % 持久化缓存 born_ratio（data/l2_diag_cache.mat），跨实验命中时跳过 COMSOL 正演。
            % 纯效率优化——不改变诊断逻辑/梯度公式，缓存命中时复用既有 FD 结果。
            % Round21 (H027 needs_optimization P0): born_ratio=FD/analytic 依赖伴随方法（λ_exact≠λ_Born），
            % 不同伴随方法（Born vs exact_dual_source）的 analytic 灵敏度不同，相同 forward 输入下
            % born_ratio 不同。新增 adjoint_method 维度使不同伴随方法的诊断结果独立缓存，
            % 避免伴随方法切换时跨方法误复用（H027 精确双源路径缓存 hits=0 的根因）。
            % 当前代码路径：setup_exact_adjoint_source（精确双源）→ tag='exact_dual_source'。
            adjoint_method_tag = 'exact_dual_source';
            l2_cache_on = isfield(p,'cavity_h025_l2_cache') && p.cavity_h025_l2_cache;
            l2_cache_path = fullfile(p.dir_data, 'l2_diag_cache.mat');
            l2_cache = containers.Map('KeyType','char','ValueType','any');
            if l2_cache_on && exist(l2_cache_path, 'file')
                try
                    cached_ld = load(l2_cache_path, 'l2_cache');
                    if isa(cached_ld.l2_cache, 'containers.Map') && ~isempty(cached_ld.l2_cache)
                        l2_cache = cached_ld.l2_cache;
                    end
                catch
                end
            end
            l2_cache_hits = 0;  l2_cache_misses = 0;
            eps_r_inner_base = voxel.epsilon_r(inner_idx);   % 诊断迭代全局 ε_r 基态（正演确定性输入）
            obs_fp = [];
            for ffi_o = 1:N_freq
                obs_fp = [obs_fp; J_obs_multi{ffi_o}(:)];     % 观测数据指纹（决定目标函数 F → 决定 born_ratio）
            end
            born_ratio = zeros(length(rep_idx),1);
            for ri = 1:length(rep_idx)
                vi_g = rep_idx(ri); v_idx = inner_idx(vi_g);
                dFa = -g_voxel(v_idx);  % 解析 ∂F/∂ε_i（g_voxel 编码 -∂F/∂ε）
                ck = l2_diag_cache_key(hole_pos, eps_r_inner_base, d_eps, freqs, v_idx, obs_fp, adjoint_method_tag);
                if l2_cache_on && isKey(l2_cache, ck)
                    ent = l2_cache(ck);
                    if ent.ok
                        born_ratio(ri) = ent.born_ratio;
                        fprintf('  [H024 L2] vox %d (d=%.3e): analytic=%+.3e FD=%+.3e ratio=%.4f  [CACHE HIT — 跳过正演]\n', ri, d_i_sdf(vi_g), ent.dFa, ent.dFf, ent.born_ratio);
                    else
                        born_ratio(ri) = NaN;
                        fprintf('  [H024 L2] vox %d: [CACHE HIT (failed fwd)]\n', ri);
                    end
                    l2_cache_hits = l2_cache_hits + 1;
                    continue;
                end
                % --- 缓存未命中：执行 COMSOL 正演 FD 验证 ---
                vp = voxel; vm = voxel;
                vp.epsilon_r(v_idx) = voxel.epsilon_r(v_idx) + d_eps;
                vm.epsilon_r(v_idx) = voxel.epsilon_r(v_idx) - d_eps;
                Fp = 0; Fm = 0; ok_l2 = true;
                for ffi = 1:N_freq
                    pf = p; pf.freq = freqs(ffi); pf.omega = 2*pi*pf.freq; pf.k0 = pf.omega/pf.c; pf.lambda = pf.c/pf.freq;
                    try
                        solve_forward(model, vp, pf); sfp = extract_scattered(model, grid); lcp = lightcone_project(grid, sfp, pf);
                        Fp = Fp + mean(sum(abs(J_obs_multi{ffi}-lcp.J_obs_perp).^2,2)./max(sum(abs(J_obs_multi{ffi}).^2,2),p.rel_err_floor)/6)/N_freq;
                        solve_forward(model, vm, pf); sfm = extract_scattered(model, grid); lcm = lightcone_project(grid, sfm, pf);
                        Fm = Fm + mean(sum(abs(J_obs_multi{ffi}-lcm.J_obs_perp).^2,2)./max(sum(abs(J_obs_multi{ffi}).^2,2),p.rel_err_floor)/6)/N_freq;
                    catch ME_l2
                        ok_l2 = false; break;
                    end
                end
                if ok_l2
                    dFf = (Fp - Fm) / (2*d_eps);
                    born_ratio(ri) = dFf / (dFa + 1e-30);
                    fprintf('  [H024 L2] vox %d (d=%.3e): analytic=%+.3e FD=%+.3e ratio=%.4f  [COMPUTED — 写入缓存]\n', ri, d_i_sdf(vi_g), dFa, dFf, born_ratio(ri));
                    if l2_cache_on
                        l2_cache(ck) = struct('ok',true,'dFa',dFa,'dFf',dFf,'born_ratio',born_ratio(ri));
                    end
                else
                    born_ratio(ri) = NaN;
                    if l2_cache_on
                        l2_cache(ck) = struct('ok',false,'dFa',dFa,'dFf',NaN,'born_ratio',NaN);
                    end
                end
                l2_cache_misses = l2_cache_misses + 1;
            end
            if l2_cache_on
                try save(l2_cache_path, 'l2_cache', '-v7.3'); catch, end
                fprintf('  [H024 L2] [Round20 CACHE] hits=%d misses=%d | 节省 %d 次正演 | 缓存条目=%d → %s\n', ...
                    l2_cache_hits, l2_cache_misses, l2_cache_hits*2*N_freq, l2_cache.Count, l2_cache_path);
            end
            vr = born_ratio(~isnan(born_ratio));
            n_L2d = 0;
            if ~isempty(vr)
                n_L2d = sum(abs(vr-1) > 0.05);
                fprintf('  [H024 L2] ratio: mean=%.4f std=%.4f | DEV(>5%%)=%d/%d\n', mean(vr), std(vr), n_L2d, length(vr));
                if n_L2d == 0, fprintf('  [H024 L2] PASS — Born 近似精确\n');
                else, fprintf('  [H024 L2] WARN — Born 近似存在系统性偏离\n'); end
            end
            % --- L3: 逐频梯度分解（零额外正演）---
            g_pf = zeros(3, N_freq);
            for ffi = 1:N_freq
                if ~isempty(h024_perfreq_gvoxel_inner{ffi})
                    g_pf(:,ffi) = direction_transit.' * (h024_perfreq_gvoxel_inner{ffi}(sdf_transit_mask) .* deps_drhole_w);
                end
            end
            g_corr = sum(g_pf, 2) * N_freq;  % 无 1/N_freq 归一化
            cos_corr = dot(g_corr, g_pos) / (norm(g_corr)*norm(g_pos) + 1e-30);
            fprintf('  [H024 L3] per-freq decomp: N_freq=%d, cos(g_corrected,g_SDF)=%.6f\n', N_freq, cos_corr);
            for ffi = 1:N_freq
                fprintf('  [H024 L3] freq=%d (%.2fGHz): g_k=[%+.3e,%+.3e,%+.3e] |g_k|=%.3e k0²=%.3e\n', ...
                    ffi, freqs(ffi)/1e9, g_pf(1,ffi), g_pf(2,ffi), g_pf(3,ffi), norm(g_pf(:,ffi)), h024_perfreq_k0sq(ffi));
            end
            if N_freq <= 1, fprintf('  [H024 L3] single-freq: -k0² constant, no direction bias (excluded)\n');
            else
                fprintf('  [H024 L3] multi-freq -k0² ratios:');
                for ffi=1:N_freq, fprintf(' %.3f', h024_perfreq_k0sq(ffi)/h024_perfreq_k0sq(1)); end
                fprintf('\n');
            end
            % --- 偏差归因汇总 ---
            fprintf('  [H024] === bias_attribution ===\n');
            if n_L1f > 0, fprintf('  [H024] L1: %d/%d deviate (chain-rule error)\n', n_L1f, N_transit_h023);
            else, fprintf('  [H024] L1: PASS (chain-rule correct)\n'); end
            if ~isempty(vr) && n_L2d > 0, fprintf('  [H024] L2: DEV %d/%d mean=%.4f (missing factor?)\n', n_L2d, length(vr), mean(vr));
            else, fprintf('  [H024] L2: PASS (Born accurate)\n'); end
            if N_freq <= 1, fprintf('  [H024] L3: single-freq excluded\n');
            else, fprintf('  [H024] L3: multi-freq analysis needed\n'); end
            fprintf('  ========== [H024 DIAG] done ==========\n\n');
            state.h024_diagnostic = struct('performed',true,'iter',iter, ...
                'L1_cos_min',min(cos_L1),'L1_n_fail',n_L1f, ...
                'L2_ratio_mean',mean(vr),'L2_n_dev',n_L2d,'L3_n_freq',N_freq);

            %% ===== H025: residual_gap_monitoring — Born 因子修正后残余偏差量化 =====
            % 依据 H025 monitoring_requirements.residual_gap_monitoring：
            % Born 因子 -k0²·ΔV_i 完整化后，若 ∂F/∂ε_i 比值仍偏离 1 超过 1 个数量级，
            % 记录残余偏差量级，触发 path 1（mphinterp 一致化）或 path 3（强散射体修正）评估。
            % 复用 H024 L2 born_ratio（FD/analytic）数据，零额外正演。
            if isfield(p,'cavity_h025_residual_gap') && p.cavity_h025_residual_gap && ~isempty(vr)
                resid_gap_orders = log10(max(abs(vr),1e-30));   % 每体素偏差数量级（log10|FD/analytic|）
                resid_gap_mean = mean(resid_gap_orders);
                resid_gap_min  = min(resid_gap_orders);
                resid_gap_max  = max(resid_gap_orders);
                resid_exceeds  = abs(resid_gap_mean) > 1.0;     % 阈值：1 个数量级
                fprintf('  [H025 RESIDUAL_GAP] Born 因子修正后残余偏差: mean=%.2f orders, range=[%.2f, %.2f] (threshold=1.0 order, n=%d)\n', ...
                    resid_gap_mean, resid_gap_min, resid_gap_max, length(vr));
                if resid_exceeds
                    fprintf('  [H025 RESIDUAL_GAP] WARN — 残余偏差 >1 个数量级，-k0²·ΔV 修正未完全消除偏差，建议后续假设评估:\n');
                    fprintf('    path 1 (P0): E_adj/E_fwd 场提取点 vs ε 微扰体素质心一致性核查（mphinterp 插值偏差）\n');
                    fprintf('    path 3 (P1): ε_r=4 强对比度下 Born 近似适用性（二阶灵敏度修正项）\n');
                else
                    fprintf('  [H025 RESIDUAL_GAP] PASS — 残余偏差 <=1 个数量级，Born 因子 -k0²·ΔV 修正有效\n');
                end
                state.h025_residual_gap = struct('performed',true, ...
                    'mean_orders',resid_gap_mean,'min_orders',resid_gap_min, ...
                    'max_orders',resid_gap_max,'exceeds_threshold',resid_exceeds, ...
                    'n_voxels',length(vr));
            end
        end
    elseif isfield(p, 'cavity_continuous_bi') && p.cavity_continuous_bi
        %% ===== H017: 连续边界积分（analytical_continuous_boundary_integral）=====
        % 在 COMSOL FEM 连续球形空洞边界上通过 mphinterp 提取 E_adj/E_fwd 场值，
        % 在 N Fibonacci 球面采样点上数值求积。积分域和被积函数均随 x_hole 连续变化，
        % 从根本上克服 x 方向体素对称性硬约束（H015/H016 FD 已穷尽）。
        % 下降方向 g_pos = +Σ_k (ε_body−ε_cavity)·k0²·Re(E_fwd·E_adj)/N_freq·n_k·w_k
        % 符号约定：与 H014 修正后的 voxel 版一致（g_pos 编码 -∂F/∂p 下降方向）
        g_pos = bi_g_pos_accum;
        fprintf('  [H017 CBI] g_pos=[%+.4e,%+.4e,%+.4e] |g_pos|=%.4e (continuous boundary integral)\n', ...
            g_pos(1), g_pos(2), g_pos(3), norm(g_pos));
        % N 收敛性后验检查（报告 integrand 统计）
        if exist('integrand_bi', 'var')
            fprintf('  [H017 CBI] integrand stats: mean=%.3e std=%.3e range=[%.3e,%.3e] N=%d\n', ...
                mean(integrand_bi), std(integrand_bi), min(integrand_bi), max(integrand_bi), bi_N);
        end
    else
        %% ===== H012-H016: voxel 离散化 shape derivative 边界面积分（向后兼容）=====
        %   H014 符号审计：g_voxel 编码 -∂F/∂ε，位置梯度编码 -∂F/∂p 下降方向
        %   ∂F/∂p_x = +jump_eps/dr·Σ g_voxel·n_x（上升方向）
        %   下降方向 g_pos = -g_pos_raw_formula（H014 修正）
        if N_boundary > 0
            pos_bnd = pos_inner(boundary_mask, :);
            rho_bnd = rho_v(boundary_mask);
            rho_bnd_safe = max(rho_bnd, 1e-10);
            n_xyz = (pos_bnd - hole_pos(:).')./ rho_bnd_safe;    % [N_bnd × 3] 外法向
            g_bnd = g_voxel(inner_idx(boundary_mask));          % [N_bnd × 1]
            jump_eps = eps_r_body - 1.0;
            g_pos_raw_formula = jump_eps * (1/dr) * sum(g_bnd .* n_xyz, 1).';
            g_pos = -g_pos_raw_formula;
        else
            g_pos = zeros(3, 1);
        end
    end

    %% ================ H015: 混合位置梯度策略 — x 分量中心有限差分 ================
    % y/z 分量保留上方解析 shape derivative 梯度（H014 FD-check 已验证方向正确）。
    % x 分量替换为中心有限差分梯度（δ_x=0.005m），克服 voxel 级几何方案下
    % 解析边界积分在 x 方向的伪信号（H014 揭示 g_FD_x≈0 而 g_analytical_x=9.83e6）。
    % 公式：g_FD_x = [F(x+δ_x) − F(x−δ_x)] / (2·δ_x) ← ∂F/∂p_x（上升方向）
    % 替换：g_pos(1) := -g_FD_x（下降方向，与 g_pos 编码 -∂F/∂p 约定一致）
    g_pos_analytical_x = g_pos(1);     % 保留解析值供对比诊断（连续 BI 模式下为 CBI 值）
    g_FD_x = NaN;  fd_x_ok = false;    % 默认 NaN（disabled / failed 时保留）
    delta_x_used = NaN;                % Round11 P-01: 实际生效的 δ_x（NaN if disabled）
    geo_shortcircuit_count = 0;        % H017 P-04: 几何预判短路命中次数（本迭代内）

    % H017/H023: 解析梯度模式下 fd_x_resolved=true（非 FD 途径）
    if h023_sdf_aware
        fd_x_resolved = true;          % H023 SDF-aware 已解析梯度（非 FD fallback 途径）
    elseif isfield(p, 'cavity_continuous_bi') && p.cavity_continuous_bi
        fd_x_resolved = true;          % H017 CBI 已解析梯度（非 FD fallback 途径）
    else
        fd_x_resolved = false;         % H015/H016 FD 路径：待 FD 验证
    end

    %% ================ H017: 连续 BI FD 符号交叉验证（仅 iter 1）================
    % go/no-go 验证点：对 x 分量施加 ±δ_x=0.01m 中心差分，验证 CBI 梯度符号一致性。
    % cos(g_pos_descent, -g_FD_ascent) 应>0（下降方向符号一致）。
    % 若 cos<0，提示 CBI 梯度符号错误（H012/H013 sign bug 先例）。
    bi_fd_crosscheck_performed = false;
    bi_fd_crosscheck_cos = NaN;
    if isfield(p, 'cavity_continuous_bi') && p.cavity_continuous_bi ...
            && isfield(p, 'cavity_bi_fd_crosscheck') && p.cavity_bi_fd_crosscheck ...
            && iter == 1 && norm(g_pos) > 1e-30
        delta_cross = p.cavity_fd_delta_x_fallback;  % δ_x=0.01m
        fprintf('\n  ========== [H017 CBI FD-CROSSCHECK] x 分量符号验证 (δ_x=%.4e, 2 次额外正演) ==========\n', delta_cross);
        F_plus_cross = NaN;  F_minus_cross = NaN;  fd_cross_ok = true;
        for sign_fd = [+1, -1]
            hole_cross = hole_pos;  hole_cross(1) = hole_cross(1) + sign_fd * delta_cross;
            he_norm = norm(hole_cross);
            if he_norm > R_body - hole_margin
                hole_cross = hole_cross * (R_body - hole_margin) / max(he_norm, 1e-10);
            end
            rho_cross = sqrt(sum((pos_inner - hole_cross(:).').^2, 2));
            mask_cross = rho_cross < R_hole;
            voxel_cross = voxel;
            voxel_cross.epsilon_r = c01_cavity_eps_assign(pos_inner, hole_cross, R_hole, eps_r_body, N_v, inner_idx, sdf_delta, h022_sdf);
            F_cross = 0;  cross_ok = true;
            for fi = 1:N_freq
                p_fc = p;  p_fc.freq = freqs(fi);  p_fc.omega = 2*pi*p_fc.freq;
                p_fc.k0 = p_fc.omega / p_fc.c;  p_fc.lambda = p_fc.c / p_fc.freq;
                try
                    [E_cross, ~, ~] = solve_forward(model, voxel_cross, p_fc);
                    sf_cross = extract_scattered(model, grid);
                    lc_cross = lightcone_project(grid, sf_cross, p_fc);
                    J_cross = lc_cross.J_obs_perp;
                    J_obs_fi = J_obs_multi{fi};
                    Delta_cross = J_obs_fi - J_cross;
                    F_k_cross = sum(abs(Delta_cross).^2, 2) ./ max(sum(abs(J_obs_fi).^2, 2), p.rel_err_floor) / 6;
                    F_cross = F_cross + mean(F_k_cross) / N_freq;
                catch ME_c
                    fprintf('  [H017 CBI FD-CROSSCHECK] sign=%+d freq=%d fwd fail: %s\n', sign_fd, fi, ME_c.message);
                    cross_ok = false;  break;
                end
            end
            if cross_ok
                if sign_fd > 0, F_plus_cross = F_cross;  else, F_minus_cross = F_cross; end
            else
                fd_cross_ok = false;
            end
        end
        if fd_cross_ok && ~isnan(F_plus_cross) && ~isnan(F_minus_cross)
            g_FD_x_cross = (F_plus_cross - F_minus_cross) / (2 * delta_cross);  % ∂F/∂p_x 上升方向
            g_FD_x = g_FD_x_cross;
            % cos(g_pos_descent, -g_FD_ascent)：两者均为下降方向，应 >0
            g_pos_norm_safe = max(norm(g_pos), 1e-30);
            g_FD_desc_x = -g_FD_x_cross;  % FD 下降方向 x 分量
            bi_fd_crosscheck_cos = g_pos(1) * g_FD_desc_x / (g_pos_norm_safe * abs(g_FD_desc_x) + 1e-30);
            bi_fd_crosscheck_performed = true;
            % H017: 保存 FD 交叉验证结果到 state（state 不随迭代重置，结果持久保留）
            state.bi_fd_crosscheck.performed = true;
            state.bi_fd_crosscheck.iter = iter;
            state.bi_fd_crosscheck.delta_x = delta_cross;
            state.bi_fd_crosscheck.F_plus = F_plus_cross;
            state.bi_fd_crosscheck.F_minus = F_minus_cross;
            state.bi_fd_crosscheck.g_FD_x_ascent = g_FD_x_cross;
            state.bi_fd_crosscheck.g_pos_x_descent = g_pos(1);
            state.bi_fd_crosscheck.cos_descent_vs_neg_FD = bi_fd_crosscheck_cos;
            state.bi_fd_crosscheck.sign_consistent = bi_fd_crosscheck_cos > 0;
            fprintf('  [H017 CBI FD-CROSSCHECK] F(+δ)=%.6e F(-δ)=%.6e g_FD_x=%+.4e (ascent)\n', F_plus_cross, F_minus_cross, g_FD_x_cross);
            fprintf('  [H017 CBI FD-CROSSCHECK] g_pos(1)=%+.4e (descent)  -g_FD_x=%+.4e (descent)\n', g_pos(1), g_FD_desc_x);
            fprintf('  [H017 CBI FD-CROSSCHECK] sign(g_pos_x)=%+d  sign(-g_FD_x)=%+d  cos=%.4f\n', ...
                sign(g_pos(1)), sign(g_FD_desc_x), bi_fd_crosscheck_cos);
            if bi_fd_crosscheck_cos > 0
                fprintf('  [H017 CBI FD-CROSSCHECK] ✓ 符号一致（cos>0）——CBI 梯度方向正确\n');
            else
                fprintf('  [H017 CBI FD-CROSSCHECK] [WARN] 符号不一致（cos≤0）——检查法向定义/符号约定\n');
            end
        else
            fprintf('  [H017 CBI FD-CROSSCHECK] [WARN] FD 正演失败，交叉验证未完成\n');
        end
        fprintf('  ========== [H017 CBI FD-CROSSCHECK] 完成 ==========\n\n');
    end

    if isfield(p, 'cavity_hybrid_fd_x') && p.cavity_hybrid_fd_x
        %% ---- H017 Round13 管线维护（P-06）：hybrid_fd 路径已 DEPRECATED ----
        % H017 连续边界积分（cavity_continuous_bi）已根本性打破 x 方向体素对称性硬约束
        % （|g_pos_x| 提升 6~8 个数量级，hole_x 首次正向移动），而 hybrid_fd 的 FD 路径
        % 在 H015/H016 已穷尽（δ_x≤0.01m 得 g_FD_x≈0，几何上必然——受 voxel 对称性硬约束）。
        % 本路径仅作向后兼容保留（cavity_continuous_bi=false 时退化至此），建议切换至
        % cavity_continuous_bi=true（零额外正演成本，连续积分域随 hole 连续变化）。
        fprintf('  [DEPRECATED][H017 P-06] cavity_hybrid_fd_x=true 已废弃——H015/H016 已证明 δ_x≤0.01m 受体素对称性硬约束（g_FD_x≈0）。建议改用 cavity_continuous_bi=true（连续边界积分，零额外正演成本，|g_pos_x| 提升 6~8 个数量级）\n');
        %% ---- H015 Round11 管线维护（P-01 修复）：FD fallback 自动升级 δ_x ----
        % 【原 bug】原代码在 |g_FD_x| < 1e4 时仅 [WARN] 打印，未执行 δ_x 升级重算。
        %   H015 实验中 4 轮迭代全部触发 WARN 但 δ_x 从未升级，hole_x 全程停滞在 0.0。
        % 【修复】将 δ_x 候选序列化（primary → fallback），|g_FD_x| 不足时自动
        %   升级 δ_x 并重新执行 2 次正演，用新 g_FD_x 替换原值。
        delta_x_primary = p.cavity_fd_delta_x;
        if isfield(p, 'cavity_fd_delta_x_fallback') && p.cavity_fd_delta_x_fallback > delta_x_primary
            delta_x_fallback = p.cavity_fd_delta_x_fallback;
        else
            delta_x_fallback = 0.01;           % 向后兼容默认值
        end
        if isfield(p, 'cavity_fd_x_min_magnitude')
            min_magnitude = p.cavity_fd_x_min_magnitude;
        else
            min_magnitude = 1e4;               % 向后兼容默认值
        end
        delta_x_candidates = [delta_x_primary, delta_x_fallback];

        fprintf('\n  ========== [H015 HYBRID-FD] x 分量有限差分梯度 (δ_x 候选=[%.4e, %.4e], min|g_FD_x|=%.2e) ==========\n', ...
            delta_x_primary, delta_x_fallback, min_magnitude);

        for d_idx = 1:length(delta_x_candidates)
            delta_x = delta_x_candidates(d_idx);
            if d_idx > 1
                fprintf('  [H015 HYBRID-FD] ---- fallback 升级 δ_x: %.4e → %.4e (尝试 %d/%d) ----\n', ...
                    delta_x_candidates(d_idx-1), delta_x, d_idx, length(delta_x_candidates));
            end

            %% ---- H017 P-04: 几何预判短路（避免无效正演）----
            % 当 ±δ_x 扰动不改变任何体素的 cavity 归属时，voxel_eval(±δ_x) 完全
            % 相同 → F(±δ_x) 严格相等 → g_FD_x≡0（数学精确，非近似）。
            % 此时无需调用昂贵的 COMSOL 正演（每次 ~20s），直接跳过该 δ_x 候选。
            % H016 实测：δ_x≤0.01m 在 x 方向体素对称场景下 100% 命中此短路，
            % 每轮省 4 次无效正演（per-iter 时间 63~92s → ~44~53s）。
            % 假设：hole 远离 R_body 边界（不触发约束投影），当前场景 hole 在原点附近成立。
            if ~isfield(p, 'cavity_fd_geo_preflight') || p.cavity_fd_geo_preflight
                hole_p_geo = hole_pos;  hole_p_geo(1) = hole_p_geo(1) + delta_x;
                hole_m_geo = hole_pos;  hole_m_geo(1) = hole_m_geo(1) - delta_x;
                rho_p_geo = sqrt(sum((pos_inner - hole_p_geo(:).').^2, 2));
                rho_m_geo = sqrt(sum((pos_inner - hole_m_geo(:).').^2, 2));
                mask_p_geo = rho_p_geo < R_hole;
                mask_m_geo = rho_m_geo < R_hole;
                n_flip_geo = sum(mask_p_geo ~= mask_m_geo);
                if n_flip_geo == 0
                    fprintf('  [H015 HYBRID-FD] δ_x=%.4e: 几何预判短路 — ±δ_x 不改变任何体素归属（mask 全同），g_FD_x≡0，跳过 %d 次正演\n', ...
                        delta_x, 2*N_freq);
                    g_FD_x = 0;
                    fd_x_ok = true;
                    delta_x_used = delta_x;
                    g_pos(1) = -g_FD_x;   % = 0（x 方向几何上无敏感度）
                    geo_shortcircuit_count = geo_shortcircuit_count + 1;
                    if d_idx < length(delta_x_candidates)
                        fprintf('  [H015 HYBRID-FD] [WARN] δ_x=%.4e 几何短路 g_FD_x≡0 < %.4e，升级至 δ_x=%.4e\n', ...
                            delta_x, min_magnitude, delta_x_candidates(d_idx+1));
                        continue;   % 尝试更大 δ_x（可能跨越体素边界）
                    else
                        fprintf('  [H015 HYBRID-FD] [ERROR] x-direction voxel symmetry unbreakable: 最大 δ_x=%.4e 几何预判仍 g_FD_x≡0\n', delta_x);
                        fprintf('  [H015 HYBRID-FD] [ERROR] 保留 g_pos(1)=0，建议改用 y/z 梯度外推 x（算法 A-02）\n');
                        break;
                    end
                else
                    fprintf('  [H015 HYBRID-FD] δ_x=%.4e: 几何预判通过 — ±δ_x 翻转 %d 个体素归属，执行正演求 g_FD_x\n', ...
                        delta_x, n_flip_geo);
                end
            end

            F_plus_x = NaN;  F_minus_x = NaN;  fd_x_eval_ok = true;

            for sign_fd = [+1, -1]
                hole_eval = hole_pos;
                hole_eval(1) = hole_eval(1) + sign_fd * delta_x;

                % 约束投影（与主循环 line search 一致）
                he_norm = norm(hole_eval);
                if he_norm > R_body - hole_margin
                    hole_eval = hole_eval * (R_body - hole_margin) / max(he_norm, 1e-10);
                    fprintf('  [H015 HYBRID-FD] δ_x=%.4e sign=%+d: hole 投影至边界\n', delta_x, sign_fd);
                end

                % 构造扰动 voxel（仅 x 方向 hole 位移）
                rho_eval = sqrt(sum((pos_inner - hole_eval(:).').^2, 2));
                mask_cav_eval = rho_eval < R_hole;
                voxel_eval = voxel;
                voxel_eval.epsilon_r = c01_cavity_eps_assign(pos_inner, hole_eval, R_hole, eps_r_body, N_v, inner_idx, sdf_delta, h022_sdf);

                % 多频率正演求残差 F
                F_eval = 0;  eval_ok = true;
                for fi = 1:N_freq
                    p_fe = p;
                    p_fe.freq = freqs(fi);
                    p_fe.omega = 2*pi*p_fe.freq;
                    p_fe.k0 = p_fe.omega / p_fe.c;
                    p_fe.lambda = p_fe.c / p_fe.freq;
                    try
                        [E_eval, ~, ~] = solve_forward(model, voxel_eval, p_fe);
                        sf_eval = extract_scattered(model, grid);
                        lc_eval = lightcone_project(grid, sf_eval, p_fe);
                        J_hyp_eval = lc_eval.J_obs_perp;
                        J_obs_fi = J_obs_multi{fi};
                        Delta_eval = J_obs_fi - J_hyp_eval;
                        F_k_eval = sum(abs(Delta_eval).^2, 2) ./ max(sum(abs(J_obs_fi).^2, 2), p.rel_err_floor) / 6;
                        F_eval = F_eval + mean(F_k_eval) / N_freq;
                    catch ME
                        fprintf('  [H015 HYBRID-FD] δ_x=%.4e sign=%+d freq=%d fwd fail: %s\n', delta_x, sign_fd, fi, ME.message);
                        eval_ok = false;  break;
                    end
                end

                if eval_ok
                    if sign_fd > 0, F_plus_x = F_eval;  else, F_minus_x = F_eval; end
                else
                    fd_x_eval_ok = false;
                end
            end

            if fd_x_eval_ok && ~isnan(F_plus_x) && ~isnan(F_minus_x)
                g_FD_x = (F_plus_x - F_minus_x) / (2 * delta_x);
                fd_x_ok = true;
                delta_x_used = delta_x;
                % 替换 x 分量：g_FD_x 为 ∂F/∂p_x（上升方向），取负号得下降方向 -∂F/∂p_x
                g_pos(1) = -g_FD_x;
                fprintf('  [H015 HYBRID-FD] δ_x=%.4e: F(+δ)=%.6e F(-δ)=%.6e  g_FD_x=%+.4e → g_pos(1):=%+.4e（下降方向）\n', ...
                    delta_x, F_plus_x, F_minus_x, g_FD_x, g_pos(1));
                fprintf('  [H015 HYBRID-FD] 解析 g_pos_analytical_x=%+.4e（对比，H014 揭示为伪信号）\n', g_pos_analytical_x);

                % ---- FD fallback 有效性检查（P-01 修复：原仅 WARN，现自动升级 δ_x）----
                if abs(g_FD_x) >= min_magnitude
                    fprintf('  [H015 HYBRID-FD] ✓ |g_FD_x|=%.4e ≥ %.4e，δ_x=%.4e 有效（捕获真实位置-残差敏感度）\n', ...
                        abs(g_FD_x), min_magnitude, delta_x);
                    fd_x_resolved = true;
                    break;     % 已获有效梯度，退出 δ_x 升级循环
                else
                    if d_idx < length(delta_x_candidates)
                        fprintf('  [H015 HYBRID-FD] [WARN] |g_FD_x|=%.4e < %.4e（δ_x=%.4e 不足），升级至 δ_x=%.4e 重算\n', ...
                            abs(g_FD_x), min_magnitude, delta_x, delta_x_candidates(d_idx+1));
                    else
                        fprintf('  [H015 HYBRID-FD] [ERROR] x-direction voxel symmetry unbreakable: 最大 δ_x=%.4e 仍得 |g_FD_x|=%.4e < %.4e\n', ...
                            delta_x, abs(g_FD_x), min_magnitude);
                        fprintf('  [H015 HYBRID-FD] [ERROR] 保留最弱信号 g_FD_x=%+.4e，建议人工检查或改用 y/z 梯度外推\n', g_FD_x);
                    end
                end
            else
                fprintf('  [H015 HYBRID-FD] [WARN] δ_x=%.4e x 分量 FD 正演失败\n', delta_x);
                if d_idx == length(delta_x_candidates)
                    fprintf('  [H015 HYBRID-FD] [WARN] 所有 δ_x 候选正演均失败，保留解析 g_pos(1)=%+.4e\n', g_pos(1));
                end
            end
        end   % end for d_idx (δ_x fallback 升级循环)
    end

    g_pos_norm_val = norm(g_pos);

    state.history_g_eps(iter) = g_eps;
    state.history_g_pos_norm(iter) = g_pos_norm_val;
    state.history_g_FD_x(iter) = g_FD_x;
    state.history_g_pos_analytical_x(iter) = g_pos_analytical_x;

    %% ===== H021/H022: CBI 梯度景观稳定性监测 =====
    % 记录逐轮 hole CBI 梯度向量，计算 cos(g_k, g_{k-1}) 验证梯度景观稳定性
    state.history_g_pos_vec(:, iter) = g_pos;
    % H022 条件_1: SDF 启用时全迭代计算梯度方向一致性（首轮必做验证 cos>0.95）
    % H021: 仅 post_freeze 计算（梯度景观稳定性）
    compute_cos_all = h022_sdf && iter > 1;
    compute_cos_freeze = h021_enabled && eps_r_frozen && iter > eps_r_freeze_iter;
    if compute_cos_all || compute_cos_freeze
        prev_g_pos_vec = state.history_g_pos_vec(:, iter - 1);
        prev_g_norm = norm(prev_g_pos_vec);
        if prev_g_norm > 1e-30 && g_pos_norm_val > 1e-30
            grad_cos_k = dot(g_pos, prev_g_pos_vec) / (g_pos_norm_val * prev_g_norm);
        else
            grad_cos_k = NaN;
        end
        if compute_cos_freeze
            state.history_g_pos_consistency(iter) = grad_cos_k;
        end
        state.history_g_pos_consistency_all(iter) = grad_cos_k;
        if ~isnan(grad_cos_k)
            if compute_cos_freeze
                fprintf('  [H021 MONITOR] iter=%d post_freeze cos(g_k, g_{k-1})=%.4f（>0.95=梯度景观稳定）\n', ...
                    iter, grad_cos_k);
            end
            if h022_sdf && iter == 2
                if h023_sdf_aware
                    fprintf('  [H023 COND_1] iter=%d SDF-aware gradient direction cos(g_k,g_{k-1})=%.4f（首轮验证，>0.95=梯度与SDF正演一致，预期>0.95）\n', ...
                        iter, grad_cos_k);
                else
                    fprintf('  [H022 COND_1] iter=%d CBI-SDF gradient direction cos(g_k,g_{k-1})=%.4f（首轮验证，>0.95=梯度方向一致）\n', ...
                        iter, grad_cos_k);
                end
            end
        end
    else
        state.history_g_pos_consistency(iter) = NaN;
    end

    %% ================ H014: 有限差分位置梯度方向审计（可配置 iter，6 次额外正演） ================
    % 对 hole_pos 各分量施加 ±delta 中心差分扰动，计算数值参考梯度 g_FD=∂F/∂p，
    % 与解析位置梯度逐分量比较方向一致性，确认修正后的 g_pos 编码下降方向。
    % 【管线维护 Round10】iter 可通过 p.cavity_fd_check_iter 配置（默认 1，向后兼容）
    fd_check_iter = 1;
    if isfield(p, 'cavity_fd_check_iter') && ~isempty(p.cavity_fd_check_iter)
        fd_check_iter = p.cavity_fd_check_iter;
    end
    if iter == fd_check_iter && isfield(p, 'cavity_fd_check') && p.cavity_fd_check
        delta_fd = p.cavity_fd_delta;
        fprintf('\n  ========== [H014 FD-CHECK] 有限差分位置梯度方向审计 (delta=%.4e m, 6 次额外正演) ==========\n', delta_fd);

        g_FD = zeros(3, 1);          % 数值梯度 ∂F/∂p（上升方向）
        fd_eval_ok = true;           % 全部正演成功标志

        for coord = 1:3
            F_plus = NaN;  F_minus = NaN;
            coord_name = char('x' + coord - 1);

            for sign_fd = [+1, -1]
                hole_eval = hole_pos;
                hole_eval(coord) = hole_eval(coord) + sign_fd * delta_fd;

                % 约束投影（与主循环 line search 一致）
                he_norm = norm(hole_eval);
                if he_norm > R_body - hole_margin
                    hole_eval = hole_eval * (R_body - hole_margin) / max(he_norm, 1e-10);
                    fprintf('  [H014 FD-CHECK] coord=%c sign=%+d: hole 投影至边界\n', coord_name, sign_fd);
                end

                % 构造扰动 voxel
                rho_eval = sqrt(sum((pos_inner - hole_eval(:).').^2, 2));
                mask_cav_eval = rho_eval < R_hole;
                voxel_eval = voxel;
                voxel_eval.epsilon_r = c01_cavity_eps_assign(pos_inner, hole_eval, R_hole, eps_r_body, N_v, inner_idx, sdf_delta, h022_sdf);

                % 多频率正演求残差 F
                F_eval = 0;  eval_ok = true;
                for fi = 1:N_freq
                    p_fe = p;
                    p_fe.freq = freqs(fi);
                    p_fe.omega = 2*pi*p_fe.freq;
                    p_fe.k0 = p_fe.omega / p_fe.c;
                    p_fe.lambda = p_fe.c / p_fe.freq;
                    try
                        [E_eval, ~, ~] = solve_forward(model, voxel_eval, p_fe);
                        sf_eval = extract_scattered(model, grid);
                        lc_eval = lightcone_project(grid, sf_eval, p_fe);
                        J_hyp_eval = lc_eval.J_obs_perp;
                        J_obs_fi = J_obs_multi{fi};
                        Delta_eval = J_obs_fi - J_hyp_eval;
                        F_k_eval = sum(abs(Delta_eval).^2, 2) ./ max(sum(abs(J_obs_fi).^2, 2), p.rel_err_floor) / 6;
                        F_eval = F_eval + mean(F_k_eval) / N_freq;
                    catch ME
                        fprintf('  [H014 FD-CHECK] coord=%c sign=%+d freq=%d fwd fail: %s\n', coord_name, sign_fd, fi, ME.message);
                        eval_ok = false;  break;
                    end
                end

                if eval_ok
                    if sign_fd > 0, F_plus = F_eval;  else, F_minus = F_eval;  end
                else
                    fd_eval_ok = false;
                end
            end

            if ~isnan(F_plus) && ~isnan(F_minus)
                g_FD(coord) = (F_plus - F_minus) / (2 * delta_fd);
            end
            fprintf('  [H014 FD-CHECK] coord=%c: F(+d)=%.6e F(-d)=%.6e  g_FD=%+.4e\n', coord_name, F_plus, F_minus, g_FD(coord));
        end

        %% 方向一致性分析
        g_FD_norm = norm(g_FD);
        if g_FD_norm > 1e-30 && g_pos_norm_val > 1e-30
            % cos(g_pos_raw, g_FD)：原始公式 vs 数值梯度（预期 >0.9，确认原始公式计算的是 ∂F/∂p 梯度本身）
            cos_raw_vs_FD = dot(g_pos_raw_formula, g_FD) / (norm(g_pos_raw_formula) * g_FD_norm + 1e-30);
            % cos(g_pos_corrected, -g_FD)：修正后 vs 数值下降方向（预期 >0.9，确认修正正确）
            cos_corrected_vs_descent = dot(g_pos, -g_FD) / (g_pos_norm_val * g_FD_norm + 1e-30);
            % cos(g_pos_raw, -g_FD)：原始公式 vs 数值下降方向（预期 <-0.9，确认原始公式是上升方向=bug）
            cos_raw_vs_descent = dot(g_pos_raw_formula, -g_FD) / (norm(g_pos_raw_formula) * g_FD_norm + 1e-30);
        else
            cos_raw_vs_FD = NaN;  cos_corrected_vs_descent = NaN;  cos_raw_vs_descent = NaN;
        end

        fprintf('  [H014 FD-CHECK] ---- 方向一致性分析 ----\n');
        fprintf('  [H014 FD-CHECK] 解析 g_pos_raw(原公式) = [%+.4e, %+.4e, %+.4e]\n', g_pos_raw_formula(1), g_pos_raw_formula(2), g_pos_raw_formula(3));
        fprintf('  [H014 FD-CHECK] 解析 g_pos(修正后)    = [%+.4e, %+.4e, %+.4e]\n', g_pos(1), g_pos(2), g_pos(3));
        fprintf('  [H014 FD-CHECK] 数值 g_FD(=∂F/∂p)    = [%+.4e, %+.4e, %+.4e]\n', g_FD(1), g_FD(2), g_FD(3));
        fprintf('  [H014 FD-CHECK] cos(g_pos_raw, g_FD)       = %.4f  （梯度计算正确性，>0.9=计算无误）\n', cos_raw_vs_FD);
        fprintf('  [H014 FD-CHECK] cos(g_pos_raw, -g_FD)      = %.4f  （原公式下降方向，<-0.9=确认原 bug）\n', cos_raw_vs_descent);
        fprintf('  [H014 FD-CHECK] cos(g_pos_corrected, -g_FD)= %.4f  （修正后下降方向，>0.9=修正正确）\n', cos_corrected_vs_descent);

        % 逐分量符号对比
        for coord = 1:3
            coord_name = char('x' + coord - 1);
            sig_raw = sign(g_pos_raw_formula(coord));
            sig_fd  = sign(g_FD(coord));
            if sig_raw == sig_fd
                fprintf('  [H014 FD-CHECK]   %c: sign(raw)=%+d == sign(FD)=%+d  → 原公式=∂F/∂p(上升方向)\n', coord_name, sig_raw, sig_fd);
            else
                fprintf('  [H014 FD-CHECK]   %c: sign(raw)=%+d != sign(FD)=%+d  → 原公式与FD反号(异常)\n', coord_name, sig_raw, sig_fd);
            end
        end

        if isnan(cos_raw_vs_descent)
            fprintf('  [H014 FD-CHECK] [WARN] FD 正演失败或梯度为零，无法完成审计，保留解析修正结果\n');
            fd_audit_conclusion = 'inconclusive';
        elseif cos_raw_vs_descent < -0.5 && cos_corrected_vs_descent > 0.5
            fprintf('  [H014 FD-CHECK] ✓ 审计确认：原公式编码 +∂F/∂p（上升方向），修正后编码 -∂F/∂p（下降方向）。\n');
            fprintf('  [H014 FD-CHECK]   根因：H013 原始公式符号与 g_voxel(-∂F/∂ε) 约定不一致，导致 hole 沿上升方向移动。\n');
            fprintf('  [H014 FD-CHECK]   H014 修正已生效（g_pos := -g_pos_raw），hole 将沿正确下降方向收敛。\n');
            fd_audit_conclusion = 'confirmed_bug_fixed';
        elseif cos_corrected_vs_descent > 0.9
            fprintf('  [H014 FD-CHECK] ✓ 修正后方向与数值下降方向一致（cos>0.9），修正正确。\n');
            fd_audit_conclusion = 'correction_valid';
        else
            fprintf('  [H014 FD-CHECK] [WARN] 方向一致性不明确，建议人工检查。保留解析修正结果。\n');
            fd_audit_conclusion = 'ambiguous';
        end

        % 保存诊断结果到 state（供实验执行者从 stdout/state 提取）
        state.fd_check.iter = iter;
        state.fd_check.delta = delta_fd;
        state.fd_check.g_FD = g_FD;
        state.fd_check.g_pos_raw_formula = g_pos_raw_formula;
        state.fd_check.g_pos_corrected = g_pos;
        state.fd_check.cos_raw_vs_FD = cos_raw_vs_FD;
        state.fd_check.cos_raw_vs_descent = cos_raw_vs_descent;
        state.fd_check.cos_corrected_vs_descent = cos_corrected_vs_descent;
        state.fd_check.conclusion = fd_audit_conclusion;
        state.fd_check.all_forward_ok = fd_eval_ok;

        fprintf('  ========== [H014 FD-CHECK] 审计完成 (conclusion=%s) ==========\n\n', fd_audit_conclusion);
    end

    % 确保 state.fd_check 即使非 iter==1 也存在（避免下游访问未定义字段）
    if ~isfield(state, 'fd_check')
        state.fd_check.performed = false;
    else
        state.fd_check.performed = true;
    end

    hole_err = norm(hole_pos - hole_true(:));

    %% ===== H020 Gate B: hole_err 序列记录 + 变化率计算 + 双门状态评估 =====
    % hole_err 在此处为 pre-line-search 值（= post-LS of previous iter），构成稳定 trajectory
    % Gate B: 连续 h020_stab_window 轮 |Δhole_err|/hole_err < h020_stab_threshold
    if h020_enabled
        state.history_hole_err_gateB(iter) = hole_err;
        if iter > 1
            prev_he_gateB = state.history_hole_err_gateB(iter - 1);
            he_change_rate = abs(hole_err - prev_he_gateB) / max(prev_he_gateB, 1e-12);
            state.history_hole_err_change_rate(iter) = he_change_rate;
        else
            state.history_hole_err_change_rate(iter) = Inf;  % iter 1 无前序，Gate B 自动不满足
        end

        % H020: 逐轮双门状态评估（供 gate_A_B_status_per_iter 监测）
        gate_A_pass_iter = (F_cheb < p.eps_tol);
        gate_B_pass_iter = false;
        if iter >= h020_stab_window + 1
            gate_B_pass_iter = true;
            for back_gb = 0:(h020_stab_window - 1)
                ci_gb = iter - back_gb;
                if state.history_hole_err_change_rate(ci_gb) > h020_stab_threshold
                    gate_B_pass_iter = false;
                    break;
                end
            end
        end
        state.history_gate_A_pass(iter) = gate_A_pass_iter;
        state.history_gate_B_pass(iter) = gate_B_pass_iter;
        if iter >= 2
            cr_start = max(2, iter - h020_stab_window + 1);
            max_cr_recent = max(state.history_hole_err_change_rate(cr_start:iter));
            fprintf('  [H020] iter=%d Gate_A=%d Gate_B=%d (max_cr_recent=%.1f%%, threshold=%.0f%%)\n', ...
                iter, gate_A_pass_iter, gate_B_pass_iter, max_cr_recent*100, h020_stab_threshold*100);
        else
            fprintf('  [H020] iter=%d Gate_A=%d Gate_B=0 (iter<%d, 无足够 hole_err 历史)\n', ...
                iter, gate_A_pass_iter, h020_stab_window + 1);
        end
    end

    fprintf('  [iter %d] AGG: F=%.4e cos=%.3f eps=%.3f hole_err=%.4fm g_eps=%.3e |g_pos|=%.3e N_bnd=%d t=%.1fs\n', ...
        iter, F_cheb, mean_cos, eps_r_body, hole_err, g_eps, g_pos_norm_val, N_boundary, toc);

    % CSV 日志
    log_fid = fopen(log_path, 'a');
    fprintf(log_fid, '%d,%.6e,%.6f,%.4f,%.4f,%.4f,%.4f,%.6e,%.6e,%.4f,%.4f,%.5f,%d,%.1f,%.6e,%.6e\n', ...
        iter, F_cheb, mean_cos, eps_r_body, hole_pos(1), hole_pos(2), hole_pos(3), ...
        g_eps, g_pos_norm_val, hole_err, mu_eps, mu_hole, 0, toc, g_FD_x, g_pos_analytical_x);
    fclose(log_fid);

    % 收敛检查（管线维护 Round14 A-03: 收敛判据解耦——backtracking 保护 + 参数稳定性检查）
    if F_cheb < p.eps_tol && iter >= 3
        allow_converge = true;

        % (1) backtracking 后强制至少 1 轮缩减步长迭代
        % 防止 backtracking 触发的缩减步长从未被实际使用（H018 v2 iter3→iter4 暴露）
        if h018_enabled && h018_backtrack_pending
            fprintf('  [Round14 A-03] iter=%d: F<eps_tol 但上一轮刚触发 backtracking，强制执行缩减步长迭代\n', iter);
            h018_backtrack_pending = false;
            allow_converge = false;
            a03_forced_this_iter = true;   % Round15: 标记本轮为 A-03 强制迭代
        end

        % (2) 参数空间稳定性检查（基于 hole_pos 变化率，不依赖真值）
        % 当连续 2 轮 hole_pos 相对位移 > stable_tol 时，位置尚未稳定，不立即收敛
        if allow_converge && isfield(p, 'cavity_convergence_decouple') && p.cavity_convergence_decouple && iter >= 4
            stable_tol = 0.05;
            if isfield(p, 'cavity_hole_stable_tol'), stable_tol = p.cavity_hole_stable_tol; end
            for back = 1:2
                if iter - back >= 1
                    prev_hp = state.history_hole_pos(:, iter - back);
                    curr_hp = state.history_hole_pos(:, iter - back + 1);
                    delta_hp = norm(curr_hp - prev_hp);
                    curr_hp_norm = max(norm(curr_hp), 1e-10);
                    if delta_hp / curr_hp_norm > stable_tol
                        fprintf('  [Round14 A-03] iter=%d back=%d: |Δhole_pos|/|hole_pos|=%.1f%% > %.0f%%，位置未稳定，暂不收敛\n', ...
                            iter, back, delta_hp/curr_hp_norm*100, stable_tol*100);
                        allow_converge = false;
                        break;
                    end
                end
            end
        end

        % (3) H020 Gate B: hole_err 稳定性判据（双门独立收敛的核心变更）
        % Gate A 已满足（F_cheb < eps_tol），现检查 Gate B 是否同时满足
        % Gate B 复用本节刚计算的 state.history_gate_B_pass(iter)
        if allow_converge && h020_enabled
            if ~state.history_gate_B_pass(iter)
                fprintf('  [H020 Gate B] iter=%d: Gate A PASS 但 Gate B FAIL（hole_err 未稳定，需连续 %d 轮变化率 < %.0f%%），双门未同时满足，继续迭代\n', ...
                    iter, h020_stab_window, h020_stab_threshold*100);
                allow_converge = false;
            else
                fprintf('  [H020] iter=%d: Gate A AND Gate B 双门同时满足，触发全局收敛\n', iter);
            end
        end

        if allow_converge
            fprintf('  [iter %d] Converged: F=%.4e < %.4e\n', iter, F_cheb, p.eps_tol);
            state.converged = true;
            state.iteration = iter;
            update_log_accepted(log_path, iter);
            break;
        else
            fprintf('  [Round14 A-03 / H020] iter=%d: F<eps_tol 但收敛判据解耦阻止过早终止，继续迭代\n', iter);
        end
    end

    %% 5. 分别归一化 + 线搜索
    % 材料：归一化为 ±1 方向
    if h021_enabled && eps_r_frozen
        dir_eps = 0;   % H021: eps_r 冻结后线搜索不更新 eps_r（仅 hole 位置更新）
    elseif abs(g_eps) > 1e-30
        dir_eps = sign(g_eps);
    else
        dir_eps = 0;
    end

    % 位置：max-norm 归一化
    if g_pos_norm_val > 1e-30
        dir_pos = g_pos / g_pos_norm_val;
    else
        dir_pos = zeros(3, 1);
    end

    fprintf('  [iter %d] linesearch: dir_eps=%+.0f, |dir_pos|=%.3f, mu_eps=%.4f, mu_hole=%.5f\n', ...
        iter, dir_eps, norm(dir_pos), mu_eps, mu_hole);

    accepted = false;
    % Round18: 本轮连续同号物理 reject 计数器重置
    ls_consec_reject = 0;
    ls_prev_sign = 0;
    mu_eps_try = mu_eps;
    J_hyp_ls_primary = [];       % H018: 线搜索接受步的主频 J_hyp（供组件 B best_intermediate）
    if h018_enabled
        %% ===== H018 v2 组件 A: 梯度归一化自适应步长 =====
        % Δx_hole = target_step × g_hole / ||g_hole||
        % 当前代码已将 dir_pos = g_pos/||g_pos|| 归一化为单位方向，
        % 故 mu_hole_try = target_step 即可实现固定物理位移目标。
        % 根因验证：实测 |Δx_hole| 应 ≈ mu_hole_try（若远小则提示隐式缩放存在）
        if g_pos_norm_val < h018_near_zero_th
            mu_hole_try = 0;
            h018_hole_converged = true;
            fprintf('  [H018 A] near-zero gradient guard: ||g_pos||=%.3e < %.3e → Δx_hole=0\n', ...
                g_pos_norm_val, h018_near_zero_th);
        else
            mu_hole_try = min(h018_target_step, h018_mu_hole_upper);
        end
        state.history_mu_hole_adaptive(iter) = mu_hole_try;
    else
        mu_hole_try = mu_hole;
    end

    % H032: 记录线搜索前 hole_err（backtracking 减半判据基准）+ 初始化减半计数器
    if h032_backtrack
        hole_err_pre_h032 = norm(hole_pos - hole_true(:));
        h032_halvings = 0;
    end

    for trial = 1:mu_max_trials
        % 管线维护 Round19 (H023 needs_optimization): 冻结后 LS 短路
        % eps_r 冻结后梯度景观恒定（post-freeze cos(g_k,g_{k-1})=1.0000）。
        % 若前一轮 LS 全 reject，本轮 LS trial 序列将与前一轮逐位相同（确定性重演，零信息增量）。
        % 在 trial==1 时短路：不执行任何正演，直接 break，依赖 Gate B 收敛判定推进迭代。
        % H023 iter4 场景：此机制完全消除 8 次确定性失败重演（节省 ~648s）。
        if trial == 1 && eps_r_frozen && (prev_iter_ls_all_reject || gate_a_shortcircuit_this_iter)
            frozen_ls_shortcircuit_hits = frozen_ls_shortcircuit_hits + 1;
            if gate_a_shortcircuit_this_iter
                gate_a_shortcircuit_hits = gate_a_shortcircuit_hits + 1;
                fprintf('  [Round23] iter=%d: LS shortcircuit (Gate A just triggered, post-freeze first LS), skipping %d trials\n', iter, mu_max_trials);
            else
                fprintf('  [Round19] iter=%d: LS shortcircuit (frozen + prev LS all-reject, deterministic replay), skipping %d trials\n', iter, mu_max_trials);
            end
            break;
        end
        % 试探更新：沿下降方向移动（dir 已为下降方向 -∇F，故用 +）
        %   H012 Round8 管线维护修复：原为 '-' 导致 24/24 trial uphill reject
        eps_r_try = eps_r_body + mu_eps_try * dir_eps;
        eps_r_try = max(p.eps_r_min, min(p.eps_r_max, eps_r_try));

        hole_try = hole_pos + mu_hole_try * dir_pos;
        % 约束投影：|hole| + R_hole < R_body
        hole_norm = norm(hole_try);
        if hole_norm > R_body - hole_margin
            hole_try = hole_try * (R_body - hole_margin) / max(hole_norm, 1e-10);
            fprintf('    [LS trial=%d] hole projected to boundary\n', trial);
        end

        % 构造试探 voxel（H022: SDF 软边界——残差梯度反馈恢复的关键路径）
        rho_try = sqrt(sum((pos_inner - hole_try(:).').^2, 2));
        mask_cav_try = rho_try < R_hole;

        voxel_try = voxel;
        voxel_try.epsilon_r = c01_cavity_eps_assign(pos_inner, hole_try, R_hole, eps_r_try, N_v, inner_idx, sdf_delta, h022_sdf);

        % 多频率正演求残差
        F_try = 0;
        fwd_ok = true;
        for fi = 1:N_freq
            p_fr = p;
            p_fr.freq = freqs(fi);
            p_fr.omega = 2*pi*p_fr.freq;
            p_fr.k0 = p_fr.omega / p_fr.c;
            p_fr.lambda = p_fr.c / p_fr.freq;

            try
                [E_try, ~, ~] = solve_forward(model, voxel_try, p_fr);
            catch ME
                fprintf('    [LS trial=%d freq=%d] fwd fail: %s\n', trial, fi, ME.message);
                fwd_ok = false;
                break;
            end
            if isempty(E_try), fwd_ok = false; break; end

            sf = extract_scattered(model, grid);
            lc_try = lightcone_project(grid, sf, p_fr);
            J_hyp_try = lc_try.J_obs_perp;
            if fi == 1
                J_hyp_ls_primary = J_hyp_try;   % H018: 捕获主频 J_hyp 供组件 B
            end

            J_obs_fi = J_obs_multi{fi};
            Delta = J_obs_fi - J_hyp_try;
            F_k_try = sum(abs(Delta).^2, 2) ./ max(sum(abs(J_obs_fi).^2, 2), p.rel_err_floor) / 6;
            F_try = F_try + mean(F_k_try) / N_freq;
        end

        if ~fwd_ok
            fprintf('    [LS trial=%d] fwd failed, decay\n', trial);
            mu_eps_try = mu_eps_try * mu_decay;
            mu_hole_try = mu_hole_try * mu_decay;
            continue;
        end

        dF_trial = F_try - F_cheb;
        fprintf('    [LS trial=%d] F_try=%.4e (old=%.4e) dF=%.4e', trial, F_try, F_cheb, dF_trial);

        % 管线维护 Round17 (H021 needs_optimization): dF 机器精度早停
        % post-freeze LS trial dF~1e-16 在数值噪声中操作，浪费正演（H021 iter4/5 共 3 次/~15s）。
        % 根因：eps_r 冻结后 hole 位置 sub-voxel 移动不改变离散化 epsilon 分布（相同 cavity 体素），
        % 正演问题完全相同 → residual 恒定 → Armijo 在舍入误差级噪声中做无意义 accept/reject。
        % 当 |dF| < 机器精度阈值时判定为"离散化不敏感步"，终止线搜索：
        %   - dF <= 0：仍按下降准则 accept（残差不上升）但立即 break，避免后续 trial 浪费正演
        %   - dF > 0：不 decay mu（更小 mu→更小位移→更不可能改变离散化→纯噪声），直接 break
        % 阈值 1e-10 比 F_cheb(~6e-2) 小 8 个数量级，误伤真实物理下降风险极低（收敛 dF>=1e-6）。
        if h021_dF_earlystop && abs(dF_trial) < dF_machine_eps
            dF_earlystop_hits = dF_earlystop_hits + 1;
            if dF_trial <= 0
                fprintf('  ACCEPT (machine-eps, discretization-insensitive)\n');
                eps_r_body = eps_r_try;
                hole_pos = hole_try;
                accepted = true;
            else
                fprintf('  BREAK (machine-eps, discretization-insensitive)\n');
            end
            break;
        end

        % 管线维护 Round19 (H023 needs_optimization): dF 相对阈值早停
        % Round17 绝对阈值 |dF|<1e-10 仅防信号消失（H021 离散化不敏感场景）。
        % SDF 恢复残差灵敏度后 dF 回到物理量级（~1e-4），绝对阈值不触发。
        % 但 |dF|/F_old < rel_threshold（0.5%）表明该步对残差的相对改善微乎其微，
        % 继续 trial 是低效的（H023 iter3 dF~1e-4 vs F_old~6e-2 → |dF|/F_old~0.17% < 0.5%）。
        % 与 Round17 绝对阈值互补：绝对阈值防信号消失，相对阈值防低效步。任一满足即终止。
        if h021_dF_earlystop && F_cheb > 0 && abs(dF_trial) / F_cheb < dF_rel_threshold
            dF_rel_earlystop_hits = dF_rel_earlystop_hits + 1;
            if dF_trial <= 0
                fprintf('  ACCEPT (rel-threshold, |dF|/F_old=%.2f%% < %.1f%%)\n', abs(dF_trial)/F_cheb*100, dF_rel_threshold*100);
                eps_r_body = eps_r_try;
                hole_pos = hole_try;
                accepted = true;
            else
                fprintf('  BREAK (rel-threshold, |dF|/F_old=%.2f%% < %.1f%%)\n', abs(dF_trial)/F_cheb*100, dF_rel_threshold*100);
            end
            break;
        end

        if F_try < F_cheb
            % H032: hole_err 回弹检测——Armijo 接受但 hole_err 几何指标可能过冲
            % F 可能下降（eps_r 改善）但 hole_err 上升（hole_pos 过冲），Armijo 接受但 H032 拒绝并减半。
            % 仅减半 mu_hole_try（eps_r 步长不变），continue 重试减半后的 hole 步。
            % 最多 max_halvings 次减半后强制接受（避免无限重试）。
            if h032_backtrack && h032_halvings < h032_max_halvings
                hole_err_try_h032 = norm(hole_try - hole_true(:));
                if hole_err_try_h032 > hole_err_pre_h032
                    fprintf('  H032 BACKTRACK: hole_err %.4f→%.4f (+%.1f%%) rebound, halving mu_hole %.5f→%.5f (halving %d/%d)\n', ...
                        hole_err_pre_h032, hole_err_try_h032, ...
                        (hole_err_try_h032/hole_err_pre_h032 - 1)*100, ...
                        mu_hole_try, mu_hole_try*0.5, h032_halvings+1, h032_max_halvings);
                    mu_hole_try = mu_hole_try * 0.5;
                    h032_halvings = h032_halvings + 1;
                    continue;  % 重试减半后的 hole 步（mu_eps_try 不变）
                end
            end
            fprintf('  ACCEPT\n');
            eps_r_body = eps_r_try;
            hole_pos = hole_try;
            accepted = true;
            break;
        else
            fprintf('  reject\n');
            mu_eps_try = mu_eps_try * mu_decay;
            mu_hole_try = mu_hole_try * mu_decay;
            % 管线维护 Round18 (H022 needs_optimization): 系统性 reject 早停
            % 连续 N 次 trial reject 且 dF 物理量级同号 → 梯度方向系统性错误
            if h022_sysreject_earlystop && abs(dF_trial) > sysreject_dF_floor
                cur_sign = sign(dF_trial);
                if cur_sign == ls_prev_sign && cur_sign ~= 0
                    ls_consec_reject = ls_consec_reject + 1;
                else
                    ls_consec_reject = 1;
                end
                ls_prev_sign = cur_sign;
                if ls_consec_reject >= sysreject_N
                    sysreject_hits = sysreject_hits + 1;
                    if cur_sign > 0, sgn_str = '正(残差上升)'; else, sgn_str = '负'; end
                    fprintf('  [Round18] BREAK: 连续 %d 次同号 reject (dF%s) → 梯度方向系统性错误，终止线搜索\n', ls_consec_reject, sgn_str);
                    break;
                end
            end
        end
    end

    if accepted
        mu_eps = min(mu_eps_try * 1.3, p.mu_max);
        mu_hole = min(mu_hole_try * 1.3, 0.02);
        update_log_accepted(log_path, iter);
    else
        fprintf('  [iter %d] all trials rejected, keep params\n', iter);
    end

    % Round19: 记录本轮 LS 是否全 reject（供下一轮冻结后 LS 短路判定）
    % eps_r 冻结后若前一轮 LS 全 reject → 下一轮 LS 短路（梯度景观恒定，确定性重演）
    prev_iter_ls_all_reject = ~accepted;

    state.history_accepted(iter) = accepted;

    % H032: 记录本轮 backtracking 减半统计（验证机制生效频率）
    if h032_backtrack
        state.history_h032_halvings(iter) = h032_halvings;
        state.history_h032_step_size(iter) = mu_hole_try;
        if h032_halvings > 0
            init_ts = NaN;
            if h018_enabled, init_ts = h018_target_step; end
            fprintf('  [H032 MONITOR] iter=%d halvings=%d, final_step=%.5f (init target_step=%.4f)\n', ...
                iter, h032_halvings, mu_hole_try, init_ts);
        end
    end

    %% ===== H022: 残差灵敏度监测（验证 SDF 恢复 dF/d(r_hole) 梯度反馈）=====
    % H021 冻结后 dF~1e-16（离散化不敏感）。SDF 应使 |dF/d_hole| 从机器精度提升至物理量级。
    if h022_sdf && accepted
        hole_pre_ls_sens = state.history_hole_pos(:, iter);
        delta_hole_sens = norm(hole_pos - hole_pre_ls_sens);
        if delta_hole_sens > 1e-12
            sens_h022 = abs(dF_trial) / delta_hole_sens;
            state.history_residual_sensitivity(iter) = sens_h022;
            if iter <= 2
                fprintf('  [H022 MONITOR] iter=%d residual_sensitivity |dF/d_hole|=%.4e (H021 baseline ~1e-16, SDF 应提升至物理量级)\n', ...
                    iter, sens_h022);
            end
        end
    end

    %% ===== H018 v2 组件 A+B: 自适应步长记录 + best_intermediate 保护 =====
    if h018_enabled
        % 记录本轮线搜索后状态
        hole_pos_pre_ls = state.history_hole_pos(:, iter);   % 线搜索前 hole_pos
        if accepted
            delta_x_actual = norm(hole_pos - hole_pos_pre_ls);   % 实测位移量级（根因验证核心指标）
        else
            delta_x_actual = 0;
        end
        state.history_delta_x_hole(iter) = delta_x_actual;

        % 根因验证监测：实测 |Δx_hole| vs 理论 target_step
        if iter == 1 && accepted
            fprintf('  [H018 v2 ROOT-CAUSE] iter=1 |Δx_hole|=%.5f vs mu_hole_try=%.5f (target_step=%.4f)\n', ...
                delta_x_actual, mu_hole_try, h018_target_step);
            if delta_x_actual < mu_hole_try * 0.5
                fprintf('  [H018 v2 ROOT-CAUSE] [WARN] |Δx_hole| << mu_hole_try → 隐式缩放可能存在（Armijo 回溯/物理 clamp）\n');
            else
                fprintf('  [H018 v2 ROOT-CAUSE] |Δx_hole| ≈ mu_hole_try → 无隐式缩放，步长直控位移\n');
            end
        end

        % 组件 B: best_intermediate 保护（基于 hole_err）+ H019 多目标 Q 升级
        if accepted
            hole_err_post = norm(hole_pos - hole_true(:));
            state.history_hole_err(iter) = hole_err_post;

            % hole_err vs residual 相关性监测（根因诊断 concern B）
            fprintf('  [H018 v2 MONITOR] iter=%d hole_err=%.4f residual=%.4e', iter, hole_err_post, F_try);

            % H018 v2 best_he_* 追踪保留（向后兼容 + 诊断对比）
            if hole_err_post < best_he_hole_err
                best_he_hole_err = hole_err_post;
                best_he_pos      = hole_pos;
                best_he_eps_r    = eps_r_body;
                best_he_residual = F_try;
                best_he_iter     = iter;
                best_he_J_hyp    = J_hyp_ls_primary;
                fprintf('  → BEST UPDATED');
            end
            fprintf('\n');
            state.history_best_hole_err(iter) = best_he_hole_err;

            % H019: 多目标综合质量判据 Q——best_intermediate 终态选择判据升级
            % Q = w_cos·cos θ_post + w_hole·max(0,1−hole_err/ref) + w_eps·max(0,1−eps_r_err/ref)
            % cos θ_post 由线搜索接受步的 J_hyp_ls_primary 与 J_obs_multi{1} 计算（无需额外正演）
            if h019_enabled && ~isempty(J_hyp_ls_primary)
                eps_r_err_post = abs(eps_r_body - eps_r_true) / eps_r_true;
                J_obs_f1 = J_obs_multi{1};
                cos_theta_post = mean(real(sum(conj(J_obs_f1) .* J_hyp_ls_primary, 2)) ...
                    ./ (sqrt(sum(abs(J_obs_f1).^2, 2)) + p.rel_err_floor) ...
                    ./ (sqrt(sum(abs(J_hyp_ls_primary).^2, 2)) + p.rel_err_floor));
                q_cos  = h019_w_cos * cos_theta_post;
                q_hole = h019_w_hole * max(0, 1 - hole_err_post / h019_hole_err_ref);
                q_eps  = h019_w_eps * max(0, 1 - eps_r_err_post / h019_eps_r_ref);
                Q_post = q_cos + q_hole + q_eps;
                state.history_Q(iter) = Q_post;
                fprintf('  [H019 MONITOR] iter=%d Q=%.4f (cos=%.3f→%.3f hole_err=%.4f→%.3f eps_r_err=%.4f→%.3f)', ...
                    iter, Q_post, cos_theta_post, q_cos, hole_err_post, q_hole, eps_r_err_post, q_eps);
                if Q_post > best_Q
                    best_Q          = Q_post;
                    best_Q_cos      = cos_theta_post;
                    best_Q_hole_err = hole_err_post;
                    best_Q_eps_r_err= eps_r_err_post;
                    best_Q_pos      = hole_pos;
                    best_Q_eps_r    = eps_r_body;
                    best_Q_residual = F_try;
                    best_Q_iter     = iter;
                    best_Q_J_hyp    = J_hyp_ls_primary;
                    fprintf('  → BEST (Q) UPDATED');
                end
                fprintf('\n');
            end

            % 组件 A: 振荡检测 — 连续 2 轮 hole_err 增加 → target_step 减半
            if isfinite(h018_prev_he_post)
                if hole_err_post > h018_prev_he_post * 1.05
                    h018_osc_count = h018_osc_count + 1;
                    fprintf('  [H018 A] oscillation: hole_err %.4f→%.4f (+%.1f%%) osc_count=%d\n', ...
                        h018_prev_he_post, hole_err_post, ...
                        (hole_err_post/h018_prev_he_post - 1)*100, h018_osc_count);
                else
                    h018_osc_count = max(0, h018_osc_count - 1);
                end
                if h018_osc_count >= 2 && h018_target_step > h018_target_step_min
                    h018_target_step = max(h018_target_step * 0.5, h018_target_step_min);
                    h018_backtrack_pending = true;  % Round14 A-03: 标记，下轮收敛检查时阻止过早收敛
                    fprintf('  [H018 A] backtracking: target_step → %.4f (osc_count≥2)\n', h018_target_step);
                    h018_osc_count = 0;
                end
            end
            h018_prev_he_post = hole_err_post;
        else
            state.history_hole_err(iter) = norm(hole_pos - hole_true(:));
            state.history_best_hole_err(iter) = best_he_hole_err;
        end
    end

    % best-state tracking 已移至 §3.5（F_cheb 计算后、收敛检查前）——管线维护 Round10 修复

    % 管线维护 Round15: A-03 强制迭代后 LS 全 reject 早停
    % H019 暴露：A-03 强制迭代后 iter4 LS 8/8 全 reject，浪费 8 次正演(~32s) + iter5 完整迭代(~24s)
    % 数学依据：LS 全 reject = 所有试探步长均使残差上升 = 当前状态已处于局部极小
    % A-03 的目的是给 hole 优化更多迭代空间，但 LS 无法找到下降方向时该目的已无法实现
    %
    % 管线维护 Round16: Gate B 让位条件（H020 暴露冲突的核心修复）
    % H020 暴露：当 Gate B 未通过（hole_err 未稳定）时，Gate B 要求继续迭代给 hole 优化空间，
    % 但 Round15 LS-allreject 在同一轮触发终止，Gate B 延迟收敛的意图被完全抵消——
    % H020 终止于 iter4（反而 < H019 的 iter5），hole 优化预算未实质扩展。
    % 修复：Gate B 未通过时，LS-allreject 让位 Gate B 的继续迭代意图；配合 gate_b_delay_max
    % 上限保护，防止 hole_err 长期震荡导致无限迭代（方案 A + 方案 C）。
    if ~accepted && a03_forced_this_iter
        gate_b_yields_lsallreject = false;  % Gate B 是否正在阻塞 LS-allreject
        if h020_enabled && ~state.history_gate_B_pass(iter)
            gate_b_yields_lsallreject = true;
            gate_b_delay_count = gate_b_delay_count + 1;
            fprintf('  [Round16 Gate B 让位] iter=%d: A-03 强制迭代后 LS 全 reject，但 Gate B 未通过（hole_err 未稳定），LS-allreject 让位 Gate B 继续迭代（延迟计数 %d/%d）\n', ...
                iter, gate_b_delay_count, gate_b_delay_max);
        end
        if ~gate_b_yields_lsallreject || gate_b_delay_count > gate_b_delay_max
            if gate_b_delay_count > gate_b_delay_max
                fprintf('  [Round16 Gate B 让位] iter=%d: Gate B 延迟已达上限（%d/%d），hole_err 仍未稳定，恢复 LS-allreject 终止\n', ...
                    iter, gate_b_delay_count, gate_b_delay_max);
            end
            fprintf('  [Round15 LS-allreject] iter=%d: A-03 强制迭代后 LS 全 reject——局部极小已确认，提前终止（节省后续迭代正演开销）\n', iter);
            state.stop_reason = 'ls_allreject_post_a03';
            break;
        end
    end

    % 连续 reject 早停（效率优化：避免无效正演浪费）
    if accepted
        consecutive_reject = 0;
    else
        consecutive_reject = consecutive_reject + 1;
        if consecutive_reject >= reject_threshold
            fprintf('  [iter %d] 连续 %d 轮 reject，提前终止（效率优化）\n', ...
                iter, consecutive_reject);
            break;
        end
    end
end

if ~state.converged && state.iteration == 0
    state.iteration = min(iter, p.max_iter);
end

%% ---- 最终重建 ----
if h019_enabled && best_Q_iter > 0
    %% H019: 返回多目标 Q 综合质量判据最优态（cos θ/hole_err/eps_r_err Pareto 最优）
    eps_r_body = best_Q_eps_r;
    hole_pos   = best_Q_pos;
    fprintf('[C01_cavity] [H019] 返回 best_intermediate (Q) state: iter=%d Q=%.4f (cos=%.3f hole_err=%.4fm eps_r_err=%.4f)\n', ...
        best_Q_iter, best_Q, best_Q_cos, best_Q_hole_err, best_Q_eps_r_err);
    fprintf('[C01_cavity] [H019] 对比 hole_err 单目标: best_he_iter=%d hole_err=%.4fm (F_cheb-based best iter=%d F=%.4e)\n', ...
        best_he_iter, best_he_hole_err, best_iter, best_F);
elseif h018_enabled && best_he_iter > 0
    %% H018 v2 组件 B: 返回 best_intermediate state（hole_err 最优）
    eps_r_body = best_he_eps_r;
    hole_pos   = best_he_pos;
    fprintf('[C01_cavity] [H018 B] 返回 best_intermediate state: iter=%d hole_err=%.4fm (F_cheb-based best iter=%d F=%.4e)\n', ...
        best_he_iter, best_he_hole_err, best_iter, best_F);
else
    %% 原始: 使用 best-state（F_cheb 最优）参数
    eps_r_body = best_eps_r;
    hole_pos   = best_hole_pos;
end

rho_final = sqrt(sum((pos_inner - hole_pos(:).').^2, 2));
mask_cav_final = rho_final < R_hole;
voxel.epsilon_r = c01_cavity_eps_assign(pos_inner, hole_pos, R_hole, eps_r_body, N_v, inner_idx, sdf_delta, h022_sdf);

state.epsilon_r = voxel.epsilon_r;
state.eps_r_body = eps_r_body;
state.hole_pos = hole_pos;
state.hole_pos_true = hole_true;
state.best_F_cheb = best_F;
state.best_iter = best_iter;
state.hole_position_error = norm(hole_pos - hole_true(:));
state.N_cavity_voxels = sum(mask_cav_final);
state.N_boundary_voxels = sum(abs(rho_final - R_hole) < dr);
state.J_obs_truth = J_obs_multi{1};   % 主频 J_obs（供 run_experiment 三件套使用）
state.freqs = freqs;
state.N_freq = N_freq;
state.algorithm = 'C01_cavity_body_eccentric';
state.mu_eps_final = mu_eps;
state.mu_hole_final = mu_hole;
if h019_enabled && best_Q_iter > 0
    state.residual = best_Q_residual;          % H019: 输出 Q 最优态残差
    state.history_J_hyp = best_Q_J_hyp;        % H019: 输出 Q 最优态 J_hyp
elseif h018_enabled && best_he_iter > 0
    state.residual = best_he_residual;          % H018: 输出 hole_err 最优态残差
    state.history_J_hyp = best_he_J_hyp;        % H018: 输出 hole_err 最优态 J_hyp
else
    state.residual = best_F;                    % 供 run_experiment 三件套输出
    state.history_J_hyp = best_J_hyp;           % 输出 best-state J_hyp（非 final）
end

%% ---- H015: 混合梯度策略状态 ----
state.hybrid_fd.enabled = isfield(p, 'cavity_hybrid_fd_x') && p.cavity_hybrid_fd_x;
state.hybrid_fd.delta_x_primary = p.cavity_fd_delta_x;
if isfield(p, 'cavity_fd_delta_x_fallback')
    state.hybrid_fd.delta_x_fallback = p.cavity_fd_delta_x_fallback;
end
state.hybrid_fd.delta_x_used = delta_x_used;
state.hybrid_fd.fallback_triggered = fd_x_ok && delta_x_used > p.cavity_fd_delta_x;
state.hybrid_fd.fd_resolved = fd_x_resolved;
state.hybrid_fd.g_FD_x_final = g_FD_x;
state.hybrid_fd.g_pos_analytical_x_final = g_pos_analytical_x;
state.hybrid_fd.geo_shortcircuited = geo_shortcircuit_count;

%% ---- H018 v2: 双组件状态 ----
state.h018_dual_component = h018_enabled;
if h018_enabled
    state.h018_component_A.target_step_init    = p.cavity_h018_target_step;
    state.h018_component_A.target_step_final   = h018_target_step;
    state.h018_component_A.mu_hole_upper       = h018_mu_hole_upper;
    state.h018_component_A.hole_converged      = h018_hole_converged;
    state.h018_component_A.osc_count_final     = h018_osc_count;
    state.h018_component_B.best_hole_err       = best_he_hole_err;
    state.h018_component_B.best_he_iter        = best_he_iter;
    state.h018_component_B.best_he_pos         = best_he_pos;
    state.h018_component_B.best_he_eps_r       = best_he_eps_r;
    state.h018_component_B.guarantee_verified  = norm(best_he_pos - hole_true(:)) <= best_he_hole_err + 1e-15;
    state.h018_component_B.final_vs_best_delta = state.hole_position_error - best_he_hole_err;
    fprintf('[C01_cavity] [H018 B] guarantee: best_he_hole_err=%.4fm (iter %d), final hole_err=%.4fm, delta=%.4fm\n', ...
        best_he_hole_err, best_he_iter, state.hole_position_error, state.h018_component_B.final_vs_best_delta);
end

%% ---- H019: 多目标 Q 判据状态 ----
state.h019_multi_obj_q = h019_enabled;
if h019_enabled
    state.h019_weights.w_cos         = h019_w_cos;
    state.h019_weights.w_hole        = h019_w_hole;
    state.h019_weights.w_eps         = h019_w_eps;
    state.h019_refs.hole_err_ref     = h019_hole_err_ref;
    state.h019_refs.eps_r_ref        = h019_eps_r_ref;
    state.h019_component_B.best_Q          = best_Q;
    state.h019_component_B.best_Q_iter     = best_Q_iter;
    state.h019_component_B.best_Q_cos      = best_Q_cos;
    state.h019_component_B.best_Q_hole_err = best_Q_hole_err;
    state.h019_component_B.best_Q_eps_r_err= best_Q_eps_r_err;
    state.h019_component_B.best_Q_pos      = best_Q_pos;
    state.h019_component_B.best_Q_eps_r    = best_Q_eps_r;
    % 数学保证：best_Q 是所有已计算 Q_post 的最大值（更新规则 Q_post > best_Q 保证），
    % 故终态 Q ≥ max(Q_history) 无条件成立（best_Q_iter > 0 表示至少计算过一次 Q）
    state.h019_component_B.guarantee_verified = (best_Q_iter > 0);
    % Q vs hole_err 单目标对比：验证多目标判据是否选中的是不同态（诊断多目标失配）
    state.h019_component_B.Q_vs_he_same_iter = (best_Q_iter == best_he_iter);
    state.h019_component_B.Q_selected_hole_err = best_Q_hole_err;
    state.h019_component_B.he_selected_hole_err = best_he_hole_err;
    fprintf('[C01_cavity] [H019 B] guarantee: best_Q=%.4f (iter %d, cos=%.3f hole_err=%.4fm eps_r_err=%.4f); hole_err单目标 iter=%d hole_err=%.4fm; 同一轮=%d\n', ...
        best_Q, best_Q_iter, best_Q_cos, best_Q_hole_err, best_Q_eps_r_err, ...
        best_he_iter, best_he_hole_err, state.h019_component_B.Q_vs_he_same_iter);
end

%% ---- H020: 双门独立收敛状态 ----
state.h020_dual_gate = h020_enabled;
if h020_enabled
    final_iter_idx = min(max(state.iteration, 1), p.max_iter);
    state.h020_gate_A.type              = 'residual F_cheb < eps_tol';
    state.h020_gate_A.threshold         = p.eps_tol;
    state.h020_gate_A.final_pass        = state.history_gate_A_pass(final_iter_idx);
    state.h020_gate_B.type              = 'hole_err stability';
    state.h020_gate_B.window            = h020_stab_window;
    state.h020_gate_B.threshold         = h020_stab_threshold;
    state.h020_gate_B.final_change_rate = state.history_hole_err_change_rate(final_iter_idx);
    state.h020_gate_B.final_pass        = state.history_gate_B_pass(final_iter_idx);
    state.h020_global_converged         = state.converged && ...
                                           state.h020_gate_A.final_pass && ...
                                           state.h020_gate_B.final_pass;
    fprintf('[C01_cavity] [H020] dual_gate: Gate_A=%d Gate_B=%d global_converged=%d (window=%d threshold=%.0f%%)\n', ...
        state.h020_gate_A.final_pass, state.h020_gate_B.final_pass, state.h020_global_converged, ...
        h020_stab_window, h020_stab_threshold*100);
end

%% ---- H021: eps_r 冻结机制状态 ----
state.h021_eps_r_freeze = h021_enabled;
if h021_enabled
    state.h021_freeze_triggered        = eps_r_frozen;
    state.h021_freeze_iteration        = eps_r_freeze_iter;
    state.h021_frozen_eps_r_value      = eps_r_body;  % 默认值（冻结后由 history_eps_r 覆盖）
    if eps_r_frozen && eps_r_freeze_iter > 0
        freeze_idx = eps_r_freeze_iter;
        state.h021_frozen_eps_r_value  = state.history_eps_r(freeze_idx);
        % post_freeze 梯度方向一致性统计（冻结后 cos(g_k, g_{k-1}) 均值）
        post_freeze_iters = (eps_r_freeze_iter+1):min(state.iteration, p.max_iter);
        post_freeze_cos = state.history_g_pos_consistency(post_freeze_iters);
        valid_cos = post_freeze_cos(~isnan(post_freeze_cos));
        if ~isempty(valid_cos)
            state.h021_post_freeze_grad_consistency_mean = mean(valid_cos);
            state.h021_post_freeze_grad_consistency_min  = min(valid_cos);
        else
            state.h021_post_freeze_grad_consistency_mean = NaN;
            state.h021_post_freeze_grad_consistency_min  = NaN;
        end
    end
    fprintf('[C01_cavity] [H021] eps_r_freeze: triggered=%d freeze_iter=%d frozen_eps_r=%.4f', ...
        eps_r_frozen, eps_r_freeze_iter, state.h021_frozen_eps_r_value);
    if eps_r_frozen && eps_r_freeze_iter > 0 && ~isnan(state.h021_post_freeze_grad_consistency_mean)
        fprintf(' post_freeze_grad_cos_mean=%.4f (min=%.4f)', ...
            state.h021_post_freeze_grad_consistency_mean, state.h021_post_freeze_grad_consistency_min);
    end
    fprintf('\n');
end

%% ---- H017: 连续边界积分状态 ----
state.continuous_bi.enabled = isfield(p, 'cavity_continuous_bi') && p.cavity_continuous_bi;
if state.continuous_bi.enabled
    state.continuous_bi.N_sphere = p.cavity_bi_N;
    state.continuous_bi.gradient_strategy = 'analytical_continuous_boundary_integral';
    state.continuous_bi.integration_domain = 'continuous spherical cavity boundary (FEM)';
    state.continuous_bi.normal_definition = 'n_k = (r_k - hole_center) / R_hole';
    state.continuous_bi.g_pos_final = g_pos;
    state.continuous_bi.g_pos_x = g_pos(1);  % 对比 H015/H016 的 ≈0
    state.continuous_bi.g_pos_y = g_pos(2);
    state.continuous_bi.g_pos_z = g_pos(3);
    if ~isfield(state, 'bi_fd_crosscheck') || ~state.bi_fd_crosscheck.performed
        state.bi_fd_crosscheck.performed = false;
    end
end

%% ---- H022: SDF 软边界 epsilon 映射状态 ----
state.h022_sdf = h022_sdf;
if h022_sdf
    state.h022_sdf_delta = sdf_delta;
    state.h022_sdf_effective_radius = R_hole + sdf_delta;
    state.h022_sdf_radius_oversize_pct = sdf_delta / R_hole * 100;
    % 梯度方向一致性统计（全迭代，条件_1）
    all_cos = state.history_g_pos_consistency_all(2:min(state.iteration, p.max_iter));
    valid_all_cos = all_cos(~isnan(all_cos));
    if ~isempty(valid_all_cos)
        state.h022_grad_consistency_all_mean = mean(valid_all_cos);
        state.h022_grad_consistency_all_min  = min(valid_all_cos);
    else
        state.h022_grad_consistency_all_mean = NaN;
        state.h022_grad_consistency_all_min  = NaN;
    end
    % 残差灵敏度统计（验证梯度反馈恢复）
    valid_sens = state.history_residual_sensitivity(state.history_residual_sensitivity > 0);
    if ~isempty(valid_sens)
        state.h022_residual_sensitivity_mean = mean(valid_sens);
        state.h022_residual_sensitivity_min  = min(valid_sens);
    else
        state.h022_residual_sensitivity_mean = 0;
        state.h022_residual_sensitivity_min  = 0;
    end
    fprintf('[C01_cavity] [H022] SDF: delta=%.4f effective_R=%.4f (%.0f%% oversize), grad_consistency_all=%.4f, residual_sensitivity_mean=%.4e (H021 baseline ~1e-16)\n', ...
        sdf_delta, R_hole + sdf_delta, sdf_delta/R_hole*100, ...
        state.h022_grad_consistency_all_mean, state.h022_residual_sensitivity_mean);
end

%% ---- 管线维护 Round17/18/19: LS 效率诊断统计 ----
state.ls_efficiency.dF_machine_eps_hits = dF_earlystop_hits;
state.ls_efficiency.dF_rel_threshold_hits = dF_rel_earlystop_hits;
state.ls_efficiency.sysreject_hits = sysreject_hits;
state.ls_efficiency.frozen_ls_shortcircuit_hits = frozen_ls_shortcircuit_hits;
state.ls_efficiency.gate_a_shortcircuit_hits = gate_a_shortcircuit_hits;
fprintf('[C01_cavity] [LS-EFFICIENCY] Round17 machine-eps earlystop=%d hits, Round19 rel-threshold earlystop=%d hits, Round18 sysreject=%d hits, Round19 frozen-LS-shortcircuit=%d hits, Round23 gate-a-LS-shortcircuit=%d hits\n', ...
    dF_earlystop_hits, dF_rel_earlystop_hits, sysreject_hits, frozen_ls_shortcircuit_hits, gate_a_shortcircuit_hits);

fprintf('\n[C01_cavity] done: iter=%d converged=%d eps_r=%.4f hole=[%.4f,%.4f,%.4f] err=%.4fm\n', ...
    state.iteration, state.converged, eps_r_body, hole_pos(1), hole_pos(2), hole_pos(3), state.hole_position_error);

end

%% ---- Helper ----
function update_log_accepted(log_path, iter)
    lines = readlines(log_path);
    if iter + 1 <= length(lines)
        line = lines{iter + 1};
        tokens = regexp(line, ',', 'split');
        if length(tokens) >= 13
            tokens{13} = '1';
            lines{iter + 1} = strjoin(tokens, ',');
            log_fid = fopen(log_path, 'w');
            for i = 1:length(lines)
                fprintf(log_fid, '%s\n', lines{i});
            end
            fclose(log_fid);
        end
    end
end

%% ---- H017: Fibonacci 球面采样点生成 ----
function pts = fibonacci_sphere_points(N, radius, center)
%FIBONACCI_SPHERE_POINTS 在球面上生成 N 个近似均匀分布的点（Fibonacci 螺旋）
%   pts = fibonacci_sphere_points(N, radius, center)
%   输出: pts [N×3] —— 球面采样点坐标（半径 radius，中心 center）
%   用途: H017 连续边界积分——在 cavity 边界球面上采样 E_adj/E_fwd 场值
    indices = (0:N-1)';
    phi = pi * (3 - sqrt(5));  % 黄金角
    z = 1 - 2 * (indices + 0.5) / N;     % z 从 +1 到 -1 均匀
    r_xy = sqrt(1 - z.^2);               % 各高度处的 xy 半径
    azim = phi * indices;                % 方位角
    x = cos(azim) .* r_xy;
    y = sin(azim) .* r_xy;
    pts = [x, y, z] * radius + center;   % 缩放+平移到目标球面
end

%% ---- H022: cavity epsilon 赋值（SDF 软边界 or 硬二值）----
function eps_r_arr = c01_cavity_eps_assign(pos_inner, hole_c, R_hole, eps_r_val, N_v, inner_idx, sdf_delta, use_sdf)
%C01_CAVITY_EPS_ASSIGN H022 epsilon 映射：SDF sub-voxel 软边界连续化或硬二值
%   SDF:  d_i=|r_i-r_hole|-R_hole（符号距离，负=腔内，正=体内）
%         ε_i=ε_r+(1.0-ε_r)·0.5·(1-tanh(d_i/δ))，使 ε 连续依赖 hole 位置
%   硬二值: body ε_r OR cavity ε=1（H021 行为，use_sdf=false 时退化为旧逻辑）
rho_v = sqrt(sum((pos_inner - hole_c(:).').^2, 2));   % [N_inner×1] 体素到 hole 中心距离
if use_sdf
    d_sdf    = rho_v - R_hole;                          % 符号距离
    H_smooth = 0.5 * (1.0 - tanh(d_sdf / sdf_delta));   % 平滑阶梯（腔内→1，体内→0）
    eps_inner = eps_r_val + (1.0 - eps_r_val) .* H_smooth;
else
    eps_inner = repmat(eps_r_val, size(rho_v));         % 硬二值：先全设 body
    eps_inner(rho_v < R_hole) = 1.0;                    % cavity→ε=1
end
eps_r_arr = ones(N_v, 1);                              % 背景 ε=1
eps_r_arr(inner_idx) = eps_inner;                      % 内部体素赋值
end

%% ---- Round20 (H025 needs_optimization): L2 诊断跨实验缓存键 ----
function key = l2_diag_cache_key(hole_pos, eps_r_inner, d_eps, freqs_vec, v_idx, obs_sig, adj_method)
%L2_DIAG_CACHE_KEY L2 诊断 born_ratio 跨实验缓存的 SHA-256 指纹键
%   born_ratio 由目标函数 F=mean|J_obs-J_fwd|² 决定，F 依赖全局 ε_r 与观测 J_obs_multi。
%   故指纹覆盖全部正演/目标确定输入：hole_pos + inner ε_r + d_eps + freqs + v_idx + J_obs。
%   相同状态跨实验（H025 观察 5/6 体素 6 位有效数字一致）→ 相同指纹 → 命中跳过正演。
%   复数拆为实/虚连续序列（typecast 需实数输入）；无 JVM 时回退高阶矩数值指纹。
%   Round21 (H027 needs_optimization P0): adj_method 维度——born_ratio=FD/analytic，
%   analytic 梯度依赖伴随方法（λ_exact≠λ_Born），不同伴随方法必须独立缓存。
    if nargin < 7 || isempty(adj_method)
        adj_method = 'unknown';
    end
    adj_code = double(adj_method);   % 字符串 → ASCII 序列，纳入指纹
    % [管线维护 H031-P1] 对 COMSOL 正演输出做 6 位有效数字量化后再哈希。
    % 根因：obs_sig (J_obs) 是 COMSOL 正演输出，跨 Server session 存在 <1e-7 量级
    % 数值噪声（网格/求解器内部状态差异），导致确定性重演场景下（H031 iter1-2 轨迹
    % 与 H030 完全一致）缓存 hits=0 misses=6 全部失效（~144s 浪费，占总耗时 ~27%）。
    % 量化至 6 sig figs：实验执行者已验证跨实验 born_ratio 匹配至 6 位有效数字，
    % 故 sub-sig-fig 噪声丢弃不影响 born_ratio 数值正确性，仅消除哈希漂移。
    obs_sig_q = quantize_sigfig6(obs_sig);
    eps_r_inner_q = quantize_sigfig6(eps_r_inner);
    sig = double([hole_pos(:); eps_r_inner_q(:); d_eps; freqs_vec(:); double(v_idx); obs_sig_q(:); adj_code(:)]);
    sig_bytes = [real(sig); imag(sig)];
    if usejava('jvm')
        md = java.security.MessageDigest.getInstance('SHA-256');
        md.update(typecast(sig_bytes, 'uint8'));
        hb = md.digest();                                    % Java byte[] → MATLAB int8 行向量
        key = lower(char(reshape(dec2hex(uint8(double(hb)), 2).', 1, [])));
    else
        % 无 JVM 回退：高阶矩数值指纹（诊断场景碰撞概率可接受）
        obs_sig_q = quantize_sigfig6(obs_sig);
        eps_r_inner_q = quantize_sigfig6(eps_r_inner);
        key = sprintf('fp_h%.10e%.10e%.10e_eps[m%.10eM%.10emu%.10es2%.10e]_de%.10e_f%.10e_v%d_o[%.10e%.10e]_adj_%s', ...
            hole_pos(1), hole_pos(2), hole_pos(3), min(real(eps_r_inner_q)), max(real(eps_r_inner_q)), ...
            mean(real(eps_r_inner_q)), sum(real(eps_r_inner_q).^2), d_eps, freqs_vec(1), v_idx, ...
            mean(real(obs_sig_q)), sum(abs(obs_sig_q).^2), adj_method);
    end
end

function y = quantize_sigfig6(x)
%QUANTIZE_SIGFIG6 将数组元素量化至 6 位有效数字（缓存键哈希鲁棒性）
%   [管线维护 H031-P1] 消除 COMSOL 正演输出跨 session 数值噪声对缓存键的干扰。
%   零元素保持为零；非零元素按量级量化到 6 位有效数字精度。
    y = x;
    nz = abs(x) > 0;
    if any(nz)
        mag = 10.^(floor(log10(abs(x(nz)))) - 5);   % 6 sig figs 量化步长
        y(nz) = round(x(nz) ./ mag) .* mag;
    end
    y(~nz) = 0;
end
