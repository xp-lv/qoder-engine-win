#!/usr/bin/env python3
"""
伴随算子精确性矩阵级验证（纯 numpy，不依赖 COMSOL/MATLAB）

验证原理：
  <L(E,H), ΔJ>  ==  <(E,H), A(ΔJ)>

其中：
  L = lightcone_project 的正向核矩阵 [3N_k × 3N_s]
  A = build_adjoint_source_fullmaxwell 的伴随核

如果 A = L^H（共轭转置），则 ratio = LHS/RHS ≈ 1.0（机器精度 ~1e-15）
"""

import numpy as np

# ============================================================
# 1. 网格构建（复现 build_measurement_grid.m + fibonacci_sphere.m）
# ============================================================

def build_measurement_grid(R, N_theta, N_phi):
    """复现 MATLAB build_measurement_grid.m"""
    theta_v = np.linspace(0, np.pi, N_theta + 1)
    theta_v = theta_v[:-1] + np.diff(theta_v) / 2

    phi_v = np.linspace(0, 2 * np.pi, N_phi + 1)
    phi_v = phi_v[:-1] + np.diff(phi_v) / 2

    delta_theta = np.pi / N_theta
    delta_phi = 2 * np.pi / N_phi

    pos_list = []
    norm_list = []
    weight_list = []

    for theta_i in theta_v:
        sin_t = np.sin(theta_i)
        cos_t = np.cos(theta_i)
        area_weight = R**2 * sin_t * delta_theta * delta_phi

        for phi_i in phi_v:
            sin_p = np.sin(phi_i)
            cos_p = np.cos(phi_i)
            x = R * sin_t * cos_p
            y = R * sin_t * sin_p
            z = R * cos_t
            pos_list.append([x, y, z])
            r_hat = [sin_t * cos_p, sin_t * sin_p, cos_t]
            norm_list.append(r_hat)
            weight_list.append(area_weight)

    return (np.array(pos_list), np.array(norm_list),
            np.array(weight_list))


def fibonacci_sphere(N):
    """复现 MATLAB fibonacci_sphere.m"""
    points = np.zeros((N, 3))
    golden = np.pi * (3 - np.sqrt(5))
    for i in range(1, N + 1):
        y = 1 - (i - 0.5) * 2 / N
        radius = np.sqrt(1 - y**2)
        theta = golden * (i - 1)
        points[i - 1] = [np.cos(theta) * radius, np.sin(theta) * radius, y]
    dOmega = (4 * np.pi / N) * np.ones(N)
    return points, dOmega


# ============================================================
# 2. 正向矩阵 M_E, M_H 构建（复现 lightcone_project.m 的核）
# ============================================================

def build_forward_matrices(pos, norm, weight, k_dir, k0, eta0):
    """
    构建 M_E [3N_k × 3N_s] 和 M_H [3N_k × 3N_s]

    正向：J_obs(i) = Σ_s M_E(i,s)·E(s) + M_H(i,s)·H(s)

    M_H(i,s) = w(s) * exp(-ik₀k̂ᵢ·r_s) * (k̂k̂ᵀ - I)·[n̂×]
    M_E(i,s) = w(s) * exp(-ik₀k̂ᵢ·r_s) * (n̂k̂ᵀ - (n̂·k̂)I) / η₀
    """
    N_s = len(pos)
    N_k = len(k_dir)

    M_E = np.zeros((3 * N_k, 3 * N_s), dtype=complex)
    M_H = np.zeros((3 * N_k, 3 * N_s), dtype=complex)

    I3 = np.eye(3)

    for i in range(N_k):
        ki = k_dir[i]
        for s in range(N_s):
            ns = norm[s]
            rs = pos[s]
            ws = weight[s]

            phase = np.exp(-1j * k0 * np.dot(ki, rs))
            ws_phase = ws * phase

            # n̂× 矩阵（叉乘）
            n_cross = np.array([
                [0, -ns[2], ns[1]],
                [ns[2], 0, -ns[0]],
                [-ns[1], ns[0], 0]
            ])

            # M_H 子块: (k̂k̂ᵀ - I)·(n̂×)
            sub_H = (np.outer(ki, ki) - I3) @ n_cross
            r_H = slice(3 * i, 3 * i + 3)
            c_H = slice(3 * s, 3 * s + 3)
            M_H[r_H, c_H] = ws_phase * sub_H

            # M_E 子块: (n̂k̂ᵀ - (n̂·k̂)I) / η₀
            ndk = np.dot(ns, ki)
            sub_E = (np.outer(ns, ki) - ndk * I3) / eta0
            M_E[r_H, c_H] = ws_phase * sub_E

    return M_E, M_H


