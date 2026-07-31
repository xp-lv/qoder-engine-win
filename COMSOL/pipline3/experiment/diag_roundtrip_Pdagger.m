function diag_roundtrip_Pdagger()
%DIAG_ROUNDTRIP_PDAGGER 验证 P·P† = I 的往返一致性
%   取 ΔJ → 反投影 S(r_v) → 正向投影 J_back → 对比 ΔJ

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  往返一致性测试: ΔJ → P† → S(r_v) → P → J_back\n');
fprintf('############################################################\n\n');

p = config();
voxel = struct();
% 用与验证脚本相同的体素网格（不连 COMSOL，纯数值测试）
N_inner = 1164;
R_inner = 0.06;
% 生成简化体素位置（球内均匀分布的近似）
rng(42);
pos = rand(N_inner, 3) * 2 * R_inner - R_inner;
r = vecnorm(pos, 2, 2);
mask = r < R_inner;
pos = pos(mask, :);
N_inner = size(pos, 1);
dV = (4/3*pi*R_inner^3 / N_inner) * ones(N_inner, 1);
fprintf('N_voxel=%d, R_inner=%.4f\n', N_inner, R_inner);

% k 方向采样
[k_dir, dOmega] = fibonacci_sphere(p.N_k);
k_vec = p.k0 * k_dir;
N_k = p.N_k;
fprintf('N_k=%d\n\n', N_k);

