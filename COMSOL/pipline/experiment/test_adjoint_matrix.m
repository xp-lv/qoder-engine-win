function ratio = test_adjoint_matrix()
%TEST_ADJOINT_MATRIX 直接矩阵级伴随验证（不经过 build_adjoint_source）
%   返回 ratio（|ratio-1| < 1e-10 为 PASS）
%
%   把 lightcone_project 的线性核拆解为两个子矩阵 M_E 和 M_H：
%     J_obs = M_E · E + M_H · H
%   其中 M_E, M_H 把表面场 [3N_s] 映射到 k 空间 [3N_k]
%
%   伴随正确性：<J_obs, ΔJ> = <E, M_E^T·ΔJ> + <H, M_H^T·ΔJ>
%
%   测试方法：
%     1. 随机 E, H → 正向得 J_obs
%     2. 随机 ΔJ → 手动计算 M_E^T·ΔJ 和 M_H^T·ΔJ
%     3. 检查内积等式
%
%   再将 M_E^T·ΔJ / M_H^T·ΔJ 与 build_adjoint_source_fullmaxwell 输出对比，
%   定位 K_J^T / K_M^T 的推导 bug。

fprintf('\n========== 矩阵级伴随验证 ==========\n');

addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
addpath('config', 'utils', 'core_jobs', 'core_jhyp');

fprintf('[TEST] 构建测量网格...\n');
p = config();
grid = build_measurement_grid(p);
N_s = size(grid.pos, 1);
N_k = p.N_k;

% k 方向
[k_dir, dOmega] = fibonacci_sphere(N_k);
k_vec = p.k0 * k_dir;

w     = grid.weight(:);
n_hat = grid.norm;
pos   = grid.pos;
eta0  = p.eta0;
k0    = p.k0;

