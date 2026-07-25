function [voxel, mu_next, accepted] = linesearch(voxel, E_total, g, lc, p, model)
%LINESEARCH Armijo 回溯线搜索 + ε_r 更新
%   [voxel, mu_next, accepted] = linesearch(voxel, E_total, g, lc, p, model)
%
%   流程:
%     1. RMS 归一化梯度
%     2. 在当前步长 μ 下试探更新 ε_r
%     3. 重跑正演，计算试探代价 F_try
%     4. Armijo 条件: F_try ≤ F_old - c·μ·||g||²
%     5. 满足则接受，否则衰减步长重试
%
%   输入:
%       voxel   当前体素网格（epsilon_r 旧值）
%       E_total 当前正演全场
%       g       [N_v × 1] 梯度
%       lc      LightConeData（含 J_obs）
%       p       config（线搜索参数）
%       model   COMSOL 模型（用于试探正演）
%   输出:
%       voxel   更新后的体素网格（epsilon_r 新值）
%       mu_next 下一轮迭代建议步长
%       accepted 是否找到可接受步长

inner = voxel.mask_interior;
eps_old = voxel.epsilon_r;

%% 自适应步长：根据 ε_r 分布的 σ 调整
eps_std = std(real(eps_old(inner)));
if eps_std > 0.3
    % 分布已破裂，使用更小的步长
    mu = p.mu_init * 0.5;
    fprintf('  [LS] ε_r σ=%.3f > 0.3，步长缩小至 μ=%.4f\n', eps_std, mu);
else
    mu = p.mu_init;
end

%% 梯度归一化（RMS = 1）
g_norm_sq = sum(g(inner).^2);  % 保存归一化前的 ||g||^2
N_inner = sum(inner);
g_rms = sqrt(mean(g(inner).^2));
if g_rms > 0
    g = g / g_rms;
end
% 轻量裁剪
g(inner) = max(-p.grad_clip, min(p.grad_clip, g(inner)));

%% 旧代价
F_old = compute_cost_fast(model, voxel, E_total, lc, p);

%% 调试信息
fprintf('  [LS DIAG] g_rms=%.3e, ||g||²=%d, N_inner=%d, Armijo coeff=%.1e\n', ...
    g_rms, g_norm_sq, N_inner, p.ls_armijo);
fprintf('  [LS DIAG] F_old=%.4e, 期望下降量=%.4e (μ×||g||²×c)\n', ...
    F_old, p.mu_init * g_norm_sq * p.ls_armijo);

%% Armijo 回溯
accepted = false;

for trial = 1:p.ls_max_trials
    % 试探更新
    eps_try = eps_old;
    eps_try(inner) = eps_old(inner) - mu * g(inner);
    
    % 物理约束
    eps_re = real(eps_try);
    eps_re = max(p.eps_r_min, min(p.eps_r_max, eps_re));
    eps_im = imag(eps_try);
    eps_im = max(-p.eps_r_imag_max, min(0, eps_im));
    eps_try = eps_re - 1i * eps_im;
    eps_try(~inner) = 1;
    
    % 试探正演
    voxel_try = voxel;
    voxel_try.epsilon_r = eps_try;
    
    if ~isempty(model)
        [E_try, ~] = solve_forward(model, voxel_try, p);
    else
        fprintf('  [LS] COMSOL 不可用，接受试探步\n');
        E_try = E_total;  % 用旧场近似
    end
    
    if isempty(E_try)
        fprintf('  [LS] 试探正演失败，跳过\n');
        mu = mu * p.ls_decay;
        continue;
    end
    
    F_try = compute_cost_fast(model, voxel_try, E_try, lc, p);
    
    % Armijo: F(x + mud) <= F(x) + c*mu*(-||g||^2)  (d = -g)
    % 使用归一化前的 g_norm_sq，避免 RMS 归一化放大期望下降量
    armijo_rhs = F_old - p.ls_armijo * mu * g_norm_sq;
    
    fprintf('  [LS trial=%d] μ=%.6f, F_old=%.4e, F_try=%.4e, Armijo=%.4e', ...
        trial, mu, F_old, F_try, armijo_rhs);
    
    if F_try <= armijo_rhs
        fprintf('  accept\n');
        voxel.epsilon_r = eps_try;
        accepted = true;
        break;
    else
        fprintf('  reject\n');
        mu = mu * p.ls_decay;
    end
end

if ~accepted
    mu = p.mu_init * p.ls_decay^p.ls_max_trials;
    fprintf('  [LS] 全部 %d 次尝试失败，保持原值\n', p.ls_max_trials);
end

% 调整下轮初始步长
if accepted
    mu_next = min(mu * 2, p.mu_max);
else
    mu_next = max(p.mu_init * 0.5, p.mu_min);
end

end

%% ---- 快速代价计算（不更新 lc 结构体；H001: COMSOL 全波 J_hyp）----
function F = compute_cost_fast(model, voxel, E_total, lc, p)
    % H001: 默认走 COMSOL 全波 J_hyp（替代 Born equivalent_source + lightcone_hyp）
    % model 须已由调用方 solve_forward 完成对应 eps_r 的求解。
    if isempty(model)
        % COMSOL 不可用降级：保留 Born 质心路径以维持可计算性（仅空 model 触发）
        J_equi = equivalent_source(voxel, E_total, p);
        J_hyp = lightcone_hyp(voxel, J_equi, lc, p);
    else
        J_hyp = compute_jhyp_comsol(model, lc, p);
    end
    Delta_J = lc.J_obs_perp - J_hyp;
    
    F_obs = sum(lc.dOmega .* sum(abs(lc.J_obs_perp).^2, 2));
    if F_obs < p.F_obs_min, F_obs = 1.0; end
    
    F = sum(lc.dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs;
end
