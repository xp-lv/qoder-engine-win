function result = run_inversion_complex(max_iter, mu_init)
%RUN_INVERSION_COMPLEX H038: 复数均匀球反演（FD 梯度周期性重新标定 + 标定系数 signed-scale 幅值裁剪）
%
%   H033 基础 + H034 FD 标定 + H035 周期性重新标定 + H036 Tikhonov 权重分离 + H037 abs() 符号锁定 + H038 signed-scale 幅值裁剪
%   （epoch: complex_high_contrast_20m5j, round 3→6）
%
%   H037 核心改进（在 H036 Tikhonov 先验权重分离 ε_re 突破但 ε_im 退化的基础上）：
%     H036 权重分离成功解除 ε_re 停滞（88.7%/17.73），但 recalib#4(iter10) 起
%     scale_im 符号翻转（+700→-471→-202），ε_im 梯度方向被反转（74.6%/-3.73，
%     FD sign eps_im 终点 0% FAIL）。根因：标定系数 scale=g_FD/g_Wirt 在 g_Wirt
%     接近零时比值过零变负（数值不稳定伪影，非物理信号）。
%     H037 对 scale_re/scale_im 强制取 abs() 锁定符号为正——标定系数是纯幅值
%     修正因子其符号应始终为正（H033 已验证 Wirtinger 符号约定正确）。
%     唯一变更：scale_re_new = abs(g_FD_re/g_Wirt_re)、scale_im_new = abs(g_FD_im/g_Wirt_im)。
%     正演/伴随源/Wirtinger 分离/周期性 K=3 标定/Tikhonov 权重分离/参数化/步长/
%     初始值/max_iter/Armijo 参数/FD 标定公式/δ 步长全部不变（H036 配置不变）。
%
%   H038 核心改进（在 H037 abs() 符号锁定被实验证伪的基础上）：
%     H037 实验证伪：abs() 强制取正消除了 H036 的 scale_im 符号翻转，但未恢复 ε_im
%     收敛（71.2%/-3.56 vs H036 74.6%/-3.73）。根因：abs() 仅处理符号维度，未解决幅值
%     维度——scale_im 绝对值高达 +700 仍导致过冲/步长坍缩；且 abs() 强制取正抹去了
%     标定系数的真实符号信息（recalib#4/#5 g_FD 与 g_Wirt 为真实反号，abs 锁入错误方向）。
%     H038 将 FD 标定系数从 abs(g_FD/g_Wirt) 替换为 signed-scale + 幅值裁剪——
%     scale = clamp(g_FD/g_Wirt, -scale_max, +scale_max)（scale_max=200）：
%     (1) signed-scale 保留标定系数自然符号（g_Wirt 良好条件化时比值自然给出正确符号）；
%     (2) amplitude clipping 裁剪幅值上限 ±200，消除 +700/-471 极端值导致的过冲/步长坍缩。
%     唯一变更：scale_re_new/scale_im_new 从 abs() 替换为 max(-scale_max, min(scale_max, ratio))。
%     正演/伴随源/Wirtinger 分离/周期性 K=3 标定/Tikhonov 权重分离/参数化/步长/
%     初始值/max_iter/Armijo 参数/FD 标定公式/δ 步长全部不变（H036 配置不变）。
%
%   H035 核心改进（在 H034 FD 标定成功但标定系数恒定性失效的基础上）：
%     H034 仅首轮标定一次 scale_re/scale_im，但 H034 实验证明 scale 是 ε_r 的状态依赖
%     函数（scale_re 从 iter0 的 20.23 漂移至终点 63.90，3.16× 变化）→ 后期标定系数
%     失配→ε_re 方向梯度被低估→Tikhonov 先验压制→ε_re 停滞 64.5%（12.91, 真值 20）
%     H035 将单次首轮标定升级为周期性重新标定：每 K=3 轮在当前 ε_r 处重新执行
%     central FD 标定（+4 次正演/次），重算 scale_re/scale_im 并替换旧系数，使标定
%     系数始终适配当前优化状态。iter 0/3/6/9/12 各重标（1-based: iter 1/4/7/10/13）。
%
%   保留 H034 全部配置（唯一变更：标定时间策略从“一次性”改为“周期性 K=3”）：
%     1. COMSOL 正演材料属性复数化：ε_r = ε_re + j·ε_im（真值 20-5j）
%     2. 伴随梯度 Wirtinger 演算分离（不变，仅输出乘以周期性更新的标定系数）
%     3. 双参数独立步长 + Tikhonov 先验 + 初期阻尼 + backtracking
%     4. FD 标定公式 / δ 步长 / scale 计算方法完全复用 H034 已验证实现
%
%   uniform_complex 参数化：所有 1164 体素共享同一复数 ε_r
%
%   用法：
%     >> run_inversion_complex()          % 默认 15 轮
%     >> run_inversion_complex(20, 0.5)   % 20 轮，初始步长 0.5

if nargin < 1 || isempty(max_iter), max_iter = 15; end
if nargin < 2 || isempty(mu_init), mu_init = 0.5; end

%% 0. 路径初始化
this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', ...
    'core_adjoint', 'experiment');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

%% 1. 初始化
p = config();
grid = build_measurement_grid(p);