%% 1. 构造正向算子 P (N_k × N_voxel，标量相位核)
% P(k,v) = dV_v * exp(-j*k_vec_k · r_v)
% 注意：每个 k 行对 3 个分量 (x,y,z) 独立作用
fprintf('构造正向算子 P [%d x %d]...\n', N_k, N_inner);
P = zeros(N_k, N_inner);
for ki = 1:N_k
    phase_v = exp(-1i * (pos * k_vec(ki,:)'));  % [N_inner x 1]
    P(ki, :) = (dV(:) .* phase_v)';
end

%% 2. 构造伴随算子 P† (N_voxel × N_k)
% P†(v,k) = exp(+j*k_vec_k · r_v)（共轭转置）
% 注意：反投影代码中用 dOmega(k) 权重求和，这里也保持一致
fprintf('构造伴随算子 P† [%d x %d]...\n', N_inner, N_k);
Pd = zeros(N_inner, N_k);
for ki = 1:N_k
    Pd(:, ki) = exp(1i * (pos * k_vec(ki,:)'));
end

%% 3. 构造测试 ΔJ (N_k × 3)
Delta_J = randn(N_k, 3) + 1i * randn(N_k, 3);
fprintf('测试 ΔJ: %d x 3, |ΔJ| mean=%.4e\n\n', N_k, mean(vecnorm(Delta_J, 2, 2)));

%% 4. 反投影: S = P† · ΔJ (按代码方式：加权求和)
% 代码: S(r_v) = Σ_k dOmega_k · ΔJ(k) · exp(+j*k·r_v)
S = zeros(N_inner, 3);
for ki = 1:N_k
    S = S + dOmega(ki) * Delta_J(ki, :) .* Pd(:, ki);
end
fprintf('反投影 S: %d x 3, |S| mean=%.4e\n', N_inner, mean(vecnorm(S, 2, 2)));

%% 5. 正向投影: J_back = P · S (按代码方式)
% 代码: J_hyp(k) = Σ_v dV_v · J_equi(v) · exp(-j*k·r_v)
J_back = zeros(N_k, 3);
for ki = 1:N_k
    J_back(ki, :) = sum(dV .* S .* P(ki, :)', 1);
end
fprintf('正向投影 J_back: %d x 3, |J_back| mean=%.4e\n\n', N_k, mean(vecnorm(J_back, 2, 2)));

%% 6. 对比 ΔJ 和 J_back
fprintf('========== 往返对比: ΔJ vs P·P†·ΔJ ==========\n');
ratio_vec = zeros(N_k, 3);
for ki = 1:N_k
    for d = 1:3
        if abs(Delta_J(ki,d)) > 1e-30
            ratio_vec(ki,d) = J_back(ki,d) / Delta_J(ki,d);
        end
    end
end

% 统计
all_ratios = ratio_vec(abs(ratio_vec) > 0);
fprintf('  ratio (J_back/ΔJ) mean = %.4f\n', mean(real(all_ratios)));
fprintf('  ratio std          = %.4f\n', std(real(all_ratios)));
fprintf('  |ratio| mean       = %.4f\n', mean(abs(all_ratios)));
fprintf('  phase(mean)        = %.4f rad\n', angle(mean(all_ratios)));

%% 7. 计算 P·P† 矩阵 (16×16) 并检查是否接近单位阵
fprintf('\n========== P·P† 矩阵分析 (16×16) ==========\n');
% P·P† = Σ_v dV_v^2 ... 不对，应该是:
% (P·P†)_{k,k'} = Σ_v P(k,v) * Pd(v,k') 
%               = Σ_v dV_v * exp(-j*k_k·r_v) * exp(+j*k_{k'}·r_v)
%               = Σ_v dV_v * exp(j*(k_{k'} - k_k)·r_v)
% 但代码中 P† 的权重是 dOmega(k)，P 的权重是 dV_v
% 所以实际的 (P·P†_code)_{k,k'} = Σ_v dV_v * exp(j*(k_{k'}-k_k)·r_v) * dOmega(k')
% 这里不对。让我重新算。

% 正向: J(k) = Σ_v dV_v · S(v) · exp(-j*k_k·r_v)  = P(k,:) · S
% 反投影: S(v) = Σ_{k'} dOmega_{k'} · ΔJ(k') · exp(+j*k_{k'}·r_v) = Pd(v,:) · (dOmega .* ΔJ)
% 所以: J_back(k) = Σ_v dV_v · [Σ_{k'} dOmega_{k'} · ΔJ(k') · exp(+j*k_{k'}·r_v)] · exp(-j*k_k·r_v)
%                 = Σ_{k'} dOmega_{k'} · ΔJ(k') · [Σ_v dV_v · exp(j*(k_{k'}-k_k)·r_v)]
%
% 定义 M(k,k') = Σ_v dV_v · exp(j*(k_{k'}-k_k)·r_v)
% 则 J_back = M · diag(dOmega) · ΔJ

M = zeros(N_k, N_k);
for kk = 1:N_k
    for kp = 1:N_k
        dk = k_vec(kp,:) - k_vec(kk,:);
        phase_kk = exp(1i * (pos * dk'));  % [N_inner x 1]
        M(kk, kp) = sum(dV(:) .* phase_kk);
    end
end

% J_back 应该 = M · diag(dOmega) · ΔJ
J_pred = M * (dOmega .* Delta_J);

fprintf('  M·diag(dΩ)·ΔJ vs 实际 J_back 的误差: %.2e\n', ...
    max(abs(J_pred(:) - J_back(:))));

fprintf('\n  M·diag(dΩ) 的特征值:\n');
MD = M * diag(dOmega);
ev = eig(MD);
fprintf('    |λ| range: [%.4f, %.4f]\n', min(abs(ev)), max(abs(ev)));
fprintf('    |λ| mean:  %.4f\n', mean(abs(ev)));
fprintf('    Re(λ) range: [%.4f, %.4f]\n', min(real(ev)), max(real(ev)));

% 对角线元素
diag_MD = diag(MD);
fprintf('\n  M·diag(dΩ) 对角线 (应≈常数):\n');
fprintf('    Re range: [%.4f, %.4f], mean=%.4f\n', min(real(diag_MD)), max(real(diag_MD)), mean(real(diag_MD)));
fprintf('    Im range: [%.4f, %.4f], mean=%.4f\n', min(imag(diag_MD)), max(imag(diag_MD)), mean(imag(diag_MD)));

%% 8. 结论
fprintf('\n############################################################\n');
fprintf('#  结论\n');
fprintf('#  如果 M·diag(dΩ) ≈ c·I (c为常数)，则 P·P† = c·I\n');
fprintf('#  → 反投影+正投影是 k 空间的标量缩放，方向信息无损\n');
fprintf('#  → 伴随算子 P† 是 P 在 k 空间的精确（标量缩放）伴随\n');
fprintf('#  但 P†·P ≠ I_voxel（1164维），16个k无法覆盖所有体素信息\n');
fprintf('############################################################\n');

end