# ============================================================
# 3. 伴随算子实现（三个版本对比）
# ============================================================

def adjoint_CODE_VERSION(pos, norm, weight, k_dir, dOmega, Delta_J, k0, eta0, coeff_base):
    """
    复现 build_adjoint_source_fullmaxwell.m 当前代码（含 bug）
    Js = coeff_base * Σ_i dΩ_i * n̂ × (ΔJ_perp(i) * phase)
    Ms = coeff_base * Σ_i dΩ_i * [k̂(n̂·ΔJ) - ΔJ(n̂·k̂)]/η₀ * phase
    """
    N_s = len(pos)
    N_k = len(k_dir)

    Js = np.zeros((N_s, 3), dtype=complex)
    Ms = np.zeros((N_s, 3), dtype=complex)

    for sj in range(N_s):
        rs = pos[sj]
        n_hat = norm[sj]
        phase = np.exp(1j * k0 * k_dir @ rs)  # [N_k]

        v = Delta_J * phase[:, np.newaxis]  # [N_k × 3]

        kdv = np.sum(k_dir * v, axis=1)  # [N_k]
        v_perp = v - k_dir * kdv[:, np.newaxis]
        KJt_v = np.cross(n_hat, v_perp)  # n̂ × v_perp, [N_k × 3]

        ndv = np.sum(n_hat * v, axis=1)
        ndk = np.sum(n_hat[np.newaxis, :] * k_dir, axis=1)
        KMt_v = (k_dir * ndv[:, np.newaxis] - ndk[:, np.newaxis] * v) / eta0

        Js[sj] = coeff_base * np.sum(dOmega[:, np.newaxis] * KJt_v, axis=0)
        Ms[sj] = coeff_base * np.sum(dOmega[:, np.newaxis] * KMt_v, axis=0)

    return Js, Ms


def adjoint_FIXED_VERSION(pos, norm, weight, k_dir, dOmega, Delta_J, k0, eta0, coeff_base):
    """
    修正版：去掉 dOmega 权重，加上 w(s) 面元权重
    Js(s) = coeff_base * w(s) * Σ_i n̂ × (ΔJ_perp(i) * phase)
    Ms(s) = coeff_base * w(s) * Σ_i [k̂(n̂·ΔJ) - ΔJ(n̂·k̂)]/η₀ * phase
    """
    N_s = len(pos)
    N_k = len(k_dir)

    Js = np.zeros((N_s, 3), dtype=complex)
    Ms = np.zeros((N_s, 3), dtype=complex)

    for sj in range(N_s):
        rs = pos[sj]
        n_hat = norm[sj]
        ws = weight[sj]
        phase = np.exp(1j * k0 * k_dir @ rs)  # [N_k]

        v = Delta_J * phase[:, np.newaxis]  # [N_k × 3]

        kdv = np.sum(k_dir * v, axis=1)
        v_perp = v - k_dir * kdv[:, np.newaxis]
        KJt_v = np.cross(n_hat, v_perp)

        ndv = np.sum(n_hat * v, axis=1)
        ndk = np.sum(n_hat[np.newaxis, :] * k_dir, axis=1)
        KMt_v = (k_dir * ndv[:, np.newaxis] - ndk[:, np.newaxis] * v) / eta0

        # ★ 修正：无 dOmega，乘 w(s)
        Js[sj] = coeff_base * ws * np.sum(KJt_v, axis=0)
        Ms[sj] = coeff_base * ws * np.sum(KMt_v, axis=0)

    return Js, Ms


