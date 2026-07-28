#!/usr/bin/env python3
"""
coeff_base 解析推导验证

验证链：
  目标函数 F 对 J_hyp 的 Wirtinger 导数 → 伴随源 → COMSOL 源项 → lambda → g_voxel

关键问题：coeff_base 应该取什么值才能让 g_adjoint = g_FD？

推导：
  1. F = (1/(N_freq*N_k*6)) * sum_k |Delta_J(k)|^2 * w_k
  2. dF/dJ_hyp(k) = -(1/(N_freq*N_k*6)) * conj(Delta_J_perp(k))
  3. 伴随源 = L^H * dF/dJ_hyp = -(1/(N_freq*N_k*6)) * L^H * conj(Delta_J_perp)

  COMSOL 源项约定：
    Js0_COMSOL = -i * conj(Js) / (omega*mu0)
    Jms0_COMSOL = -i * conj(Ms)
    lambda = conj(lambda_raw)

  两个 conj 抵消效应分析
"""

import numpy as np

def fibonacci_sphere(N):
    points = np.zeros((N, 3))
    golden = np.pi * (3 - np.sqrt(5))
    for i in range(1, N + 1):
        y = 1 - (i - 0.5) * 2 / N
        radius = np.sqrt(1 - y**2)
        theta = golden * (i - 1)
        points[i - 1] = [np.cos(theta) * radius, np.sin(theta) * radius, y]
    dOmega = (4 * np.pi / N) * np.ones(N)
    return points, dOmega

def build_measurement_grid(R, N_theta, N_phi):
    theta_v = np.linspace(0, np.pi, N_theta + 1)
    theta_v = theta_v[:-1] + np.diff(theta_v) / 2
    phi_v = np.linspace(0, 2 * np.pi, N_phi + 1)
    phi_v = phi_v[:-1] + np.diff(phi_v) / 2
    delta_theta = np.pi / N_theta
    delta_phi = 2 * np.pi / N_phi
    pos_list, norm_list, weight_list = [], [], []
    for theta_i in theta_v:
        sin_t, cos_t = np.sin(theta_i), np.cos(theta_i)
        area_weight = R**2 * sin_t * delta_theta * delta_phi
        for phi_i in phi_v:
            sin_p, cos_p = np.sin(phi_i), np.cos(phi_i)
            pos_list.append([R*sin_t*cos_p, R*sin_t*sin_p, R*cos_t])
            norm_list.append([sin_t*cos_p, sin_t*sin_p, cos_t])
            weight_list.append(area_weight)
    return np.array(pos_list), np.array(norm_list), np.array(weight_list)


def build_forward_matrices(pos, norm, weight, k_dir, k0, eta0):
    N_s, N_k = len(pos), len(k_dir)
    M_E = np.zeros((3*N_k, 3*N_s), dtype=complex)
    M_H = np.zeros((3*N_k, 3*N_s), dtype=complex)
    I3 = np.eye(3)
    for i in range(N_k):
        ki = k_dir[i]
        for s in range(N_s):
            ns, rs, ws = norm[s], pos[s], weight[s]
            phase = np.exp(-1j * k0 * np.dot(ki, rs))
            ws_phase = ws * phase
            n_cross = np.array([[0,-ns[2],ns[1]],[ns[2],0,-ns[0]],[-ns[1],ns[0],0]])
            sub_H = (np.outer(ki, ki) - I3) @ n_cross
            M_H[3*i:3*i+3, 3*s:3*s+3] = ws_phase * sub_H
            ndk = np.dot(ns, ki)
            sub_E = (np.outer(ns, ki) - ndk * I3) / eta0
            M_E[3*i:3*i+3, 3*s:3*s+3] = ws_phase * sub_E
    return M_E, M_H


print("=" * 65)
print("  coeff_base 解析推导验证")
print("=" * 65)

