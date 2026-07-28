function [lambda_exact, ok, lambda_gauss, Js, Ms, source_pos, F_obs] = ...
        setup_exact_adjoint_source(model, voxel, grid, lc, p)
%SETUP_EXACT_ADJOINT_SOURCE H027: 精确全 Maxwell 表面双源伴随源构建与求解
%   [lambda_exact, ok] = setup_exact_adjoint_source(model, voxel, grid, lc, p)
%   [lambda_exact, ok, lambda_gauss] = setup_exact_adjoint_source(...)
%   [lambda_exact, ok, lambda_gauss, Js, Ms, source_pos] = setup_exact_adjoint_source(...)
%   [lambda_exact, ok, lambda_gauss, Js, Ms, source_pos, F_obs] = setup_exact_adjoint_source(...)
%
%   ★ H027（Round 22 方向转型核心假设）★
%   基于 Love/Schelkunoff 表面等效定理，在测量球面 (R=0.26m) 上设置
%   SurfaceCurrent (Js0 = n̂ × H_t) + SurfaceMagneticCurrentDensity (Jms0 = −n̂ × E_t)
%   双源精确注入，COMSOL 频域求解精确伴随场 λ_exact，替代旧 Born 近似简化反向投影。
%
%   根因链（H027 核心动机）：
%     H024 AD 三层诊断锁定梯度偏差源 = L2 Born 近似系统性高估 ∂F/∂ε 4-7 数量级（6/6 体素 DEV）
%     → H025 Born 因子修正（−k0²·ΔV_i）改善 ~2.3 数量级但残余 1.7-4.7 数量级仍存
%     → 代码审查发现 build_adjoint_source_fullmaxwell.m 旧版注释自承"忽略表面等效极化投影核"
%     → 根因收窄至伴随源构建环节简化反向投影 → H027 用精确表面双源替代
%
%   实现流程（H027 implementation_scope 四步，本函数为高层语义封装）：
%     (1) 从观测残差 lc.Delta_J_perp 构建伴随激励
%         → build_adjoint_source_fullmaxwell 精确 Stratton-Chu 伴随累加（Js + Ms 双源）
%     (2) 在测量球面 R=0.26m 设置 SurfaceCurrent Js0 + SurfaceMagneticCurrentDensity Jms0 双源
%         → solve_adjoint 双源路径（COMSOL 6.2 EMW physics 原生 features）
%     (3) COMSOL 频域求解器（PARDISO）求解精确伴随场 λ_exact
%         → solve_adjoint model.sol('sol1').runAll() 复用正演 LU 分解
%     (4) mphinterp 提取 λ_exact 代入梯度公式 g_voxel = −k0²·Re(λ_exact·E_fwd)·ΔV
%         → solve_adjoint read_field 提取 voxel 中心 + Gauss 点伴随场
%
%   梯度公式结构（H025）完全不变，唯一变更为 λ 从 Born 反向投影近似 λ_Born
%   升级为精确 Maxwell 伴随场 λ_exact。Born 因子 −k0²·ΔV_i（H025 不变）、
%   链式法则 dε_i/d_r_hole（H023 不变）、SDF 正演 epsilon 映射（H022 不变）全部保留。
%
%   理论依据：表面等效定理（Love/Schelkunoff equivalence theorem）
%     测量球面上的切向场 (E_t, H_t) 等效为：
%       表面电流 Js0 = n̂ × H_t（对应 H 变分，K_J^T 核）
%       表面磁流 Jms0 = −n̂ × E_t（对应 E 变分，K_M^T 核）
%     Born 反向投影仅注入近似 Js0（忽略 Jms0 及表面极化投影核），
%     精确全 Maxwell 伴随需双源 Js0 + Jms0 完整注入重建 λ_exact。
%     转置核向量展开：
%       K_J^T·v = n̂ × (v − k̂(k̂·v))          （电流，对应 H 变分）
%       K_M^T·v = (k̂(n̂·v) − n̂(k̂·v)) / η₀   （磁流，对应 E 变分）
%
%   工程验证（experiment/probe_magnetic_current_v2.m 实测）：
%     - COMSOL 6.2 EMW physics 原生支持 SurfaceCurrent（dim=2）+
%       SurfaceMagneticCurrentDensity（dim=2，Jms0 属性 7 个完整）✓
%     - PARDISO + clearSolutionData 求解通过 ✓
%     - 球心 |E| = 0.36~1.75 非零物理有效 ✓
%
%   高对比度适用性：应用对象西瓜 ε_r ~ 60-80，Born 近似在该量级必然严重失效
%   （Born 近似有效性要求 |ε_r−1| << 1），精确全 Maxwell 伴随是唯一对高对比度
%   强散射体根本有效的路线。
%
%   输入:
%       model   COMSOL 模型对象（须已 mphload + solve_forward，LU 已缓存）
%       voxel   体素结构（含 pos, mask_interior, gauss_pos, gauss_w, dV）
%       grid    测量网格（含 pos [N_surface×3], norm, weight；pos 在测量球面 R=0.26m）
%       lc      LightConeData（须含 Delta_J_perp, J_obs_perp, dOmega, k_dir, k_vec）
%               Delta_J_perp = 归一化残差（(J_obs − J_hyp) ./ J_obs_safe）
%               k_vec = k0 * k_dir（须由调用方设置，如 lc.k_vec = p.k0 * lc.k_dir）
%       p       config（须含 omega, eps0, eta0, k0, mu0, F_obs_min）
%   输出:
%       lambda_exact  [N_inner × 3] complex — 精确伴随场（voxel 中心）
%                     代入梯度公式 g_voxel = −k0²·Re(λ_exact·E_fwd)·ΔV
%       ok            logical — 求解成功标志
%       lambda_gauss  [4×N_inner × 3] complex — Gauss 点精确伴随场（SDF-aware 积分用）
%       Js            [N_surface × 3] complex — 表面电流伴随源（诊断/可视化用）
%       Ms            [N_surface × 3] complex — 表面磁流伴随源（诊断/可视化用）
%       source_pos    [N_surface × 3] — 源位置（= grid.pos，测量球面 R=0.26m）
%       F_obs         scalar — 归一化因子
%
%   依赖（已验证的底层组件，本函数为高层语义封装，不重复实现物理逻辑）:
%       build_adjoint_source_fullmaxwell (core_jhyp/) — 精确 Stratton-Chu 伴随源构建
%       solve_adjoint (core_forward/)    — COMSOL 双源求解 + mphinterp 提取
%
%   See also: build_adjoint_source_fullmaxwell, solve_adjoint, read_field