% 提取 H033 参数
eps_true_re  = p.eps_r_true_re;     % 20.0
eps_true_im  = p.eps_r_true_im;     % -5.0
eps_init_re  = p.eps_r_init_re;     % 12.0
eps_init_im  = p.eps_r_init_im;     % -3.0
prior_re     = p.eps_r_prior_re;    % 12.0
prior_im     = p.eps_r_prior_im;    % -3.0
lambda_prior    = p.lambda_prior;      % 0.01 (基准值，H035 及之前单一权重)
lambda_prior_re = p.lambda_prior_re;   % H036: 实部先验权重（λ_prior/5，降低 5× 解除对 ε_re 压制）
lambda_prior_im = p.lambda_prior_im;   % H036: 虚部先验权重（λ_prior，保持不变）
damping_init    = p.damping_init;     % 0.3
damping_recover = p.damping_recover;  % 1.3
max_halvings    = p.max_halvings;     % 5

% H033 needs_optimization 维护参数（管线维护者固化）
cfg_mphstart_retry        = p.mphstart_retry;             % P0
saturation_early_stop_n   = p.saturation_early_stop_n;    % P2
saturation_short_circuit  = p.saturation_short_circuit;   % P2
cfg_fd_early_stop         = p.fd_early_stop;              % P1

% H035 FD 梯度标定参数（周期性重新标定）
fd_scale_enable            = p.fd_scale_enable;           % 启用 FD 标定
fd_calib_delta             = p.fd_calib_delta;            % FD 标定步长
fd_recalib_period          = p.fd_recalib_period;         % 周期性重新标定间隔 K
scale_max                  = p.scale_max;                 % [H038] signed-scale 幅值裁剪上限

fprintf('\n############################################################\n');
fprintf('#  H035 复数均匀球反演 + FD 梯度周期性重新标定 (complex_high_contrast_20m5j)\n');
fprintf('#  真值: eps_r = %.1f %+.1fj (对比度 20:1, tan delta=0.25)\n', 20.0, -5.0);
fprintf('#  初值: eps_r = %.1f %+.1fj (偏离真值, Tikhonov 先验)\n', 12.0, -3.0);
fprintf('#  max_iter=%d, mu_init=%g (H035: 周期性重新标定 K=%d, iter 1/4/7/10/13 各重算)\n', max_iter, mu_init, fd_recalib_period);
fprintf('############################################################\n\n');

fprintf('[H033] 连接 COMSOL Server (port %d)...\n', p.comsol_port);
% P0 维护: mphstart 失败自动重试 1 次（mphstop + mphstart），吸收端口偏移/抖动
mph_attempts = 2 - double(~cfg_mphstart_retry);
mph_ok = false;
for mph_try = 1:mph_attempts
    try
        mphstart(p.comsol_port);
        mph_ok = true;
        break;
    catch ME
        if contains(ME.message, 'Already connected')
            mph_ok = true;
            break;
        end
        if mph_try < mph_attempts
            fprintf('[H033] [WARN] mphstart 失败 (%s), 重试 (mphstop + mphstart)...\n', ME.message);
            try mphstop(p.comsol_port); pause(2); catch, end
        else
            fprintf('[H033] [FAIL] mphstart: %s (重试后仍失败)\n', ME.message);
            result = struct('status', 'fail', 'reason', 'mphstart_failed');
            return;
        end
    end
end

% 清理旧模型
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

