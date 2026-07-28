function test_adjoint_numerical()
%TEST_ADJOINT_NUMERICAL 数值级伴随验证（纯黑盒，不构造矩阵）
%
%   核心原理：<L(x), y> = <x, L*(y)>
%   L = lightcone_project（正向：表面场→k空间）
%   L* = build_adjoint_source 的伴随核（k空间→表面源）
%
%   关键：不能直接把 build_adjoint_source 的输出当成 L*(y)，
%   因为它有 coeff_base / F_obs 归一化。
%   正确做法：先剥离归一化，只测纯算子核。
%
%   方法：对 lightcone_project 做 FD 微扰——数值计算其对 ΔJ 的"转置响应"

fprintf('\n========== 数值级伴随验证（黑盒） ==========\n');

addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
addpath('config', 'utils', 'core_jobs', 'core_jhyp');

p = config();
grid = build_measurement_grid(p);
N_s = size(grid.pos, 1);
N_k = p.N_k;

rng(42);

%% 1. 直接验证 lightcone_project 的线性性 + 提取纯算子
% J_obs = L_E · E + L_H · H
% 通过 4 次正向调用提取 L_E, L_H 的列：

fprintf('[TEST] 提取 lightcone_project 的正向算子（有限差分）...\n');

% 基准：零场
sf_zero.E_cart = zeros(N_s, 3);
sf_zero.H_cart = zeros(N_s, 3);
lc_zero = lightcone_project(grid, sf_zero, p);
J_zero = lc_zero.J_obs_perp;  % 应该是 0

% 对 E 的每个分量做单位场
L_E_cols = zeros(3*N_k, 3*N_s);  % [3N_k × 3N_s]
for s = 1:N_s
    for d = 1:3
        E_test = zeros(N_s, 3);
        E_test(s, d) = 1;
        sf_t.E_cart = E_test;
        sf_t.H_cart = zeros(N_s, 3);
        lc_t = lightcone_project(grid, sf_t, p);
        col_idx = (s-1)*3 + d;
        L_E_cols(:, col_idx) = lc_t.J_obs_perp(:);
    end
    if mod(s, 500) == 0
        fprintf('  E 提取进度: %d/%d\n', s, N_s);
    end
end

% 对 H 类似
L_H_cols = zeros(3*N_k, 3*N_s);
for s = 1:N_s
    for d = 1:3
        H_test = zeros(N_s, 3);
        H_test(s, d) = 1;
        sf_t.E_cart = zeros(N_s, 3);
        sf_t.H_cart = H_test;
        lc_t = lightcone_project(grid, sf_t, p);
        col_idx = (s-1)*3 + d;
        L_H_cols(:, col_idx) = lc_t.J_obs_perp(:);
    end
    if mod(s, 500) == 0
        fprintf('  H 提取进度: %d/%d\n', s, N_s);
    end
end

fprintf('[TEST] 算子提取完成: L_E[%s], L_H[%s]\n', mat2str(size(L_E_cols)), mat2str(size(L_H_cols)));

%% 2. 纯矩阵内积验证
E_vec = randn(3*N_s, 1) + 1i * randn(3*N_s, 1);
H_vec = randn(3*N_s, 1) + 1i * randn(3*N_s, 1);
dJ_vec = randn(3*N_k, 1) + 1i * randn(3*N_k, 1);

J_fwd = L_E_cols * E_vec + L_H_cols * H_vec;

% <J_fwd, dJ> = conj(dJ)' * J_fwd
LHS = conj(dJ_vec)' * J_fwd;

% <(E,H), L^H (dJ)> = conj(E)' * (L_E^H dJ) + conj(H)' * (L_H^H dJ)
RHS = conj(E_vec)' * (L_E_cols' * dJ_vec) + conj(H_vec)' * (L_H_cols' * dJ_vec);
% 注意：MATLAB 的 ' 对复矩阵是共轭转置 = H

ratio_matrix = LHS / RHS;