% ============================================================
%  H027: 精确全 Maxwell 表面双源伴随源构建与求解
%  高层封装 —— 整合残差→双源→COMSOL 求解→mphinterp 提取
%  底层物理逻辑由 build_adjoint_source_fullmaxwell + solve_adjoint 承载
%  本函数仅负责流程编排与语义化接口（H027 implementation_scope 四步）
% ============================================================

fprintf('[setup_exact_adjoint_source] ★H027 精确全 Maxwell 表面双源伴随★\n');
fprintf('  Love/Schelkunoff 表面等效定理 → Js0 + Jms0 双源 → λ_exact\n');
fprintf('  (替代旧 Born 近似简化反向投影，消除 ∂F/∂ε 4-7 数量级系统性偏差)\n');

%% ====== (1) 从观测残差构建精确伴随激励（Stratton-Chu 转置核累加）======
%  build_adjoint_source_fullmaxwell 实现：
%    J_s(s) = Σ_k dΩ_k · K_J^T(k̂,n̂_s) · [ΔJ(k)·e^{+ik₀k̂·r_s}] / F_obs
%    M_s(s) = Σ_k dΩ_k · K_M^T(k̂,n̂_s) · [ΔJ(k)·e^{+ik₀k̂·r_s}] / F_obs
%  标量系数：coeff_base = 0.5i·ω·ε₀（★ H029 迁移：与验证管线一致，无 F_obs 除法）
[Js, Ms, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, p);

fprintf('  (1) 伴随激励构建完成: |Js| mean=%.4e, |Ms| mean=%.4e (N_surface=%d, N_k=%d)\n', ...
    mean(vecnorm(Js, 2, 2)), mean(vecnorm(Ms, 2, 2)), size(source_pos, 1), size(lc.k_dir, 1));

%% ====== (2)+(3)+(4) 测量球面双源注入 + COMSOL 求解 + mphinterp 提取 λ_exact ======
%  solve_adjoint 双源路径（Ms 非空时触发）实现：
%    (2a) 写入 Js 插值函数 int_sc_{x,y,z}_{re,im}（-conj(Js) 约定）
%    (2b) 写入 Ms 插值函数 int_ms_{x,y,z}_{re,im}（-conj(Ms) 约定）
%    (2c) 创建 SurfaceCurrent (sc_adj, dim=2): Js0 = Js/(ωμ₀)
%    (2d) 创建 SurfaceMagneticCurrentDensity (ms_adj, dim=2): Jms0 = Ms
%    (2e) 归零旧 ExternalCurrentDensity (vec1)，设 adjoint_mode=0（零背景场）
%    (3)  model.sol('sol1').runAll() 复用正演 LU 分解（PARDISO）求解 λ_exact
%    (4a) read_field (mphinterp) 提取 voxel 中心 λ_exact
%    (4b) read_field (mphinterp) 提取 Gauss 点 λ_exact（SDF-aware 积分用）
%    (6)  恢复模型（adjoint_mode=1，移除 sc_adj/ms_adj，归零 vec1）
[lambda_exact, ok, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);

if ok
    fprintf('  (2-4) λ_exact 求解+提取成功: %d voxels, |λ_exact| mean=%.4e', ...
        size(lambda_exact, 1), mean(vecnorm(lambda_exact, 2, 2)));
    if ~isempty(lambda_gauss)
        fprintf(' (Gauss %d pts)', size(lambda_gauss, 1));
    end
    fprintf('\n');
else
    fprintf('  [WARN] λ_exact 求解失败（solve_adjoint 返回 ok=false）\n');
end

end