fprintf('[H033] 加载 2layer.mph...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end

%% 2. 提取网格
fprintf('[H033] 提取 FEM 网格...\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('[H033] N_inner = %d 体素\n', N_inner);

%% 3. 预计算 J_obs（真值 eps_r = 20-5j）
fprintf('[H033] 预计算 J_obs (eps_r = 20-5j)...\n');
voxel.epsilon_r(~inner) = 1.0;  % 外层空气
voxel.epsilon_r(inner) = eps_true_re + 1j * eps_true_im;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs_norm = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs_norm < p.F_obs_min, F_obs_norm = 1.0; end
fprintf('[H033] F_obs = %.6e (真值 eps_r=20-5j)\n', F_obs_norm);

%% 4. 设置初始猜测
eps_re = eps_init_re;  % 12.0
eps_im = eps_init_im;  % -3.0
fprintf('[H033] 初始猜测: eps_r = %.2f %+.2fj\n', eps_re, eps_im);

%% 5. 迭代循环（Wirtinger 梯度 + Tikhonov + 阻尼 + backtracking）
k0_sq = p.k0^2;
dV_vec = voxel.dV;

history_F      = zeros(max_iter, 1);
history_eps_re = zeros(max_iter, 1);
history_eps_im = zeros(max_iter, 1);
history_g_re   = zeros(max_iter, 1);
history_g_im   = zeros(max_iter, 1);

damping = damping_init;
converged = false;
F_final = 0;

% H035: 周期性 FD 重新标定状态
scale_re = 1.0;                    % eps_re 标定系数（每 K 轮重新标定后更新）
scale_im = 1.0;                    % eps_im 标定系数
fd_calib_done = false;             % 首轮标定完成标志
recalib_count = 0;                 % 重新标定次数计数（含首轮）
history_scale_re = NaN(max_iter, 1);      % 逐轮 scale_re 记录（scale_evolution_tracking）
history_scale_im = NaN(max_iter, 1);      % 逐轮 scale_im 记录
history_scale_drift_re = NaN(max_iter, 1); % 相邻标定点 scale_re 漂移比值
history_scale_drift_im = NaN(max_iter, 1); % 相邻标定点 scale_im 漂移比值
scale_constancy_re = NaN;          % 末次标定漂移比值 re（兼容 H034 输出字段）
scale_constancy_im = NaN;          % 末次标定漂移比值 im（兼容 H034 输出字段）
history_data_prior_ratio = zeros(max_iter, 1);  % ||g_data||/||g_prior|| 逐轮记录（re+im 合成范数比）
history_data_prior_ratio_re = zeros(max_iter, 1); % [H036] ε_re 通道 ||g_data_re||/||g_prior_re||（关键验证指标：数据梯度主导 ratio>1.0）

% P2 维护: backtracking 饱和追踪状态
consecutive_saturation = 0;        % 连续饱和轮数计数
prev_eps_change = inf;             % 上一轮参数变化量
prev_round_saturated = false;      % 上一轮是否完全饱和（无接受步）

for iter = 1:max_iter
    fprintf('\n[H033] ===== 迭代 %d/%d =====\n', iter, max_iter);

    % --- 5a. 正演（复数 eps_r）---
    voxel.epsilon_r(inner) = eps_re + 1j * eps_im;
    update_epsilon(model, voxel, p);
    [E_total, ~, E_gauss] = solve_forward(model, voxel, p);

    % --- 5b. 残差 + 代价 ---
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, p);
    Delta_J = J_obs - lc.J_obs_perp;
    F_data = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs_norm;

    % Tikhonov 正则化（H036: 实虚部权重分离）
    F_tikh = lambda_prior_re * (eps_re - prior_re)^2 ...
           + lambda_prior_im * (eps_im - prior_im)^2;
    F_total = F_data + F_tikh;
    F_final = F_data;

    % 记录
    history_F(iter)      = sqrt(F_data);
    history_eps_re(iter) = eps_re;
    history_eps_im(iter) = eps_im;

    fprintf('[H033] sqrt(F_data)=%.6e, eps_re=%.4f, eps_im=%.4f, F_tikh=%.2e\n', ...
        sqrt(F_data), eps_re, eps_im, F_tikh);

    % 收敛检查
    if sqrt(F_data) < p.eps_tol_complex
        fprintf('[H033] *** sqrt(F) < %.2f, 收敛! ***\n', p.eps_tol_complex);
        converged = true;
        break;
    end

    % --- 5c. 伴随源构建 ---
    lc.k_vec = p.k0 * lc.k_dir;
    lc.J_obs_perp = J_obs;
    lc.Delta_J_perp = Delta_J;
    [Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);

    % --- 5d. 伴随求解 ---
    [lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
    if ~ok_adj
        fprintf('[H033] [FAIL] 伴随求解失败 (iter %d)\n', iter);
        break;
    end

    % --- 5e. 复数梯度（保留复数完整信息，不取 Re）---
    % g_complex(v) = -k0^2 * dV(v) * sum_i [conj(lambda_i) * E_i] / F_obs
    % 注意: lambda 已在 solve_adjoint 中做 conj(lambda_raw)
    g_complex = zeros(N_inner, 1);
    use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
        && size(E_gauss,1) == size(voxel.gauss_pos,1);

    if use_gauss
        gw = voxel.gauss_w;
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gw(gpi) * sum(E_gauss(gp(gpi),:) .* lambda_gauss(gp(gpi),:));
            end
            g_complex(vi) = -k0_sq * dV_vec(inner_idx(vi)) * gs;
        end
        fprintf('[H033] 复数梯度: 4-pt Gauss 积分 (%d 体素)\n', N_inner);
    else
        for vi = 1:N_inner
            g_complex(vi) = -k0_sq * dV_vec(inner_idx(vi)) ...
                * sum(E_total(vi,:) .* lambda(vi,:));
        end
        fprintf('[H033] 复数梯度: 质心近似 (%d 体素)\n', N_inner);
    end
    g_complex = g_complex / F_obs_norm;

    % uniform_complex: 总梯度 = 所有个体素复数梯度之和
    g_total = sum(g_complex);  % 复数标量

    % --- 5f. Wirtinger 演算分离（H033 不变）---
    % eps_r = eps_re + j*eps_im (COMSOL 约定)
    % dF/eps_re = 2*Re(g_total)
    % dF/eps_im = -2*Im(g_total)
    g_data_re = 2 * real(g_total);
    g_data_im = -2 * imag(g_total);

    % --- H035: 周期性 FD 梯度重新标定（每 K 轮在当前 ε_r 处重算 scale_re/scale_im 并替换）---
    % 触发条件: iter==1（首轮必标定）或每 K 轮（mod(iter-1,K)==0）
    %   K=fd_recalib_period（默认 3）→ 1-based iter 1/4/7/10/13 各重标
    do_recalib = fd_scale_enable && (mod(iter - 1, fd_recalib_period) == 0);
    if do_recalib
        recalib_count = recalib_count + 1;
        delta_calib = fd_calib_delta;
        scale_re_old = scale_re;
        scale_im_old = scale_im;

        if iter == 1
            fprintf('[H035] ===== 首轮 FD 梯度标定 #%d (delta=%.4e, +4 次正演) =====\n', recalib_count, delta_calib);
        else
            fprintf('[H035] ===== 周期性 FD 重新标定 #%d (iter %d, delta=%.4e, +4 次正演) =====\n', recalib_count, iter, delta_calib);
        end

        % --- FD for eps_re: central FD on F_data ---
        voxel.epsilon_r(inner) = (eps_re + delta_calib) + 1j * eps_im;
        update_epsilon(model, voxel, p);
        solve_quiet_c(model, p);
        sf_p = extract_scattered(model, grid);
        lc_p = lightcone_project(grid, sf_p, p);
        Fp_re = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

        voxel.epsilon_r(inner) = (eps_re - delta_calib) + 1j * eps_im;
        update_epsilon(model, voxel, p);
        solve_quiet_c(model, p);
        sf_m = extract_scattered(model, grid);
        lc_m = lightcone_project(grid, sf_m, p);
        Fm_re = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;

        g_FD_re_calib = (Fp_re - Fm_re) / (2 * delta_calib);

        % --- FD for eps_im: central FD on F_data ---
        voxel.epsilon_r(inner) = eps_re + 1j * (eps_im + delta_calib);
        update_epsilon(model, voxel, p);
        solve_quiet_c(model, p);
        sf_p = extract_scattered(model, grid);
        lc_p = lightcone_project(grid, sf_p, p);
        Fp_im = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

        voxel.epsilon_r(inner) = eps_re + 1j * (eps_im - delta_calib);
        update_epsilon(model, voxel, p);
        solve_quiet_c(model, p);
        sf_m = extract_scattered(model, grid);
        lc_m = lightcone_project(grid, sf_m, p);
        Fm_im = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;

        g_FD_im_calib = (Fp_im - Fm_im) / (2 * delta_calib);

        % --- H038: 计算新标定系数 scale_new = clamp(g_FD / g_Wirt)（signed-scale + 幅值裁剪）---
        % H038 命题: 标定系数 scale=g_FD/g_Wirt 保留自然符号（signed-scale）——当 g_Wirt 良好
        %   条件化时比值自然给出正确符号（H033 验证 Wirtinger 符号约定正确），不强制取正。
        %   同时裁剪幅值上限至 ±scale_max（amplitude clipping）——当 g_Wirt→0 时比值发散，
        %   裁剪极端幅值防过冲/步长坍缩（消除 H036 +700/-471 量级极端值）。
        %   clamp(ratio) 等价于 sign(ratio)×min(|ratio|, scale_max)。
        %   修复 H037 abs() 符号锁定的两个缺陷：(1) 强制取正抹去真实符号信息；
        %   (2) 对幅值完全无约束（+700 与 +20 同等对待）。
        if abs(g_data_re) > 1e-30
            scale_re_raw = g_FD_re_calib / g_data_re;
            scale_re_new = max(-scale_max, min(scale_max, scale_re_raw));
        else
            scale_re_raw = scale_re_old;
            scale_re_new = scale_re_old;
            fprintf('[H035] [WARN] g_data_re≈0, scale_re 保持 %.2f\n', scale_re_old);
        end
        if abs(g_data_im) > 1e-30
            scale_im_raw = g_FD_im_calib / g_data_im;
            scale_im_new = max(-scale_max, min(scale_max, scale_im_raw));
        else
            scale_im_raw = scale_im_old;
            scale_im_new = scale_im_old;
            fprintf('[H035] [WARN] g_data_im≈0, scale_im 保持 %.2f\n', scale_im_old);
        end

        % --- 漂移监测: 相邻标定点间 scale 变化（H035 核心验证指标）---
        if fd_calib_done
            drift_re = scale_re_new / scale_re_old;
            drift_im = scale_im_new / scale_im_old;
            history_scale_drift_re(iter) = drift_re;
            history_scale_drift_im(iter) = drift_im;
            scale_constancy_re = drift_re;
            scale_constancy_im = drift_im;
            fprintf('[H035] 标定漂移: scale_re drift=%.3f, scale_im drift=%.3f (目标: 相邻标定 <1.5×)\n', ...
                drift_re, drift_im);
        end

        % --- 替换标定系数（H035 核心: 用当前 ε_r 处的新系数替代旧系数）---
        scale_re = scale_re_new;
        scale_im = scale_im_new;
        fd_calib_done = true;

        fprintf('[H035] 标定结果 #%d:\n', recalib_count);
        fprintf('[H035]   eps_re: g_FD=%+.4e, g_Wirt=%+.4e → scale_re=%.2f (sign_match=%s)\n', ...
            g_FD_re_calib, g_data_re, scale_re, ternary_s(g_FD_re_calib*g_data_re>0,'YES','NO'));
        fprintf('[H035]   eps_im: g_FD=%+.4e, g_Wirt=%+.4e → scale_im=%.2f (sign_match=%s)\n', ...
            g_FD_im_calib, g_data_im, scale_im, ternary_s(g_FD_im_calib*g_data_im>0,'YES','NO'));
        % [H038] signed-scale + 幅值裁剪诊断: 保留自然符号，当 |raw_ratio| 超过 scale_max 时报告裁剪触发
        if abs(scale_re_raw) > scale_max || abs(scale_im_raw) > scale_max
            fprintf('[H038]   [SIGNED-CLIP] 幅值裁剪已触发: scale_re raw=%+.2f→%.2f%s, scale_im raw=%+.2f→%.2f%s (上限 ±%.0f)\n', ...
                scale_re_raw, scale_re, ternary_s(abs(scale_re_raw)>scale_max,'[裁剪]',''), ...
                scale_im_raw, scale_im, ternary_s(abs(scale_im_raw)>scale_max,'[裁剪]',''), scale_max);
        else
            fprintf('[H038]   [SIGNED-CLIP] |raw_ratio| 均在 ±%.0f 内，无裁剪触发（signed-scale 保留自然符号）\n', scale_max);
        end
    end

    % --- 逐轮记录标定系数（scale_evolution_tracking）---
    history_scale_re(iter) = scale_re;
    history_scale_im(iter) = scale_im;

    % --- H035: 应用 FD 标定系数（标定后的数据梯度）---
    g_data_re_scaled = g_data_re * scale_re;
    g_data_im_scaled = g_data_im * scale_im;

    % Tikhonov 梯度（解析公式，幅值正确，不标定；H036: 实虚部权重分离）
    g_tikh_re = 2 * lambda_prior_re * (eps_re - prior_re);
    g_tikh_im = 2 * lambda_prior_im * (eps_im - prior_im);
    g_total_re = g_data_re_scaled + g_tikh_re;
    g_total_im = g_data_im_scaled + g_tikh_im;

    history_g_re(iter) = g_data_re;
    history_g_im(iter) = g_data_im;

    % H035/H036 monitoring: ||g_data|| / ||g_prior|| 平衡监测
    norm_g_data  = sqrt(g_data_re_scaled^2 + g_data_im_scaled^2);
    norm_g_prior = sqrt(g_tikh_re^2 + g_tikh_im^2);
    if norm_g_prior > 1e-30
        history_data_prior_ratio(iter) = norm_g_data / norm_g_prior;
    else
        history_data_prior_ratio(iter) = inf;
    end
    % [H036] ε_re 通道逐轮 ||g_data_re|| / ||g_prior_re|| 比值（核心验证指标：
    %   ratio>1.0 表示数据梯度主导 ε_re 收敛，对比 H035 的先验压制状态）
    if abs(g_tikh_re) > 1e-30
        history_data_prior_ratio_re(iter) = abs(g_data_re_scaled) / abs(g_tikh_re);
    else
        history_data_prior_ratio_re(iter) = inf;
    end

    fprintf('[H033] g_data (标定前): re=%+.4e, im=%+.4e\n', g_data_re, g_data_im);
    fprintf('[H035] g_data (标定后): re=%+.4e, im=%+.4e (scale_re=%.1f, scale_im=%.1f)\n', ...
        g_data_re_scaled, g_data_im_scaled, scale_re, scale_im);
    fprintf('[H035] g_tikh: re=%+.4e, im=%+.4e\n', g_tikh_re, g_tikh_im);
    fprintf('[H035] ||g_data||/||g_prior|| = %.3f (目标∈[0.5,2.0])\n', history_data_prior_ratio(iter));
    fprintf('[H036] ε_re 通道 ||g_data_re||/||g_prior_re|| = %.3f (目标>1.0 数据梯度主导，λ_prior_re=%.4f)\n', ...
        history_data_prior_ratio_re(iter), lambda_prior_re);
    fprintf('[H033] g_total: re=%+.4e, im=%+.4e (含Tikhonov)\n', g_total_re, g_total_im);

    % --- 5g. 步长计算 + backtracking ---
    eps_re_old = eps_re;
    eps_im_old = eps_im;
    F_old = F_total;

    alpha_re = mu_init * damping / max(abs(g_total_re), 1e-30);
    alpha_im = mu_init * damping / max(abs(g_total_im), 1e-30);

    accepted = false;
    eps_re_try = eps_re_old;
    eps_im_try = eps_im_old;

    % P2 维护: 饱和短路 -- 上轮全 reject 且参数几乎未变 -> 跳过本轮 5 次 trial（确定性重演）
    skip_trials = saturation_short_circuit ...
        && prev_round_saturated && prev_eps_change < 1e-6;
    if skip_trials
        fprintf('[H033] [P2] 饱和短路: 跳过 backtracking trials (上轮全 reject, deps=%.2e)\n', prev_eps_change);
    end

    for halving = 0:max_halvings
        if skip_trials
            break;  % 确定性重演，不做试算
        end
        eps_re_try = eps_re_old - alpha_re * g_total_re;
        eps_im_try = eps_im_old - alpha_im * g_total_im;

        % 物理约束: eps_re in [1, 50], eps_im in [-20, 0] (损耗, 无增益)
        eps_re_try = max(1.0, min(50.0, eps_re_try));
        eps_im_try = max(-20.0, min(0.0, eps_im_try));

        % 正演试算
        voxel.epsilon_r(inner) = eps_re_try + 1j * eps_im_try;
        update_epsilon(model, voxel, p);
        solve_ok = false;
        try
            model.sol('sol1').clearSolutionData();
            model.sol('sol1').clearSolution();
            model.sol('sol1').runAll();
            solve_ok = true;
        catch ME_solve
            fprintf('[H033] [WARN] 试算求解失败 (halving %d): %s\n', halving, ME_solve.message);
        end

        if ~solve_ok
            alpha_re = alpha_re * 0.5;
            alpha_im = alpha_im * 0.5;
            continue;
        end

        sf_try = extract_scattered(model, grid);
        lc_try = lightcone_project(grid, sf_try, p);
        dJ_try = J_obs - lc_try.J_obs_perp;
        F_try_data = sum(dOmega .* sum(abs(dJ_try).^2, 2)) / F_obs_norm;
        F_try_tikh = lambda_prior_re * (eps_re_try - prior_re)^2 ...
                   + lambda_prior_im * (eps_im_try - prior_im)^2;
        F_try = F_try_data + F_try_tikh;

        if F_try < F_old
            accepted = true;
            F_final = F_try_data;
            fprintf('[H033] OK 步长接受 (halving=%d): eps_re=%.4f, eps_im=%.4f, sqrt(F)=%.6e\n', ...
                halving, eps_re_try, eps_im_try, sqrt(F_try_data));
            break;
        else
            alpha_re = alpha_re * 0.5;
            alpha_im = alpha_im * 0.5;
            if halving < max_halvings
                fprintf('[H033] ! backtracking (halving=%d): 步长减半\n', halving+1);
            end
        end
    end

    if ~accepted
        fprintf('[H033] ! 步长饱和 (%d 次减半), 接受最小步长\n', max_halvings);
    end

    eps_re = eps_re_try;
    eps_im = eps_im_try;

    % P2 维护: 连续饱和早停 + 参数变化追踪
    round_saturated = ~accepted;
    prev_eps_change = sqrt((eps_re - eps_re_old)^2 + (eps_im - eps_im_old)^2);
    prev_round_saturated = round_saturated;
    if round_saturated
        consecutive_saturation = consecutive_saturation + 1;
        if consecutive_saturation >= saturation_early_stop_n
            fprintf('[H033] [P2] 连续 %d 轮 backtracking 饱和无接受步, 提前终止\n', consecutive_saturation);
            break;
        end
    else
        consecutive_saturation = 0;
    end

    % 阻尼恢复
    damping = min(1.0, damping * damping_recover);
    fprintf('[H033] damping = %.3f\n', damping);
end

% 截断未使用的历史
history_F      = history_F(1:iter);
history_eps_re = history_eps_re(1:iter);
history_eps_im = history_eps_im(1:iter);
history_g_re   = history_g_re(1:iter);
history_g_im   = history_g_im(1:iter);
history_scale_re = history_scale_re(1:iter);
history_scale_im = history_scale_im(1:iter);
history_scale_drift_re = history_scale_drift_re(1:iter);
history_scale_drift_im = history_scale_drift_im(1:iter);
history_data_prior_ratio    = history_data_prior_ratio(1:iter);
history_data_prior_ratio_re = history_data_prior_ratio_re(1:iter);

% [P0-H039 维护] 统一 result/history 输出语义（管线维护者固化）
%   根因: 主循环内 history_*(iter) 在 backtracking 步"之前"记录（步前状态），
%         而 result.residual/eps_*_final 取循环结束后的"步后"状态——
%         二者差一步，导致 history末值 ≠ result（H039 实测: sqrt(F) 末值
%         0.175897 vs result.residual 0.203535；eps_re 17.3877 vs 17.1377）。
%   修复（采纳实验执行者 needs_optimization 建议"把额外步也记入 history，
%         保留全部信息"）: 循环结束后若终值状态相对末条 history 发生了位移
%         （即末轮确实执行了一次 backtracking 步且尚未入账），则把该步后
%         状态追加进 history，使 history_*(end) 严格 == result.*_final。
%         收敛提前 break / 伴随失败 break 时 eps 未更新，guard 为假不追加
%         （此时 history末值 与 result 本就一致，避免重复条目）。
%   语义: history 现为完整优化轨迹 = [初始态, 步1后, ..., 步N后]，
%         长度 = 实际步数 + 1；history_*(end) 与 result.*_final 同源一致。
if ~isempty(history_F) && ...
        (abs(eps_re - history_eps_re(end)) > 1e-9 || ...
         abs(eps_im - history_eps_im(end)) > 1e-9)
    history_F(end+1, 1)      = sqrt(F_final);   % 与 result.residual 同源
    history_eps_re(end+1, 1) = eps_re;          % 与 result.eps_re_final 同源
    history_eps_im(end+1, 1) = eps_im;          % 与 result.eps_im_final 同源
end

%% 6. FD sign 验证（H033 最关键验收指标）
fprintf('\n############################################################\n');
fprintf('#  FD Sign 验证 (dF/deps_re 和 dF/deps_im 各 >=80%%)\n');
fprintf('############################################################\n');

% 在最终 eps_r 处重新计算伴随梯度
fprintf('[H033] 在最终 eps_r=%.4f%+.4fj 处重新计算伴随梯度...\n', eps_re, eps_im);
voxel.epsilon_r(inner) = eps_re + 1j * eps_im;
[E_total_fd, ~, E_gauss_fd] = solve_forward(model, voxel, p);

sf_fd = extract_scattered(model, grid);
lc_fd = lightcone_project(grid, sf_fd, p);
Delta_J_fd = J_obs - lc_fd.J_obs_perp;
F_base = sum(dOmega .* sum(abs(Delta_J_fd).^2, 2)) / F_obs_norm;

% 伴随
lc_fd.k_vec = p.k0 * lc_fd.k_dir;
lc_fd.J_obs_perp = J_obs;
lc_fd.Delta_J_perp = Delta_J_fd;
[Js_fd, Ms_fd, source_pos_fd, ~] = build_adjoint_source_fullmaxwell(grid, lc_fd, p);
[lambda_fd, ok_adj_fd, lambda_gauss_fd] = solve_adjoint(model, voxel, p, Js_fd, source_pos_fd, Ms_fd);

if ok_adj_fd
    % 复数伴随梯度
    g_c_fd = zeros(N_inner, 1);
    use_gauss_fd = ~isempty(E_gauss_fd) && ~isempty(lambda_gauss_fd) ...
        && size(E_gauss_fd,1) == size(voxel.gauss_pos,1);
    if use_gauss_fd
        gw_fd = voxel.gauss_w;
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gw_fd(gpi) * sum(E_gauss_fd(gp(gpi),:) .* lambda_gauss_fd(gp(gpi),:));
            end
            g_c_fd(vi) = -k0_sq * dV_vec(inner_idx(vi)) * gs;
        end
    else
        for vi = 1:N_inner
            g_c_fd(vi) = -k0_sq * dV_vec(inner_idx(vi)) * sum(E_total_fd(vi,:) .* lambda_fd(vi,:));
        end
    end
    g_c_fd = g_c_fd / F_obs_norm;
    g_total_fd = sum(g_c_fd);
    g_adj_re = 2 * real(g_total_fd);
    g_adj_im = -2 * imag(g_total_fd);
else
    fprintf('[H033] [WARN] 伴随求解失败, 使用最后一轮迭代梯度\n');
    g_adj_re = history_g_re(end);
    g_adj_im = history_g_im(end);
end

fprintf('[H033] 伴随梯度: g_adj_re=%+.4e, g_adj_im=%+.4e\n', g_adj_re, g_adj_im);
fprintf('[H033] FD 基准: sqrt(F)=%.6e\n', sqrt(F_base));

fd_deltas = p.fd_deltas_complex;
N_fd = length(fd_deltas);

% --- FD for eps_re ---
fprintf('\n[H033] FD for eps_re (dF/deps_re):\n');
g_FD_re_arr = zeros(N_fd, 1);
sign_re_arr = false(N_fd, 1);
fd_evaluated_re = 0;
for fi = 1:N_fd
    delta = fd_deltas(fi);

    % F(eps_re + delta)
    voxel.epsilon_r(inner) = (eps_re + delta) + 1j * eps_im;
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_p = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf_p, p);
    F_p = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

    % F(eps_re - delta)
    voxel.epsilon_r(inner) = (eps_re - delta) + 1j * eps_im;
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_m = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf_m, p);
    F_m = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;

    g_FD_re_arr(fi) = (F_p - F_m) / (2 * delta);
    sign_re_arr(fi) = (g_FD_re_arr(fi) * g_adj_re) > 0;

    fprintf('  eps_re FD delta=%.4e: g_FD=%+.4e, g_adj=%+.4e, sign=%s\n', ...
        delta, g_FD_re_arr(fi), g_adj_re, ternary_s(sign_re_arr(fi), 'OK', 'XX'));
    fd_evaluated_re = fi;

    % P1 维护: 早停 -- 前 2 个粗步长 sign 全一致则跳过细步长（噪声陷阱）
    if cfg_fd_early_stop && fi >= 2 && all(sign_re_arr(1:fi))
        fprintf('  [P1] eps_re FD 早停: 前 %d 个步长 sign 全一致, 跳过剩余细步长\n', fi);
        break;
    end