def adjoint_EXACT_VERSION(M_E, M_H, dJ_vec):
    """
    理论精确版：直接用矩阵共轭转置 M^H · dJ
    A_E(dJ)(s) = M_E^H · dJ  → 对应 Ms（磁流，E变分）
    A_H(dJ)(s) = M_H^H · dJ  → 对应 Js（电流，H变分）
    """
    Js_exact = (M_H.conj().T @ dJ_vec).reshape(-1, 3)  # M_H^H → H变分 → Js
    Ms_exact = (M_E.conj().T @ dJ_vec).reshape(-1, 3)  # M_E^H → E变分 → Ms
    return Js_exact, Ms_exact


# ============================================================
# 4. 主验证流程
# ============================================================

def run_test(N_theta, N_phi, N_k, label=""):
    """运行一次完整的内积测试"""
    print(f"\n{'='*60}")
    print(f"  伴随算子内积测试 {label}")
    print(f"  N_surface={N_theta*N_phi}, N_k={N_k}")
    print(f"{'='*60}")

    # 物理参数
    R = 0.26
    c = 299792458
    freq = 1e9
    omega = 2 * np.pi * freq
    k0 = omega / c
    eps0 = 8.854187817e-12
    mu0 = 4 * np.pi * 1e-7
    eta0 = np.sqrt(mu0 / eps0)

    # 网格
    pos, norm, weight = build_measurement_grid(R, N_theta, N_phi)
    k_dir, dOmega = fibonacci_sphere(N_k)
    N_s = len(pos)

    print(f"  R={R}, k0={k0:.4f}, eta0={eta0:.2f}")
    print(f"  w(s) range: [{weight.min():.4e}, {weight.max():.4e}]")
    print(f"  dOmega = {dOmega[0]:.4e} (均匀)")

    # 构建正向矩阵
    print("\n  [1] 构建正向矩阵 M_E, M_H...")
    M_E, M_H = build_forward_matrices(pos, norm, weight, k_dir, k0, eta0)
    print(f"      M_E shape={M_E.shape}, M_H shape={M_H.shape}")

    # 随机测试数据
    rng = np.random.default_rng(42)
    E_vec = rng.standard_normal(3 * N_s) + 1j * rng.standard_normal(3 * N_s)
    H_vec = rng.standard_normal(3 * N_s) + 1j * rng.standard_normal(3 * N_s)
    dJ_vec = rng.standard_normal(3 * N_k) + 1j * rng.standard_normal(3 * N_k)

    # 正向
    J_fwd = M_E @ E_vec + M_H @ H_vec

    # LHS = <J_fwd, dJ> = conj(J_fwd)^T · dJ  (标准 Hermitian 内积)
    LHS = np.conj(J_fwd) @ dJ_vec

    Delta_J = dJ_vec.reshape(N_k, 3)

    # ---- 理论精确伴随（矩阵共轭转置，金标准）----
    print("\n  [2] 理论精确伴随 (M^H · dJ)...")
    Js_exact, Ms_exact = adjoint_EXACT_VERSION(M_E, M_H, dJ_vec)

    # RHS = <H, Js> + <E, Ms>  （★ 注意配对：Js→H变分，Ms→E变分）
    RHS_exact = (np.conj(H_vec) @ Js_exact.reshape(-1) +
                 np.conj(E_vec) @ Ms_exact.reshape(-1))

    ratio_exact = LHS / RHS_exact
    print(f"      ratio = {ratio_exact:.15f}")
    print(f"      |ratio - 1| = {abs(ratio_exact - 1):.2e}")

    # ---- 错误配对检查（旧 test_adjoint_correctness.m 的 bug）----
    RHS_wrong = (np.conj(E_vec) @ Js_exact.reshape(-1) +
                 np.conj(H_vec) @ Ms_exact.reshape(-1))
    ratio_wrong = LHS / RHS_wrong
    print(f"\n  [2b] 错误配对 <E,Js>+<H,Ms> ratio = {ratio_wrong:.6f}")
    print(f"       （如果 ≠ 1，证明配对方向写反了）")

    # ---- 当前代码版本（dOmega 权重，无 w(s)）----
    print("\n  [3] 当前代码版本 (dOmega 权重, coeff_base=1)...")
    Js_code, Ms_code = adjoint_CODE_VERSION(
        pos, norm, weight, k_dir, dOmega, Delta_J, k0, eta0, coeff_base=1.0)

    RHS_code = (np.conj(H_vec) @ Js_code.reshape(-1) +
                np.conj(E_vec) @ Ms_code.reshape(-1))
    ratio_code = LHS / RHS_code
    print(f"      ratio = {ratio_code:.15f}")
    print(f"      |ratio - 1| = {abs(ratio_code - 1):.2e}")

    # 检查 ratio 是否依赖表面位置（结构性错误标志）
    Js_exact_flat = Js_exact.reshape(-1)
    Ms_exact_flat = Ms_exact.reshape(-1)
    # 排除零点
    nonzero = np.abs(Js_exact_flat) > 1e-30
    if np.any(nonzero):
        per_point_ratio = (Js_code.reshape(-1)[nonzero] /
                           Js_exact_flat[nonzero])
        print(f"      Js_code/Js_exact per-point: "
              f"mean={np.mean(per_point_ratio):.4f}, "
              f"std={np.std(per_point_ratio):.4f}, "
              f"range=[{np.min(np.abs(per_point_ratio)):.4f}, "
              f"{np.max(np.abs(per_point_ratio)):.4f}]")

    # ---- 修正版本（w(s) 权重，无 dOmega）----
    print("\n  [4] 修正版本 (w(s) 权重, coeff_base=1)...")
    Js_fixed, Ms_fixed = adjoint_FIXED_VERSION(
        pos, norm, weight, k_dir, dOmega, Delta_J, k0, eta0, coeff_base=1.0)

    RHS_fixed = (np.conj(H_vec) @ Js_fixed.reshape(-1) +
                 np.conj(E_vec) @ Ms_fixed.reshape(-1))
    ratio_fixed = LHS / RHS_fixed
    print(f"      ratio = {ratio_fixed:.15f}")
    print(f"      |ratio - 1| = {abs(ratio_fixed - 1):.2e}")

    # ---- 汇总结论 ----
    print(f"\n  {'='*50}")
    print(f"  结论：")
    tol = 1e-10
    if abs(ratio_exact - 1) < tol:
        print(f"    [PASS] exact adjoint (|ratio-1| < 1e-10)")
    else:
        print(f"    [FAIL] exact adjoint (matrix build error)")
    
    if abs(ratio_code - 1) < tol:
        print(f"    [PASS] current code version")
    else:
        print(f"    [FAIL] current code version (ratio={ratio_code:.6e})")
    
    if abs(ratio_fixed - 1) < tol:
        print(f"    [PASS] fixed version")
    else:
        print(f"    [FAIL] fixed version (ratio={ratio_fixed:.6e})")
    print(f"  {'='*50}")

    return ratio_exact, ratio_code, ratio_fixed


