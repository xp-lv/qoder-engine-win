function [voxel, mu_next, accepted, F_try] = linesearch_adj(voxel, g, p, model, grid, J_obs, lc_obs, mu_init, F_old)
%
%   [voxel, mu_next, accepted, F_try] = linesearch_adj(...)
%
%   适配管线2特点：
%     - J_hyp 直接用 lightcone_project（无 Born 近似）
%     - 代价函数 F = 定义 A（compute_cost.m 标准）
%     - 梯度已归一化方向，步长 mu 直接控制 eps_r 变化幅度

% g 是 [N_inner × 1] 梯度（仅内部体素）
inner = voxel.mask_interior;
inner_idx = find(inner);
eps_old_inner = voxel.epsilon_r(inner);  % 仅内部体素

% 步长初始化
mu = mu_init;

% 梯度归一化（RMS = 1）
g_rms = sqrt(mean(g.^2));
if g_rms > 0
    g_normed = g / g_rms;
else
    g_normed = g;
end

% 保存归一化前的 ||g||^2（Armijo 条件用）
g_norm_sq = sum(g.^2);

%% F_old 由调用方传入（避免模型状态不一致）
dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min, F_obs = 1.0; end

%% Armijo 回溯
accepted = false;
F_try = F_old;
c_armijo = 0.01;  % Armijo 充分下降常数
ls_decay = 0.5;   % 步长衰减因子
ls_max_trials = 8;

fprintf('  [LS] F_old=%.6e, ||g||²=%.4e, mu_init=%.4f\n', F_old, g_norm_sq, mu);

for trial = 1:ls_max_trials
    % 试探更新
    eps_try_inner = eps_old_inner - mu * g_normed;
    
    % 物理约束
    eps_try_inner_clamped = max(1.0, min(50.0, eps_try_inner));  % eps_r ∈ [1, 50]
    
    % 写回完整 voxel
    eps_try_full = voxel.epsilon_r;
    eps_try_full(inner) = eps_try_inner_clamped;
    
    % 试探正演
    voxel_try = voxel;
    voxel_try.epsilon_r = eps_try_full;
    
    update_epsilon(model, voxel_try, p);
    
    % ★ 确保正演模式：恢复背景场 + adjoint_mode=1
    try model.physics('emw').prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    try model.param.set('adjoint_mode', '1'); catch, end
    try model.physics('emw').feature('vec1').set('Je', {'0','0','0'}); catch, end
    
    % 清解 + 求解
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end
    model.sol('sol1').runAll();
    
    % 计算试探代价
    sf_try = extract_scattered(model, grid);
    lc_try = lightcone_project(grid, sf_try, p);
    Delta_J_try = J_obs - lc_try.J_obs_perp;
    F_try = sum(dOmega .* sum(abs(Delta_J_try).^2, 2)) / F_obs;
    
    % Armijo 条件
    armijo_rhs = F_old - c_armijo * mu * g_norm_sq;
    
    fprintf('  [LS trial=%d] mu=%.6f, F_try=%.6e, Armijo=%.6e', trial, mu, F_try, armijo_rhs);
    
    if F_try <= armijo_rhs
        fprintf('  ACCEPT\n');
        voxel.epsilon_r(inner) = eps_try_inner_clamped;
        accepted = true;
        break;
    else
        fprintf('  reject\n');
        mu = mu * ls_decay;
    end
end

if ~accepted
    fprintf('  [LS] 全部 %d 次尝试失败，保持原值\n', ls_max_trials);
    F_try = F_old;
    mu_next = mu_init * 0.5;
else
    mu_next = min(mu * 1.5, 5.0);  % 下轮步长略增
end

end