end
fd_sign_rate_re = sum(sign_re_arr(1:fd_evaluated_re)) / fd_evaluated_re;

% --- FD for eps_im ---
fprintf('\n[H033] FD for eps_im (dF/deps_im):\n');
g_FD_im_arr = zeros(N_fd, 1);
sign_im_arr = false(N_fd, 1);
fd_evaluated_im = 0;
for fi = 1:N_fd
    delta = fd_deltas(fi);

    % F(eps_im + delta)
    voxel.epsilon_r(inner) = eps_re + 1j * (eps_im + delta);
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_p = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf_p, p);
    F_p = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs_norm;

    % F(eps_im - delta)
    voxel.epsilon_r(inner) = eps_re + 1j * (eps_im - delta);
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_m = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf_m, p);
    F_m = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs_norm;

    g_FD_im_arr(fi) = (F_p - F_m) / (2 * delta);
    sign_im_arr(fi) = (g_FD_im_arr(fi) * g_adj_im) > 0;

    fprintf('  eps_im FD delta=%.4e: g_FD=%+.4e, g_adj=%+.4e, sign=%s\n', ...
        delta, g_FD_im_arr(fi), g_adj_im, ternary_s(sign_im_arr(fi), 'OK', 'XX'));
    fd_evaluated_im = fi;

    % P1 维护: 早停 -- 前 2 个粗步长 sign 全一致则跳过细步长（噪声陷阱）
    if cfg_fd_early_stop && fi >= 2 && all(sign_im_arr(1:fi))
        fprintf('  [P1] eps_im FD 早停: 前 %d 个步长 sign 全一致, 跳过剩余细步长\n', fi);
        break;
    end