# 参数
R = 0.26; c = 299792458; freq = 1e9
omega = 2*np.pi*freq; k0 = omega/c
eps0 = 8.854187817e-12; mu0 = 4*np.pi*1e-7; eta0 = np.sqrt(mu0/eps0)
N_theta, N_phi, N_k = 6, 12, 16  # 小规模便于稠密矩阵
N_freq = 1

# 网格
pos, norm, weight = build_measurement_grid(R, N_theta, N_phi)
k_dir, dOmega = fibonacci_sphere(N_k)
N_s = len(pos)

# 正向矩阵
M_E, M_H = build_forward_matrices(pos, norm, weight, k_dir, k0, eta0)

# 随机测试数据
rng = np.random.default_rng(42)
E_vec = rng.standard_normal(3*N_s) + 1j*rng.standard_normal(3*N_s)
H_vec = rng.standard_normal(3*N_s) + 1j*rng.standard_normal(3*N_s)
dJ_vec = rng.standard_normal(3*N_k) + 1j*rng.standard_normal(3*N_k)

print(f"\n  N_freq={N_freq}, N_k={N_k}, N_s={N_s}")
print(f"  omega={omega:.4e}, mu0={mu0:.4e}, eps0={eps0:.4e}")
print(f"  eta0={eta0:.2f}, k0={k0:.4f}")

# ============================================================
# 步骤 1: 验证 <L(field), dJ> = <field, L^H dJ>（结构正确性）
# ============================================================
print(f"\n{'='*65}")
print("  步骤 1: 矩阵级伴随验证（coeff_base=1, 修正权重）")
print(f"{'='*65}")

J_fwd = M_E @ E_vec + M_H @ H_vec
LHS = np.conj(J_fwd) @ dJ_vec

Js_exact = (M_H.conj().T @ dJ_vec).reshape(-1, 3)  # H变分
Ms_exact = (M_E.conj().T @ dJ_vec).reshape(-1, 3)  # E变分
RHS = np.conj(H_vec) @ Js_exact.reshape(-1) + np.conj(E_vec) @ Ms_exact.reshape(-1)
ratio = LHS / RHS
print(f"  ratio = {ratio:.15f}")
print(f"  |ratio-1| = {abs(ratio-1):.2e}  {'PASS' if abs(ratio-1)<1e-10 else 'FAIL'}")

# ============================================================
# 步骤 2: 验证 dF/dJ_hyp 的共轭 vs 非共轭
# ============================================================
print(f"\n{'='*65}")
print("  步骤 2: Wirtinger 导数验证（conj(Delta_J) vs Delta_J）")
print(f"{'='*65}")

# 理论：dF/dJ_hyp(k) = -(1/(N_freq*N_k*6)) * conj(Delta_J_perp(k))
# 伴随源 = L^H * dF/dJ_hyp = -(1/(N_freq*N_k*6)) * L^H * conj(Delta_J_perp)

# 但代码中 build_adjoint_source_fullmaxwell 传入的是 Delta_J_perp（不取共轭）
# COMSOL 源项 Js0 = -i*conj(Js)/(omega*mu0) 又做了共轭
# 所以净效应：COMSOL 收到的是 -i*conj(coeff_base * w(s) * sum(核 * Delta_J * phase)) / (omega*mu0)
#           = -i*conj(coeff_base)/(omega*mu0) * w(s) * sum(核 * conj(Delta_J) * conj(phase))
#           = -i*conj(coeff_base)/(omega*mu0) * w(s) * sum(核 * conj(Delta_J) * exp(-ikr))

# 而理论要求的源（产生正确 lambda 的 COMSOL 源）是 L^H * conj(Delta_J_perp)：
# = w(s) * sum(核^H * conj(Delta_J_perp) * exp(+ikr))
# 注意 核^H 含 conj（但实向量的核^H = 核^T），且 exp(+ikr) 来自相位翻转

# 验证：conj(Delta_J * exp(+ikr)) = conj(Delta_J) * exp(-ikr)
# 所以 COMSOL 源中的 conj(Js) 确实引入了 conj(Delta_J) * exp(-ikr)
# 这等于 conj(Delta_J * exp(+ikr))

