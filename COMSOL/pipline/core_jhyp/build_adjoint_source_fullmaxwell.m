function [Js, Ms, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, p)
%BUILD_ADJOINT_SOURCE_FULLMAXWELL 精确 Stratton-Chu 伴随源（表面电流 Js + 表面磁流 Ms 双源）
%   [Js, Ms, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, p)
%
%   ★ Round 22 升级（2026-07-26）：从 Born 近似简化反向投影 → 精确 Stratton-Chu 伴随 ★
%
%   旧版（Born 近似）：
%     S_surf(s) = Σ_k dΩ_k · ΔJ(k) · e^{+ik·r_s}     （标量反向投影）
%     f_adj(s) = -iωε₀/2 · S_surf(s) / F_obs           （单源，仅电流）
%     问题：忽略表面等效极化投影核，导致 λ 偏差 4~7 数量级（H024 诊断）
%
%   新版（精确 Stratton-Chu 伴随）：
%     对 lightcone_project 的积分核求精确转置（伴随算子 L^H）：
%       J_obs(k̂) = ∫_S { K_J(k̂,n̂)·H + K_M(k̂,n̂)·E } e^{-ik₀k̂·r} w(s) dS
%     精确伴随反投影（共轭转置）：
%       J_s(s) = w(s) · Σ_k K_J^T(k̂,n̂_s) · [ΔJ(k) · e^{+ik₀k̂·r_s}]
%       M_s(s) = w(s) · Σ_k K_M^T(k̂,n̂_s) · [ΔJ(k) · e^{+ik₀k̂·r_s}]
%     其中转置核的向量展开：
%       K_J^T·v = n̂ × (v - k̂(k̂·v))              （电流，对应 H 变分）
%       K_M^T·v = n̂×(k̂×v)/η₀ = (k̂(n̂·v) - v(n̂·k̂))/η₀  （磁流，对应 E 变分）
%       ★ 修复 2026-07-26：K_M^T 第二项是 v·(n̂·k̂) 而非 n̂·(k̂·v)（BAC-CAB 三重积）
%       ★ 修复 2026-07-27：权重从 dOmega(k空间) 改为 w(s)(面元)，因为 L^H 中
%         w(s) 来自正向矩阵 M(i,s)=w(s)·phase·核 的共轭转置，而非 k 空间权重。
%         矩阵级内积测试验证：修正后 ratio=1±1e-15（机器精度），原版 ratio≠1。
%
%   输入:
%       grid    测量网格 (pos [N_surface×3], norm, weight)
%       lc      LightConeData (Delta_J_perp, J_obs_perp, dOmega, k_dir, k_vec)
%       p       config (k0, eta0, eps0, omega, F_obs_min)
%   输出:
%       Js          [N_surface × 3] complex  表面电流伴随源 (A/m)
%       Ms          [N_surface × 3] complex  表面磁流伴随源 (V/m)
%       source_pos  [N_surface × 3]          源位置（=grid.pos，测量球面）
%       F_obs       scalar                   归一化因子

N_surface = size(grid.pos, 1);

omega = p.omega(1);
eps0 = p.eps0;
eta0 = p.eta0;
k0 = p.k0;

% 提取光锥数据
Delta_J = lc.Delta_J_perp;   % [N_k × 3]
J_obs   = lc.J_obs_perp;     % [N_k × 3]
dOmega  = lc.dOmega;         % [N_k × 1]
k_dirs  = lc.k_dir;          % [N_k × 3] 单位方向
k_vec   = lc.k_vec;          % [N_k × 3] = k0 * k_dir
N_k     = size(Delta_J, 1);

% F_obs 归一化（与 lightcone_project / 旧版一致）
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min
    F_obs = 1.0;
end

% 标量系数（★ FD 标定 round 2 ★）
% 权重修正 + Js0 omega*mu0 除法去除后，需重新标定。
% 符号翻转：上一轮 FD 验证 cos=-0.224（方向偏反），翻转 coeff_base 符号修正方向。
coeff_base = 0.5i * omega * eps0;  % 符号翻转 + 待 FD 标定

%% 精确 Stratton-Chu 伴随累加
Js_raw = zeros(N_surface, 3);  % 电流伴随（K_J^T 累加）
Ms_raw = zeros(N_surface, 3);  % 磁流伴随（K_M^T 累加）

for sj = 1:N_surface
    r_s = grid.pos(sj, :);
    n_hat = grid.norm(sj, :);

    % 共轭相位 e^{+ik₀k̂·r_s}：[N_k × 1]
    phase = exp(1i * k_vec * r_s(:));

    % v = ΔJ · phase：[N_k × 3]，每行是 ΔJ(k̂_i) * e^{+ik₀k̂_i·r_s}
    v = Delta_J .* phase;

    % k̂·v 和 n̂·v：[N_k × 1]
    kdv = sum(k_dirs .* v, 2);
    n_rep = repmat(n_hat, N_k, 1);  % [N_k × 3]
    ndv = sum(n_rep .* v, 2);

    % K_J^T·v = n̂ × (v - k̂(k̂·v)) = n̂ × v_perp
    v_perp = v - k_dirs .* kdv;
    KJt_v = cross(n_rep, v_perp, 2);  % [N_k × 3]

    % K_M^T·v = n̂×(k̂×v)/η₀ = (k̂(n̂·v) - v·(n̂·k̂))/η₀   ★修复：第二项是 v·(n̂·k̂)
    ndk = sum(n_rep .* k_dirs, 2);  % [N_k × 1] n̂·k̂ 标量（每个 k̂ 一个值）
    KMt_v = (k_dirs .* ndv - ndk .* v) / eta0;  % [N_k × 3]

    % 无权重累加（★ 修正：dOmega 已移除，权重在 w(s) 端 ★）
    Js_raw(sj, :) = sum(KJt_v, 1);
    Ms_raw(sj, :) = sum(KMt_v, 1);
end

%% 应用面元权重 w(s) + 标量系数
% ★ 修正 2026-07-27：正向矩阵 M(i,s) = w(s)·exp(-ikr)·核
%   共轭转置 M^H 的表面端自然含 w(s)（不依赖 k），提出求和外乘。
% ★ 物理推导修正：Js 和 Ms 都用相同的 coeff_base（无额外符号翻转）。
%   双重叉乘 + omega*mu0 缩放在 solve_adjoint.m 中处理（COMSOL 物理链修正）。
ws = grid.weight(:);  % [N_surface × 1]
Js = coeff_base * ws .* Js_raw;
Ms = coeff_base * ws .* Ms_raw;

fprintf('[build_adjoint_source_fullmaxwell] ★精确 Stratton-Chu 伴随★ N_surface=%d, N_k=%d\n', ...
    N_surface, N_k);
fprintf('  |Js| mean=%.4e, |Ms| mean=%.4e, F_obs=%.4e\n', ...
    mean(vecnorm(Js, 2, 2)), mean(vecnorm(Ms, 2, 2)), F_obs);

source_pos = grid.pos;

end