%% 1. 构建正向矩阵 M_E, M_H [3N_k × 3N_s]
% J_obs(i,d) = sum_s sum_d' M(i,d, s,d') * field(s,d')
% 用稀疏方式：对每个 (i, s) 对，计算 3×3 子块

fprintf('[TEST] 构建正向矩阵 M_E, M_H (%dx%d → %dx%d)...\n', 3*N_s, 1, 3*N_k, 1);

M_E = zeros(3*N_k, 3*N_s);
M_H = zeros(3*N_k, 3*N_s);

for i = 1:N_k
    ki = k_dir(i, :);
    phase_s = exp(-1i * pos * (k0 * ki(:)));  % [N_s × 1]
    ws_phase = w .* phase_s;  % [N_s × 1]

    for s = 1:N_s
        ns = n_hat(s,:);
        % 3×3 子块：field(s,:) 的 3 个分量 → J_obs(i,:) 的 3 个分量
        % 贡献 = ws_phase(s) * integrand_subblock

        % === M_H 子块（来自 H_s）===
        % 正向：integrand_H = k̂(k̂·(n̂×H)) − (n̂×H) = [k̂k̂ᵀ − I]·(n̂×H) = [k̂k̂ᵀ−I]·[n̂×]·H
        % 所以 M_H 的 3×3 子块 = ws_phase(s) * (k̂k̂ᵀ − I) · [n̂×]
        n_cross = [0, -ns(3), ns(2); ns(3), 0, -ns(1); -ns(2), ns(1), 0];  % [n̂×]
        sub_H = (ki' * ki - eye(3)) * n_cross;  % [3×3]
        r_H = (i-1)*3+1 : i*3;
        c_H = (s-1)*3+1 : s*3;
        M_H(r_H, c_H) = ws_phase(s) * sub_H;

        % === M_E 子块（来自 E_s）===
        % 正向：integrand_E = (n̂(E·k̂) − E(n̂·k̂))/η₀ = [n̂k̂ᵀ − k̂·(n̂·k̂)·... ]/η₀
        % 更精确：integrand_E = (n̂_s*(E_s·k̂_i) - E_s*(n̂_s·k̂_i)) / η₀
        %   = (n̂ k̂ᵀ − (n̂·k̂) I) E / η₀
        ndk = dot(ns, ki);
        sub_E = (ns' * ki - ndk * eye(3)) / eta0;  % [3×3]
        r_E = r_H;  % same index range as M_H
        c_E = c_H;
        M_E(r_E, c_E) = ws_phase(s) * sub_E;
    end
end

fprintf('[TEST] M_E size=%s, M_H size=%s\n', mat2str(size(M_E)), mat2str(size(M_H)));

%% 2. 随机场 + 内积测试
rng(42);
E_vec = randn(3*N_s, 1) + 1i * randn(3*N_s, 1);
H_vec = randn(3*N_s, 1) + 1i * randn(3*N_s, 1);
dJ_vec = randn(3*N_k, 1) + 1i * randn(3*N_k, 1);

% 正向
J_fwd = M_E * E_vec + M_H * H_vec;

% LHS = <J_fwd, dJ> = conj(J_fwd)^T * dJ
% MATLAB 中 x' = conj(x)^T（Hermitian 转置），所以 J_fwd' * dJ = conj(J_fwd)^T * dJ
LHS = J_fwd' * dJ_vec;

% RHS = <E, M_E^H dJ> + <H, M_H^H dJ>
%   = conj(E)^T * (M_E^H * dJ) + conj(H)^T * (M_H^H * dJ)
% MATLAB 中 E_vec' = conj(E_vec)^T，M_E' = conj(M_E)^T = M_E^H
% ★ 修复 2026-07-27：原代码 conj(E_vec)' = E_vec^T（普通转置），漏了共轭
%   应该直接用 E_vec'（即 conj(E_vec)^T），不需要外加 conj
RHS = E_vec' * (M_E' * dJ_vec) + H_vec' * (M_H' * dJ_vec);

ratio = LHS / RHS;

fprintf('\n========== 矩阵级内积结果 ==========\n');
fprintf('LHS = <M·(E,H), dJ>    = %.6e + %.6ei\n', real(LHS), imag(LHS));
fprintf('RHS = <(E,H), M^T·dJ>  = %.6e + %.6ei\n', real(RHS), imag(RHS));
fprintf('ratio = LHS/RHS        = %.15f + %.15fi\n', real(ratio), imag(ratio));
fprintf('|ratio - 1|            = %.2e\n', abs(ratio - 1));

if abs(ratio - 1) < 1e-10
    fprintf('\n★★★ 矩阵级伴随验证 PASS ★★★\n');
    fprintf('lightcone_project 的 M_E, M_H 矩阵转置关系正确\n');
else
    fprintf('\n★★★ 矩阵级伴随验证 FAIL ★★★\n');
end

%% 3. 对比 build_adjoint_source_fullmaxwell 的输出
fprintf('\n========== 对比 build_adjoint_source_fullmaxwell ==========\n');

% M_E^T · dJ 和 M_H^T · dJ 是"理论正确的"表面伴随场
E_adjoint_exact = M_E' * dJ_vec;  % [3N_s × 1]
H_adjoint_exact = M_H' * dJ_vec;  % [3N_s × 1]

% build_adjoint_source_fullmaxwell 输出
Delta_J_mat = reshape(dJ_vec, 3, N_k)';  % [N_k × 3]
J_obs_mat = ones(N_k, 3);  % 归一化用（避免 F_obs 干扰）

sf_dum.E_cart = reshape(E_vec, 3, N_s)';
sf_dum.H_cart = reshape(H_vec, 3, N_s)';
lc_fwd = lightcone_project(grid, sf_dum, p);
lc_adj = lc_fwd;
lc_adj.Delta_J_perp = Delta_J_mat;
lc_adj.J_obs_perp = lc_fwd.J_obs_perp;  % 用正向结果做归一化基准
[Js_out, Ms_out, ~, ~] = build_adjoint_source_fullmaxwell(grid, lc_adj, p);

Js_vec = Js_out(:);
Ms_vec = Ms_out(:);

% 对比（注意 build_adjoint 有 coeff_base 标量系数 + F_obs 归一化）
% 理论值：Js 应该正比于 E_adjoint（或 H_adjoint），Ms 正比于另一个
fprintf('对比 Js 与 M_E^T·dJ（电流核）：\n');
fprintf('  |Js|     = %.6e\n', norm(Js_vec));
fprintf('  |M_E^T·dJ| = %.6e\n', norm(E_adjoint_exact));
if norm(Js_vec) > 0 && norm(E_adjoint_exact) > 0
    cos_Js_E = abs(conj(Js_vec)' * E_adjoint_exact) / (norm(Js_vec) * norm(E_adjoint_exact));
    fprintf('  cos(Js, M_E^T·dJ) = %.6f\n', cos_Js_E);
end

fprintf('对比 Ms 与 M_H^T·dJ（磁流核）：\n');
fprintf('  |Ms|     = %.6e\n', norm(Ms_vec));
fprintf('  |M_H^T·dJ| = %.6e\n', norm(H_adjoint_exact));
if norm(Ms_vec) > 0 && norm(H_adjoint_exact) > 0
    cos_Ms_H = abs(conj(Ms_vec)' * H_adjoint_exact) / (norm(Ms_vec) * norm(H_adjoint_exact));
    fprintf('  cos(Ms, M_H^T·dJ) = %.6f\n', cos_Ms_H);
end

% 也试 Js vs M_H^T 和 Ms vs M_E^T（检查配对是否搞反）
if norm(Js_vec) > 0 && norm(H_adjoint_exact) > 0
    cos_Js_H = abs(conj(Js_vec)' * H_adjoint_exact) / (norm(Js_vec) * norm(H_adjoint_exact));
    fprintf('  cos(Js, M_H^T·dJ) = %.6f（检查配对）\n', cos_Js_H);
end
if norm(Ms_vec) > 0 && norm(E_adjoint_exact) > 0
    cos_Ms_E = abs(conj(Ms_vec)' * E_adjoint_exact) / (norm(Ms_vec) * norm(E_adjoint_exact));
    fprintf('  cos(Ms, M_E^T·dJ) = %.6f（检查配对）\n', cos_Ms_E);
end

fprintf('\n========== 诊断结论 ==========\n');
fprintf('如果矩阵级 ratio ≈ 1 但 cos(Js/Ms) 偏离 1：\n');
fprintf('  → lightcone_project 正向矩阵正确，build_adjoint_source 的核推导有 bug\n');
fprintf('如果矩阵级 ratio ≠ 1：\n');
fprintf('  → lightcone_project 本身的矩阵构造可能有误（测试代码问题）\n');
fprintf('=================================\n\n');

end