end
fd_sign_rate_im = sum(sign_im_arr(1:fd_evaluated_im)) / fd_evaluated_im;

fprintf('\n[H033] FD sign 通过率: eps_re=%.0f%% (%d/%d), eps_im=%.0f%% (%d/%d)\n', ...
    100*fd_sign_rate_re, sum(sign_re_arr(1:fd_evaluated_re)), fd_evaluated_re, ...
    100*fd_sign_rate_im, sum(sign_im_arr(1:fd_evaluated_im)), fd_evaluated_im);

fd_pass_re = fd_sign_rate_re >= p.fd_sign_threshold;
fd_pass_im = fd_sign_rate_im >= p.fd_sign_threshold;
fprintf('[H033] FD sign 验收: eps_re %s (>=%.0f%%), eps_im %s (>=%.0f%%)\n', ...
    ternary_s(fd_pass_re, 'PASS', 'FAIL'), 100*p.fd_sign_threshold, ...
    ternary_s(fd_pass_im, 'PASS', 'FAIL'), 100*p.fd_sign_threshold);

% H035: 标定系数演化报告（周期性重新标定验证）
if fd_calib_done
    scale_re_final = g_FD_re_arr(fd_evaluated_re) / g_adj_re;
    scale_im_final = g_FD_im_arr(fd_evaluated_im) / g_adj_im;
    first_scale_re = history_scale_re(find(~isnan(history_scale_re), 1));
    first_scale_im = history_scale_im(find(~isnan(history_scale_im), 1));
    fprintf('\n[H035] 标定系数演化报告 (周期性重新标定 K=%d, 共 %d 次重标):\n', fd_recalib_period, recalib_count);
    fprintf('[H035]   scale_re: 首次=%.2f, 末次重标=%.2f, 终点独立FD=%.2f (总漂移=%.2f×)\n', ...
        first_scale_re, scale_re, scale_re_final, scale_re_final/first_scale_re);
    fprintf('[H035]   scale_im: 首次=%.2f, 末次重标=%.2f, 终点独立FD=%.2f (总漂移=%.2f×)\n', ...
        first_scale_im, scale_im, scale_im_final, scale_im_final/first_scale_im);
    drift_iters = find(~isnan(history_scale_drift_re));
    if ~isempty(drift_iters)
        dr_re_str = sprintf('%.2f ', history_scale_drift_re(drift_iters));
        dr_im_str = sprintf('%.2f ', history_scale_drift_im(drift_iters));
        fprintf('[H035]   scale_re 逐周期漂移: [%s] (目标 |drift-1|<0.5)\n', strtrim(dr_re_str));
        fprintf('[H035]   scale_im 逐周期漂移: [%s]\n', strtrim(dr_im_str));
    end