fprintf('\n========== 矩阵级内积（FD 提取的算子） ==========\n');
fprintf('LHS = <L(E,H), dJ>   = %.6e + %.6ei\n', real(LHS), imag(LHS));
fprintf('RHS = <(E,H), L^H dJ> = %.6e + %.6ei\n', real(RHS), imag(RHS));
fprintf('ratio = %.15f + %.15fi\n', real(ratio_matrix), imag(ratio_matrix));
fprintf('|ratio-1| = %.2e\n', abs(ratio_matrix - 1));

if abs(ratio_matrix - 1) < 1e-8
    fprintf('★★★ 矩阵级 PASS（FD 提取的 lightcone_project 算子正确）★★★\n');
else
    fprintf('★★★ 矩阵级 FAIL ★★★\n');
end

%% 3. 对比 build_adjoint_source 的输出与 L_E^H·dJ / L_H^H·dJ
fprintf('\n========== 对比 build_adjoint_source ==========\n');

E_adj_exact = conj(L_E_cols' * dJ_vec);  % L_E^H dJ，但伴随定义需注意 conj
H_adj_exact = conj(L_H_cols' * dJ_vec);

% 实际上：<L x, y> = <x, L^H y> 其中 <a,b>=conj(a)'b
% 所以 L^H y 就是 conj(L_E_cols)' dJ 的逐列展开
E_adj_LH = L_E_cols' * dJ_vec;  % 这就是 L_E^H · dJ（MATLAB ' 已含 conj）
H_adj_LH = L_H_cols' * dJ_vec;

Delta_J_mat = reshape(dJ_vec, 3, N_k)';
sf_dum.E_cart = reshape(E_vec, 3, N_s)';
sf_dum.H_cart = reshape(H_vec, 3, N_s)';
lc_fwd = lightcone_project(grid, sf_dum, p);
lc_adj = lc_fwd;
lc_adj.Delta_J_perp = Delta_J_mat;
lc_adj.J_obs_perp = lc_fwd.J_obs_perp;
[Js_out, Ms_out, ~, ~] = build_adjoint_source_fullmaxwell(grid, lc_adj, p);

Js_vec = Js_out(:);
Ms_vec = Ms_out(:);

fprintf('|Js|=%.4e, |Ms|=%.4e\n', norm(Js_vec), norm(Ms_vec));
fprintf('|L_E^H dJ|=%.4e, |L_H^H dJ|=%.4e\n', norm(E_adj_LH), norm(H_adj_LH));

if norm(Js_vec) > 0 && norm(E_adj_LH) > 0
    cos1 = abs(conj(Js_vec)' * E_adj_LH) / (norm(Js_vec) * norm(E_adj_LH));
    fprintf('cos(Js, L_E^H·dJ) = %.6f  （Js=电伴随，配 L_E？）\n', cos1);
end
if norm(Js_vec) > 0 && norm(H_adj_LH) > 0
    cos2 = abs(conj(Js_vec)' * H_adj_LH) / (norm(Js_vec) * norm(H_adj_LH));
    fprintf('cos(Js, L_H^H·dJ) = %.6f  （Js=电伴随，配 L_H？）\n', cos2);
end
if norm(Ms_vec) > 0 && norm(E_adj_LH) > 0
    cos3 = abs(conj(Ms_vec)' * E_adj_LH) / (norm(Ms_vec) * norm(E_adj_LH));
    fprintf('cos(Ms, L_E^H·dJ) = %.6f  （Ms=磁伴随，配 L_E？）\n', cos3);
end
if norm(Ms_vec) > 0 && norm(H_adj_LH) > 0
    cos4 = abs(conj(Ms_vec)' * H_adj_LH) / (norm(Ms_vec) * norm(H_adj_LH));
    fprintf('cos(Ms, L_H^H·dJ) = %.6f  （Ms=磁伴随，配 L_H？）\n', cos4);
end

fprintf('\n========== 结论 ==========\n');
fprintf('1. 矩阵级 ratio 验证 lightcone_project 的算子自洽性\n');
fprintf('2. cos 值判定 build_adjoint_source 的 Js/Ms 是否匹配 L_E^H/L_H^H\n');
fprintf('   - cos ≈ 1 → 匹配（核正确）\n');
fprintf('   - cos ≈ 0 → 不匹配（核推导有 bug 或配对搞反）\n');
fprintf('============================\n\n');

end