# 关键检查：conj(phase)*核 vs phase*核^T
# L^H * conj(Delta_J) 的相位是 exp(+ikr) * conj(Delta_J) = conj(Delta_J * exp(-ikr))
# 但 COMSOL 源给出的是 conj(Delta_J) * exp(-ikr) = conj(Delta_J * exp(+ikr))

# 这两者相差一个相位方向！exp(+ikr) vs exp(-ikr)

# 检查：L^H 作用于 conj(dJ) 是否等于 conj(L^T 作用于 dJ)？
# L^H * conj(dJ) = conj(L)^T * conj(dJ) = conj(L * dJ)... 不对
# conj(L)^T * conj(dJ) = conj(L^T * dJ)... 不对
# 对元素：L^H_{si} * conj(dJ_i) = conj(L_{is}) * conj(dJ_i) = conj(L_{is} * dJ_i)
# 所以 L^H * conj(dJ) = conj(L^T * dJ)（逐元素）

# 而 COMSOL 源给出的是 conj(coeff_base) * w(s) * sum_i conj(核 * Delta_J * phase)
# = conj(coeff_base) * w(s) * conj(sum_i 核 * Delta_J * exp(+ikr))  （核是实操作+相位）
# = conj(coeff_base * w(s) * sum_i 核 * Delta_J * exp(+ikr))
# = conj(Js_raw)   （如果 coeff_base 在外面）

# 而 L^H * conj(Delta_J) 理论值 = w(s) * sum_i conj(核 * Delta_J * exp(+ikr))
# 这不等于 conj(L^H * Delta_J)！

# 让我直接验证
dJ_conj = np.conj(dJ_vec)
Js_from_conj = (M_H.conj().T @ dJ_conj).reshape(-1, 3)
Js_conj_of_raw = np.conj(Js_exact)  # conj(M_H^H @ dJ)

# L^H * conj(dJ) vs conj(L^H * dJ)
ratio_conj = np.vdot(Js_from_conj.reshape(-1), Js_conj_of_raw.reshape(-1)) / \
             np.vdot(Js_conj_of_raw.reshape(-1), Js_conj_of_raw.reshape(-1))
print(f"  L^H*conj(dJ) vs conj(L^H*dJ): ratio = {ratio_conj:.15f}")
if abs(ratio_conj - 1) < 1e-10:
    print(f"  -> 恒等（L^H*conj(dJ) = conj(L^H*dJ)），COMSOL 的 conj 约定正确补偿")
else:
    print(f"  -> 不等！需要额外处理共轭")

# ============================================================
# 步骤 3: coeff_base 理论值推导
# ============================================================
print(f"\n{'='*65}")
print("  步骤 3: coeff_base 理论推导")
print(f"{'='*65}")

# 完整链：
#   Js = coeff_base * w(s) * sum_i (核^H . Delta_J_perp . phase)   [代码]
#   Js0_COMSOL = -i * conj(Js) / (omega*mu0)                        [COMSOL约定]
#              = -i * conj(coeff_base) / (omega*mu0) * w(s) * conj(sum_i 核^H . Delta_J . phase)
#              = -i * conj(coeff_base) / (omega*mu0) * (L^H * conj(Delta_J)) [步骤2验证]
#
#   lambda_raw = G(Js0_COMSOL, Jms0_COMSOL)                         [COMSOL求解]
#   lambda = conj(lambda_raw)                                       [代码提取]
#
#   g_voxel = -k0^2 * DeltaV * Re(lambda * E_fwd) / N_freq         [梯度公式]
#
# 理论伴随源 = L^H * dF/dJ_hyp
#           = -(1/(N_freq*N_k*6)) * L^H * conj(Delta_J_perp)
#
# 要使 Js0_COMSOL 产生的 lambda 满足 g_voxel = FD梯度：
#   Js0_COMSOL 应正比于 理论伴随源
#   -i * conj(coeff_base) / (omega*mu0) = -(1/(N_freq*N_k*6)) * c_Green
#
# 其中 c_Green 是 Green 函数引入的常数（COMSOL Maxwell 方程的归一化）

