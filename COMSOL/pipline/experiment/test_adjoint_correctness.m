function ratio = test_adjoint_correctness()
%TEST_ADJOINT_CORRECTNESS 伴随算子内积测试（方法1，纯矩阵，不需 COMSOL）
%   返回 ratio（|ratio-1| < 1e-10 为 PASS）
%
%   验证原理：<L(E,H), dJ> == <(E,H), A(dJ)>
%   其中 L = lightcone_project（正向），A = build_adjoint_source_fullmaxwell（伴随）
%
%   如果伴随正确，ratio = LHS/RHS ≈ 1.0（机器精度 ~1e-15）
%   如果 ratio ≠ 1，说明 K_J^T 或 K_M^T 推导有 bug
%
%   不需要 COMSOL Server，纯 MATLAB 矩阵运算，~1 秒完成

fprintf('\n========== 伴随算子内积测试（方法1） ==========\n');

%% 1. 构建测试数据（模拟 config.m 和 build_measurement_grid 的输出）
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
addpath('config', 'utils', 'core_jobs', 'core_jhyp');

fprintf('[TEST] 构建测量网格...\n');
p = config();
grid = build_measurement_grid(p);

N_surface = size(grid.pos, 1);
N_k = p.N_k;

%% 2. 随机生成表面场 E, H（复数）
rng(42);  % 可复现
E_surf = randn(N_surface, 3) + 1i * randn(N_surface, 3);
H_surf = randn(N_surface, 3) + 1i * randn(N_surface, 3);

sf.E_cart = E_surf;
sf.H_cart = H_surf;

%% 3. 随机生成残差 ΔJ（k 空间）
Delta_J = randn(N_k, 3) + 1i * randn(N_k, 3);
J_obs = randn(N_k, 3) + 1i * randn(N_k, 3);  % 用于 F_obs 归一化

%% 4. 正向算子 L: (E, H) → J_forward
fprintf('[TEST] 正向算子 lightcone_project...\n');
lc_fwd = lightcone_project(grid, sf, p);
J_forward = lc_fwd.J_obs_perp;  % [N_k × 3]

%% 5. 伴随算子 A: ΔJ → (Js, Ms)
fprintf('[TEST] 伴随算子 build_adjoint_source_fullmaxwell...\n');
lc_adj = lc_fwd;
lc_adj.Delta_J_perp = Delta_J;
lc_adj.J_obs_perp = J_obs;
[Js, Ms, ~, F_obs] = build_adjoint_source_fullmaxwell(grid, lc_adj, p);

%% 6. 计算内积
% LHS = <L(E,H), ΔJ> = sum( conj(J_forward) .* Delta_J )
% 注意：正向算子用的是真实 J_obs（lc_fwd），不是 Delta_J
% 内积测试：<L(x), y> = <x, A(y)>
% 这里 x = (E, H)，y = ΔJ
% L(x) = lightcone_project(E, H) = J_forward
% A(y) = build_adjoint_source_fullmaxwell(ΔJ) = (Js, Ms)

LHS = sum(conj(J_forward(:)) .* Delta_J(:));

% RHS = <(E,H), A(ΔJ)> = <H, Js> + <E, Ms>
% ★ 修正 2026-07-27：正向核 M_H 作用于 H，M_E 作用于 E
%   共轭转置 M_H^H 作用于 ΔJ → Js（H 变分的伴随）
%   共轭转置 M_E^H 作用于 ΔJ → Ms（E 变分的伴随）
%   因此内积配对是 <H, Js> + <E, Ms>，不是 <E, Js> + <H, Ms>
%   矩阵级测试验证：错误配对 ratio 远离 1，正确配对 ratio=1±1e-15
RHS = sum(conj(H_surf(:)) .* Js(:)) + sum(conj(E_surf(:)) .* Ms(:));

% ★ build_adjoint_source 内含 coeff_base = -0.5i*omega*eps0 标量因子
%   A = coeff_base * L^H，所以 ratio_raw = LHS/RHS = 1/coeff_base
%   补偿后 ratio = ratio_raw * coeff_base 应 = 1（验证 A/L^H = coeff_base 为纯标量）
coeff_base_val = 0.5i * p.omega(1) * p.eps0;  % 与 build_adjoint_source 同步（符号翻转）
ratio_raw = LHS / RHS;
ratio = ratio_raw * coeff_base_val;  % 补偿 coeff_base 因子

fprintf('\n========== 结果 ==========\n');
fprintf('LHS = <L(E,H), dJ>     = %.6e + %.6ei\n', real(LHS), imag(LHS));
fprintf('RHS = <(E,H), (Js,Ms)> = %.6e + %.6ei\n', real(RHS), imag(RHS));
fprintf('ratio_raw = LHS/RHS    = %.6e + %.6ei (应 ≈ 1/coeff_base = %.6e)\n', ...
    real(ratio_raw), imag(ratio_raw), 1/coeff_base_val);
fprintf('coeff_base             = %.6e + %.6ei\n', real(coeff_base_val), imag(coeff_base_val));
fprintf('ratio (补偿后)         = %.15f + %.15fi\n', real(ratio), imag(ratio));
fprintf('|ratio - 1|            = %.2e\n', abs(ratio - 1));

if abs(ratio - 1) < 1e-10
    fprintf('\n★★★ PASS: 伴随算子正确（机器精度内）★★★\n');
else
    fprintf('\n★★★ FAIL: 伴随算子有 bug ★★★\n');
    fprintf('|ratio-1| = %.2e >> 1e-10\n', abs(ratio - 1));

    % 逐层隔离诊断
    fprintf('\n--- 逐层隔离诊断 ---\n');

    % 只测 Js（电流核 K_J^T，对应 H 变分）
    RHS_Js_only = sum(conj(H_surf(:)) .* Js(:));
    ratio_Js = LHS / RHS_Js_only;
    fprintf('仅 Js (配对 <H,Js>):  ratio = %.6e (|ratio-1|=%.2e)\n', ratio_Js, abs(ratio_Js-1));

    % 只测 Ms（磁流核 K_M^T，对应 E 变分）
    RHS_Ms_only = sum(conj(E_surf(:)) .* Ms(:));
    ratio_Ms = LHS / RHS_Ms_only;
    fprintf('仅 Ms (配对 <E,Ms>):  ratio = %.6e (|ratio-1|=%.2e)\n', ratio_Ms, abs(ratio_Ms-1));

    if abs(ratio_Js - 1) < 1e-10
        fprintf('→ Js（电流核 K_J^T）正确，问题在 Ms（磁流核 K_M^T）\n');
    elseif abs(ratio_Ms - 1) < 1e-10
        fprintf('→ Ms（磁流核 K_M^T）正确，问题在 Js（电流核 K_J^T）\n');
    else
        fprintf('→ 两个核都可能有问题\n');
    end
end
fprintf('============================\n\n');

end
