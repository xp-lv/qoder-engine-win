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

    % 设置真值 phantom
    voxel_truth = voxel;
    voxel_truth.epsilon_r = ones(N_v, 1);
    voxel_truth.epsilon_r(inner) = eps_r_true;
    % 空洞区域 ε=1.0
    rho_truth = sqrt(sum((pos_inner - hole_true).^2, 2));
    cavity_truth = rho_truth < R_hole;
    voxel_truth.epsilon_r(inner_idx(cavity_truth)) = 1.0;

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
state.converged = false;
state.iteration = 0;

% 效率优化：连续 reject 早停 + best-state tracking（吸收 H007 实验效率建议）
consecutive_reject = 0;
reject_threshold   = 3;   % 连续 3 轮全 trial reject → 提前终止
best_F             = Inf;  % best-state 残差
best_eps_r         = eps_r_init;
best_hole_pos      = hole_init(:);
best_iter          = 0;
best_J_hyp         = [];   % best-state J_hyp（供三件套评估）

%% ---- CSV 日志 ----
log_path = fullfile(p.dir_result_C01, 'C01_cavity_log.csv');
log_fid = fopen(log_path, 'w');
fprintf(log_fid, 'iter,F_cheb,cos_theta,eps_r,hx,hy,hz,g_eps,g_pos_norm,hole_err,mu_eps,mu_hole,accepted,time_s,g_FD_x,g_pos_analytical_x\n');
fclose(log_fid);