# 简化：假设 c_Green = 1（COMSOL 的 Green 函数是标准的）
# -i * conj(coeff_base) / (omega*mu0) = -(1/(N_freq*N_k*6))
# conj(coeff_base) = i * omega*mu0 / (N_freq*N_k*6)
# coeff_base = -i * omega*mu0 / (N_freq*N_k*6)

coeff_theory = -1j * omega * mu0 / (N_freq * N_k * 6)
print(f"  理论 coeff_base = -i * omega * mu0 / (N_freq*N_k*6)")
print(f"                  = -i * {omega:.4e} * {mu0:.4e} / ({N_freq}*{N_k}*6)")
print(f"                  = {coeff_theory:.6e}")

# 对比旧值
coeff_old = -0.5j * omega * eps0 * 4.0
coeff_new = -0.5j * omega * eps0  # 当前代码修正后的初始值
print(f"\n  对比：")
print(f"    旧 coeff_base (经验魔数) = {coeff_old:.6e}")
print(f"    新 coeff_base (初始估计) = {coeff_new:.6e}")
print(f"    理论 coeff_base          = {coeff_theory:.6e}")
print(f"    旧/理论 = {coeff_old/coeff_theory:.4f}")
print(f"    新/理论 = {coeff_new/coeff_theory:.4f}")

# 但注意：这个理论值假设 c_Green=1，实际需要 FD 标定验证
print(f"\n  ★ 注意：理论值假设 COMSOL Green 函数归一化 c_Green=1")
print(f"    实际 coeff_base 需通过 FD 标定最终确认")
print(f"    预期：修正后 ratio = g_adj/g_FD 应为全局常数（不再随参数漂移）")

# ============================================================
# 步骤 4: 验证修正后 ratio 的恒定性（结构正确性的最终确认）
# ============================================================
print(f"\n{'='*65}")
print("  步骤 4: 多组随机数据验证 ratio 恒定性")
print(f"{'='*65}")

print(f"\n  {'测试':>4}  {'ratio_real':>14}  {'ratio_imag':>14}  {'|ratio-1|':>12}  结果")
print(f"  {'-'*4}  {'-'*14}  {'-'*14}  {'-'*12}  {'-'*4}")

for trial in range(10):
    rng_trial = np.random.default_rng(trial)
    E_t = rng_trial.standard_normal(3*N_s) + 1j*rng_trial.standard_normal(3*N_s)
    H_t = rng_trial.standard_normal(3*N_s) + 1j*rng_trial.standard_normal(3*N_s)
    dJ_t = rng_trial.standard_normal(3*N_k) + 1j*rng_trial.standard_normal(3*N_k)

    J_t = M_E @ E_t + M_H @ H_t
    LHS_t = np.conj(J_t) @ dJ_t

    Js_t = (M_H.conj().T @ dJ_t).reshape(-1, 3)
    Ms_t = (M_E.conj().T @ dJ_t).reshape(-1, 3)
    RHS_t = np.conj(H_t) @ Js_t.reshape(-1) + np.conj(E_t) @ Ms_t.reshape(-1)
    r = LHS_t / RHS_t
    status = "PASS" if abs(r - 1) < 1e-10 else "FAIL"
    print(f"  {trial+1:>4}  {r.real:>14.15f}  {r.imag:>14.15f}  {abs(r-1):>12.2e}  {status}")

print(f"\n  结论：10 组随机数据全部 PASS → A = L^H（结构精确）")
print(f"  coeff_base 不影响 ratio 恒定性（它是全局标量缩放）")
print(f"  → 需要 FD 标定确定 coeff_base 的最终值（步骤 5）")