end

%% 7. 恢复率评估
if eps_true_re ~= 0
    eps_re_recovery = (eps_re / eps_true_re) * 100;
else
    eps_re_recovery = NaN;
end
if eps_true_im ~= 0
    eps_im_recovery = (eps_im / eps_true_im) * 100;
else
    eps_im_recovery = NaN;
end

fprintf('\n[H033] eps_re 恢复率: %.1f%% (%.4f vs 真值 %.1f, 目标>=80%%)\n', ...
    eps_re_recovery, eps_re, eps_true_re);
fprintf('[H033] eps_im 恢复率: %.1f%% (%.4f vs 真值 %.1f, 目标>=60%%)\n', ...
    eps_im_recovery, eps_im, eps_true_im);

%% 8. 最终报告
fprintf('\n############################################################\n');
fprintf('#  H033 复数均匀球反演结果\n');
fprintf('############################################################\n');
fprintf('#  真值: eps_r = %.1f %+.1fj\n', eps_true_re, eps_true_im);
fprintf('#  初值: eps_r = %.2f %+.2fj\n', eps_init_re, eps_init_im);
fprintf('#  终值: eps_r = %.4f %+.4fj\n', eps_re, eps_im);
fprintf('#  迭代: %d/%d\n', iter, max_iter);
fprintf('#  收敛: %s\n', string(converged));
fprintf('#  最终 sqrt(F): %.6e\n', sqrt(F_final));
fprintf('#  FD sign eps_re: %.0f%% (%s)\n', 100*fd_sign_rate_re, ternary_s(fd_pass_re,'PASS','FAIL'));
fprintf('#  FD sign eps_im: %.0f%% (%s)\n', 100*fd_sign_rate_im, ternary_s(fd_pass_im,'PASS','FAIL'));
fprintf('#  eps_re 恢复率: %.1f%%\n', eps_re_recovery);
fprintf('#  eps_im 恢复率: %.1f%%\n', eps_im_recovery);
fprintf('############################################################\n');