%% ================ 主循环 ================
for iter = 1:p.max_iter
    tic;
    fprintf('\n--- C01_cavity iter %d/%d ---\n', iter, p.max_iter);

    %% 1. 从参数构造 voxel epsilon_r
    rho_v = sqrt(sum((pos_inner - hole_pos.').^2, 2));   % [N_inner × 1]
    mask_cavity = rho_v < R_hole;
    mask_body   = ~mask_cavity;

    voxel.epsilon_r = ones(N_v, 1);
    voxel.epsilon_r(inner) = eps_r_body;
    voxel.epsilon_r(inner_idx(mask_cavity)) = 1.0;

    N_cavity = sum(mask_cavity);
    N_body = sum(mask_body);
    fprintf('  [iter %d] body voxels=%d, cavity voxels=%d, eps_r=%.4f, hole=[%.4f,%.4f,%.4f]\n', ...
        iter, N_body, N_cavity, eps_r_body, hole_pos(1), hole_pos(2), hole_pos(3));

    %% 2. 多频率正演 + 残差 + 伴随梯度
    g_voxel = zeros(N_v, 1);          % 实数梯度（∂F/∂Re(ε)）
    F_k_total = zeros(N_k, 1);
    cos_theta_sum = 0;
    J_hyp_primary = [];
    F_k_per_freq = zeros(N_freq, 1);

    use_gauss = ~isempty(voxel.gauss_pos) && size(voxel.gauss_pos, 1) == 4 * N_inner;
    gauss_w = voxel.gauss_w;

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

        %% 伴随求解
        fprintf('  [iter %d freq=%d] adjoint...\n', iter, fi);
        lc.k_vec = p.k0 * lc.k_dir;
        lc.J_obs_perp = J_obs_fi;
        lc.Delta_J_perp = Delta_J ./ J_obs_safe;
        [f_adj, source_pos] = build_adjoint_source_fullmaxwell(grid, lc, p);
        [lambda_fi, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos);

        if ~adj_ok
            fprintf('  [iter %d freq=%d] [WARN] adjoint failed, skip\n', iter, fi);
            continue;
        end

        %% 体素梯度 g_voxel = Re[-k0²·dV·(E·λ)] / N_freq
        k0_sq = p.k0^2;
        dV_vec = voxel.dV;

        if use_gauss && ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
                && size(E_gauss, 1) == size(voxel.gauss_pos, 1)
            for vi = 1:N_inner
                v_idx = inner_idx(vi);
                gp = (4*(vi-1)+1):(4*vi);
                gs = 0;
                for gpi = 1:4
                    gs = gs + gauss_w(gpi) * dot(E_gauss(gp(gpi),:), lambda_gauss(gp(gpi),:));
                end
                g_voxel(v_idx) = g_voxel(v_idx) - k0_sq * dV_vec(v_idx) * real(gs) / N_freq;
            end
        else
            E_vox = zeros(N_inner, 3);
            E_vox(:, :) = E_total;
            L_vox = zeros(N_inner, 3);
            L_vox(:, :) = lambda_fi;
            for vi = 1:N_inner
                v_idx = inner_idx(vi);
                g_voxel(v_idx) = g_voxel(v_idx) - k0_sq * dV_vec(v_idx) * real(dot(E_vox(vi,:), L_vox(vi,:))) / N_freq;
            end
        end

        fprintf('  [iter %d freq=%d] |g_voxel| mean=%.4e max=%.4e\n', ...
            iter, fi, mean(abs(g_voxel(inner_idx))), max(abs(g_voxel(inner_idx))));
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

    %% 4. 参数梯度计算
    % (a) 材料梯度：∂F/∂eps_r = Σ_{body\cavity} g_voxel(v)
    body_voxel_idx = inner_idx(mask_body);
    g_eps = sum(g_voxel(body_voxel_idx));

    % (b) 位置梯度：shape derivative 边界面积分
    %   H014 符号审计与修正：
    %   g_voxel 编码 -∂F/∂ε（下降方向，与 g_eps 收敛正确一致），因此位置梯度也必须
    %   编码下降方向 -∂F/∂p，才能与更新公式 hole += mu·dir_pos（dir_pos=g_pos/|g_pos|）配合。
    %   物理推导：当 hole 沿 +x 移动 δ，+x 侧边界体素从 body→cavity，Δε=-jump_eps；
    %   离散化 ∂ε_v/∂p_x = -jump_eps·n_x/dr（n 为外法向，从 hole 指向边界）。
    %   ∂F/∂p_x = Σ(∂F/∂ε_v)·(∂ε_v/∂p_x) = Σ(-g_voxel)·(-jump_eps·n_x/dr)
    %           = +jump_eps/dr·Σ g_voxel·n_x  ← 梯度本身（上升方向）
    %   下降方向 -∂F/∂p = -jump_eps/dr·Σ g_voxel·n_x  ← H014 修正：取负号
    %   H013 原始公式无负号 → g_pos 实为 +∂F/∂p（上升方向），导致 hole 沿错误方向移动
    %   （y/z 分量与真值反向），H014 通过有限差分审计确认并修正。
    boundary_mask = abs(rho_v - R_hole) < dr;
    N_boundary = sum(boundary_mask);

    g_pos_raw_formula = zeros(3, 1);   % H014: 原始公式值（+∂F/∂p，上升方向），供 FD 审计对比

    if N_boundary > 0
        pos_bnd = pos_inner(boundary_mask, :);
        rho_bnd = rho_v(boundary_mask);
        rho_bnd_safe = max(rho_bnd, 1e-10);
        n_xyz = (pos_bnd - hole_pos.')./ rho_bnd_safe;    % [N_bnd × 3] 外法向
        g_bnd = g_voxel(inner_idx(boundary_mask));          % [N_bnd × 1]
        jump_eps = eps_r_body - 1.0;
        % H013 原始公式（梯度本身 +∂F/∂p，上升方向）——保留供 FD 审计对比
        g_pos_raw_formula = jump_eps * (1/dr) * sum(g_bnd .* n_xyz, 1).';
        % H014 修正：取负号，使其编码下降方向 -∂F/∂p（与 g_eps 约定一致）
        g_pos = -g_pos_raw_formula;
    else
        g_pos = zeros(3, 1);
    end

    %% ================ H015: 混合位置梯度策略 — x 分量中心有限差分 ================
    % y/z 分量保留上方解析 shape derivative 梯度（H014 FD-check 已验证方向正确）。
    % x 分量替换为中心有限差分梯度（δ_x=0.005m），克服 voxel 级几何方案下
    % 解析边界积分在 x 方向的伪信号（H014 揭示 g_FD_x≈0 而 g_analytical_x=9.83e6）。
    % 公式：g_FD_x = [F(x+δ_x) − F(x−δ_x)] / (2·δ_x) ← ∂F/∂p_x（上升方向）
    % 替换：g_pos(1) := -g_FD_x（下降方向，与 g_pos 编码 -∂F/∂p 约定一致）
    g_pos_analytical_x = g_pos(1);     % 保留解析值供对比诊断
    g_FD_x = NaN;  fd_x_ok = false;    % 默认 NaN（disabled / failed 时保留）
    delta_x_used = NaN;                % Round11 P-01: 实际生效的 δ_x（NaN if disabled）
    fd_x_resolved = false;             % Round11 P-01: 是否获得 |g_FD_x| ≥ 阈值的有效梯度

    if isfield(p, 'cavity_hybrid_fd_x') && p.cavity_hybrid_fd_x
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
                rho_eval = sqrt(sum((pos_inner - hole_eval.').^2, 2));
                mask_cav_eval = rho_eval < R_hole;
                voxel_eval = voxel;
                voxel_eval.epsilon_r = ones(N_v, 1);
                voxel_eval.epsilon_r(inner) = eps_r_body;
                voxel_eval.epsilon_r(inner_idx(mask_cav_eval)) = 1.0;

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
                rho_eval = sqrt(sum((pos_inner - hole_eval.').^2, 2));
                mask_cav_eval = rho_eval < R_hole;
                voxel_eval = voxel;
                voxel_eval.epsilon_r = ones(N_v, 1);
                voxel_eval.epsilon_r(inner) = eps_r_body;
                voxel_eval.epsilon_r(inner_idx(mask_cav_eval)) = 1.0;

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

    hole_err = norm(hole_pos - hole_true.');
    fprintf('  [iter %d] AGG: F=%.4e cos=%.3f eps=%.3f hole_err=%.4fm g_eps=%.3e |g_pos|=%.3e N_bnd=%d t=%.1fs\n', ...
        iter, F_cheb, mean_cos, eps_r_body, hole_err, g_eps, g_pos_norm_val, N_boundary, toc);

    % CSV 日志
    log_fid = fopen(log_path, 'a');
    fprintf(log_fid, '%d,%.6e,%.6f,%.4f,%.4f,%.4f,%.4f,%.6e,%.6e,%.4f,%.4f,%.5f,%d,%.1f,%.6e,%.6e\n', ...
        iter, F_cheb, mean_cos, eps_r_body, hole_pos(1), hole_pos(2), hole_pos(3), ...
        g_eps, g_pos_norm_val, hole_err, mu_eps, mu_hole, 0, toc, g_FD_x, g_pos_analytical_x);
    fclose(log_fid);

    % 收敛检查
    if F_cheb < p.eps_tol && iter >= 3
        fprintf('  [iter %d] Converged: F=%.4e < %.4e\n', iter, F_cheb, p.eps_tol);
        state.converged = true;
        state.iteration = iter;
        update_log_accepted(log_path, iter);
        break;
    end

    %% 5. 分别归一化 + 线搜索
    % 材料：归一化为 ±1 方向
    if abs(g_eps) > 1e-30
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
    mu_eps_try = mu_eps;
    mu_hole_try = mu_hole;

    for trial = 1:mu_max_trials
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

        % 构造试探 voxel
        rho_try = sqrt(sum((pos_inner - hole_try.').^2, 2));
        mask_cav_try = rho_try < R_hole;

        voxel_try = voxel;
        voxel_try.epsilon_r = ones(N_v, 1);
        voxel_try.epsilon_r(inner) = eps_r_try;
        voxel_try.epsilon_r(inner_idx(mask_cav_try)) = 1.0;

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

        fprintf('    [LS trial=%d] F_try=%.4e (old=%.4e) dF=%.4e', trial, F_try, F_cheb, F_try - F_cheb);

        if F_try < F_cheb
            fprintf('  ACCEPT\n');
            eps_r_body = eps_r_try;
            hole_pos = hole_try;
            accepted = true;
            break;
        else
            fprintf('  reject\n');
            mu_eps_try = mu_eps_try * mu_decay;
            mu_hole_try = mu_hole_try * mu_decay;
        end
    end

    if accepted
        mu_eps = min(mu_eps_try * 1.3, p.mu_max);
        mu_hole = min(mu_hole_try * 1.3, 0.02);
        update_log_accepted(log_path, iter);
    else
        fprintf('  [iter %d] all trials rejected, keep params\n', iter);
    end

    state.history_accepted(iter) = accepted;

    % best-state tracking 已移至 §3.5（F_cheb 计算后、收敛检查前）——管线维护 Round10 修复

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

%% ---- 最终重建（使用 best-state 参数） ----
eps_r_body = best_eps_r;
hole_pos   = best_hole_pos;

rho_final = sqrt(sum((pos_inner - hole_pos.').^2, 2));
mask_cav_final = rho_final < R_hole;
voxel.epsilon_r = ones(N_v, 1);
voxel.epsilon_r(inner) = eps_r_body;
voxel.epsilon_r(inner_idx(mask_cav_final)) = 1.0;

state.epsilon_r = voxel.epsilon_r;
state.eps_r_body = eps_r_body;
state.hole_pos = hole_pos;
state.hole_pos_true = hole_true;
state.best_F_cheb = best_F;
state.best_iter = best_iter;
state.hole_position_error = norm(hole_pos - hole_true.');
state.N_cavity_voxels = sum(mask_cav_final);
state.N_boundary_voxels = sum(abs(rho_final - R_hole) < dr);
state.J_obs_truth = J_obs_multi{1};   % 主频 J_obs（供 run_experiment 三件套使用）
state.freqs = freqs;
state.N_freq = N_freq;
state.algorithm = 'C01_cavity_body_eccentric';
state.mu_eps_final = mu_eps;
state.mu_hole_final = mu_hole;
state.residual = best_F;             % 供 run_experiment 三件套输出
state.history_J_hyp = best_J_hyp;    % 输出 best-state J_hyp（非 final）

%% ---- H015: 混合梯度策略状态 ----
state.hybrid_fd.enabled = isfield(p, 'cavity_hybrid_fd_x') && p.cavity_hybrid_fd_x;
state.hybrid_fd.delta_x_primary = p.cavity_fd_delta_x;          % Round11 P-01: 原始 δ_x
if isfield(p, 'cavity_fd_delta_x_fallback')
    state.hybrid_fd.delta_x_fallback = p.cavity_fd_delta_x_fallback;  % Round11 P-01: fallback 升级 δ_x
end
state.hybrid_fd.delta_x_used = delta_x_used;                    % Round11 P-01: 实际生效的 δ_x（NaN if disabled）
state.hybrid_fd.fallback_triggered = fd_x_ok && delta_x_used > p.cavity_fd_delta_x;  % 是否触发了 δ_x 升级
state.hybrid_fd.fd_resolved = fd_x_resolved;                    % Round11 P-01: 是否获得 |g_FD_x| ≥ 阈值的有效梯度
state.hybrid_fd.g_FD_x_final = g_FD_x;                          % 最后一轮 g_FD_x（NaN if disabled）
state.hybrid_fd.g_pos_analytical_x_final = g_pos_analytical_x;  % 最后一轮解析 x 梯度（对比）

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