if __name__ == '__main__':
    # 测试 1：小规模（可构建稠密矩阵验证）
    r1 = run_test(N_theta=6, N_phi=12, N_k=16,
                  label="(小规模 N_s=72, N_k=16)")

    # 测试 2：中等规模
    r2 = run_test(N_theta=12, N_phi=24, N_k=32,
                  label="(中等规模 N_s=288, N_k=32)")

    # 测试 3：接近实际管线规模（但避免过大矩阵）
    r3 = run_test(N_theta=24, N_phi=48, N_k=64,
                  label="(接近实际 N_s=1152, N_k=64)")

    print("\n\n" + "=" * 60)
    print("  最终汇总")
    print("=" * 60)
    labels = ["小规模", "中等规模", "接近实际"]
    results = [r1, r2, r3]
    for label, (re, rc, rf) in zip(labels, results):
        print(f"\n  {label}:")
        print(f"    exact   ratio = {re:.15f}  "
              f"{'PASS' if abs(re-1)<1e-10 else 'FAIL'}")
        print(f"    code    ratio = {rc:.6e}  "
              f"{'PASS' if abs(rc-1)<1e-10 else 'FAIL'}")
        print(f"    fixed   ratio = {rf:.15f}  "
              f"{'PASS' if abs(rf-1)<1e-10 else 'FAIL'}")
