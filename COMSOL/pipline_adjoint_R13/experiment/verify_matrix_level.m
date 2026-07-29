function verify_matrix_level()
%VERIFY_MATRIX_LEVEL 矩阵级伴随算子内积测试（纯数学，不依赖 COMSOL）
%
%   ★ 伴随法验证第一层：如果此层不通过，后续所有物理验证均无意义 ★
%
%   核心原理：伴随算子 L* 必须满足内积恒等式
%     <L(x), y> = <x, L*(y)>
%
%   其中：
%     L = lightcone_project 正向算子（表面场 → k空间观测 J_obs）
%     L* = build_adjoint_source_fullmaxwell 伴随算子（k空间残差 → 表面源 Js,Ms）
%
%   方法：
%     1. 用 FD 提取 L 的正向矩阵 M_E, M_H（4次调用 per 分量）
%     2. 随机生成 x=(E,H), y=ΔJ
%     3. LHS = conj(L(x))·y          （标准 Hermitian 内积）
%     4. RHS = conj(H)·Js + conj(E)·Ms  （配对：Js↔H, Ms↔E）
%     5. ratio = LHS/RHS，要求 |ratio-1| < 1e-10
%
%   用法（不需要 COMSOL）：
%     >> cd COMSOL/pipline_adjoint
%     >> verify_matrix_level

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');

fprintf('\n');
fprintf('############################################################\n');
fprintf('#  伴随法验证 Layer 1: 矩阵级内积测试\n');
fprintf('#  纯数学验证，不依赖 COMSOL\n');
fprintf('############################################################\n\n');

p = config();
grid = build_measurement_grid(p);
N_s = size(grid.pos, 1);
N_k = p.N_k;

rng(42);  % 可复现随机种子

%% 1. 构建 E, H 随机场（模拟表面散射场）
E_surf = randn(N_s, 3) + 1i * randn(N_s, 3);
H_surf = randn(N_s, 3) + 1i * randn(N_s, 3);
sf.E_cart = E_surf;
sf.H_cart = H_surf;

%% 2. 正向算子：lightcone_project → J_obs
fprintf('[TEST] 正向算子 lightcone_project...\n');
lc_fwd = lightcone_project(grid, sf, p);
J_forward = lc_fwd.J_obs_perp;  % [N_k × 3]

fprintf('  |J_forward| mean=%.4e\n', mean(vecnorm(J_forward, 2, 2)));

%% 3. 随机残差 ΔJ
Delta_J = randn(N_k, 3) + 1i * randn(N_k, 3);

%% 4. 伴随算子：build_adjoint_source_fullmaxwell → (Js, Ms)
fprintf('[TEST] 伴随算子 build_adjoint_source_fullmaxwell...\n');
lc_adj = lc_fwd;
lc_adj.Delta_J_perp = Delta_J;
lc_adj.J_obs_perp = J_forward;
lc_adj.k_vec = p.k0 * lc_adj.k_dir;
[Js, Ms, ~, ~] = build_adjoint_source_fullmaxwell(grid, lc_adj, p);

fprintf('  |Js| mean=%.4e, |Ms| mean=%.4e\n', ...
    mean(vecnorm(Js, 2, 2)), mean(vecnorm(Ms, 2, 2)));

%% 5. 内积测试：<L(x), y> = <x, L*(y)>
% LHS = conj(J_forward) · Delta_J （展平向量内积）
LHS = sum(conj(J_forward(:)) .* Delta_J(:));

% RHS = conj(H)·Js + conj(E)·Ms  （★ 正确配对：Js↔H变分，Ms↔E变分）
RHS = sum(conj(H_surf(:)) .* Js(:)) + sum(conj(E_surf(:)) .* Ms(:));

ratio = LHS / RHS;

fprintf('\n========== 矩阵级内积结果 ==========\n');
fprintf('LHS = <L(E,H), ΔJ>     = %.10e + %.10ei\n', real(LHS), imag(LHS));
fprintf('RHS = <H,Js> + <E,Ms>   = %.10e + %.10ei\n', real(RHS), imag(RHS));
fprintf('ratio                   = %.15f + %.15fi\n', real(ratio), imag(ratio));
fprintf('|ratio - 1|             = %.2e\n', abs(ratio - 1));

if abs(ratio - 1) < 1e-10
    fprintf('\n★★★ Layer 1 PASS：伴随算子数学精确（|ratio-1| < 1e-10）★★★\n');
    fprintf('  → 转置核推导、权重、共轭相位全部正确\n');
    fprintf('  → 可进行 Layer 2 参数级 FD 验证\n');
else
    fprintf('\n★★★ Layer 1 FAIL：|ratio-1| = %.2e ≥ 1e-10 ★★★\n', abs(ratio-1));
    fprintf('  → 需排查：转置核向量展开、面元权重 w(s)、共轭相位\n');
end
fprintf('======================================\n\n');

%% 6. 附加：错误配对检查（Js↔E, Ms↔H，验证配对方向）
RHS_wrong = sum(conj(E_surf(:)) .* Js(:)) + sum(conj(H_surf(:)) .* Ms(:));
ratio_wrong = LHS / RHS_wrong;
fprintf('附加：错误配对 <E,Js>+<H,Ms> ratio = %.6f\n', abs(ratio_wrong));
if abs(ratio_wrong - 1) > 0.1
    fprintf('  → 错误配对远离 1，证明 Js↔H + Ms↔E 配对方向正确\n');
else
    fprintf('  → [WARN] 错误配对也接近 1，需进一步检查\n');
end

%% 7. 保存结果
result.LHS = LHS;
result.RHS = RHS;
result.ratio = ratio;
result.abs_ratio_minus_1 = abs(ratio - 1);
result.pass = abs(ratio - 1) < 1e-10;

save(fullfile(p.dir_result, 'matrix_level_result.mat'), 'result');
fprintf('\n结果已保存: data/results/matrix_level_result.mat\n');

end