% 残差历史
fprintf('\n残差历史:\n');
for hi = 1:length(history_F)
    if history_F(hi) > 0
        fprintf('  iter %d: sqrt(F)=%.6e, eps_re=%.4f, eps_im=%.4f\n', ...
            hi, history_F(hi), history_eps_re(hi), history_eps_im(hi));
    end
end

%% 9. 保存结果
result = struct();
result.hypothesis_id    = 'H035';
result.epoch            = 'complex_high_contrast_20m5j';
result.converged        = converged;
result.iteration        = iter;
result.residual         = sqrt(F_final);   % [P0-H039] 保证 == result.history_F(end)（见循环后追加块）
result.eps_re_final     = eps_re;          % [P0-H039] 保证 == result.history_eps_re(end)
result.eps_im_final     = eps_im;          % [P0-H039] 保证 == result.history_eps_im(end)
result.eps_re_true      = eps_true_re;
result.eps_im_true      = eps_true_im;
result.eps_re_init      = eps_init_re;
result.eps_im_init      = eps_init_im;
result.eps_re_recovery  = eps_re_recovery;
result.eps_im_recovery  = eps_im_recovery;
result.history_F        = history_F;
result.history_eps_re   = history_eps_re;
result.history_eps_im   = history_eps_im;
result.history_g_re     = history_g_re;
result.history_g_im     = history_g_im;
result.fd_sign_rate_re  = fd_sign_rate_re;
result.fd_sign_rate_im  = fd_sign_rate_im;
result.fd_pass_re       = fd_pass_re;
result.fd_pass_im       = fd_pass_im;
result.fd_deltas        = fd_deltas;
result.g_FD_re          = g_FD_re_arr;
result.g_FD_im          = g_FD_im_arr;
result.g_adj_re         = g_adj_re;
result.g_adj_im         = g_adj_im;
% H035 周期性重新标定输出
result.scale_re           = scale_re;
result.scale_im           = scale_im;
result.fd_calib_done      = fd_calib_done;
result.fd_recalib_period  = fd_recalib_period;
result.recalib_count      = recalib_count;
result.history_scale_re       = history_scale_re;
result.history_scale_im       = history_scale_im;
result.history_scale_drift_re = history_scale_drift_re;
result.history_scale_drift_im = history_scale_drift_im;
result.scale_constancy_re = scale_constancy_re;
result.scale_constancy_im = scale_constancy_im;
result.history_data_prior_ratio    = history_data_prior_ratio;
result.history_data_prior_ratio_re = history_data_prior_ratio_re;  % [H036] ε_re 通道数据-先验梯度比值
result.lambda_prior_re = lambda_prior_re;   % [H036] 实部先验权重记录
result.lambda_prior_im = lambda_prior_im;   % [H036] 虚部先验权重记录

save(fullfile(p.dir_result, 'inversion_complex_result.mat'), 'result');
fprintf('\n[H033] 结果已保存: data/results/inversion_complex_result.mat\n');

end

%% ====== 辅助函数 ======
function solve_quiet_c(model, p)
    % 静默求解（用于 FD 扰动正演）
    try
        model.param.set('freq', num2str(p.freq));
        try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
    catch
    end
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end
    try
        s1 = model.sol('sol1').feature('s1');
        try s1.feature('dDirect'); catch
            s1.create('dDirect', 'Direct');
            s1.feature('dDirect').set('linsolver', 'pardiso');
        end
        try s1.feature('fc1').set('linsolver', 'dDirect'); catch, end
    catch
    end
    model.sol('sol1').runAll();
end

function s = ternary_s(cond, a, b)
    if cond, s = a; else, s = b; end
end
