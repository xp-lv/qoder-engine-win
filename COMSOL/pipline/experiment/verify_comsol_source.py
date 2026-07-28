#!/usr/bin/env python3
"""
COMSOL SurfaceCurrent / SurfaceMagneticCurrentDensity 物理约定验证

推导链：
1. Maxwell 频域方程（散射场公式）：
   ∇×μ_r⁻¹(∇×E_s) - k₀²(ε_r - jσ/ωε₀)E_s = -iωμ₀J_src + ∇×μ_r⁻¹M_src

   其中 J_src 是体积电流密度源 [A/m²]，M_src 是磁流密度源 [V/m²]

2. COMSOL 弱形式：
   ∫ μ_r⁻¹(∇×E_s)·(∇×w) - k₀²ε_r E_s·w dV
   = -∫ J_src·w dV + ∫ μ_r⁻¹ M_src·(∇×w) dV   (体积源)

   表面源通过分部积分自然出现：
   = -∫_S (Js0 × n̂)·(∇×w) dS  ... 不对，让我重新推导

3. 正确的弱形式源项映射（从 Stratton-Chu / Love-Schelkunoff）：

   表面电流 Js_surface = n̂ × H  （等效电流，单位 A/m）
   表面磁流 Ms_surface = -n̂ × E = E × n̂  （等效磁流，单位 V/m）

   COMSOL 中：
   - SurfaceCurrent (Js0)：弱形式贡献为 ∫_S Js0 · w dS（测试函数 w 直接点乘）
     其中 Js0 在 COMSOL 中定义为"表面电流密度"，物理意义是 J_s [A/m]
     
   - SurfaceMagneticCurrentDensity (Jms0)：弱形式贡献为 -∫_S Jms0 · (∇×w)/μ_r dS
     或等价地 ∫_S Jms0 × n̂ · ... 

   关键问题：COMSOL 的 Js0 是否等于物理 J_s = n̂×H？

   答案：COMSOL EMW 中 SurfaceCurrent 的 Js0 就是直接注入 Maxwell 方程的
   表面电流源项，它出现在方程右端：
     ∫_S Js0 · w dS
   这对应 Maxwell 方程中的 J_s。所以 Js0 = J_s = n̂ × H。

   但代码中的约定是 Js0 = -i*conj(Js)/(omega*mu0)，这有问题：
   - 物理量 J_s 应该直接等于 Js0，不需要 /(omega*mu0)
   - /(omega*mu0) 来自旧版 Born 体积电流的遗留

4. 推导正确的 Js0 和 Jms0：

   伴随源 = L^H * (dF/dJ_obs)
   其中 dF/dJ_obs(k) = -conj(Delta_J_perp(k)) / (N_k * 6 * N_freq)

   L^H 的输出 Js_raw 和 Ms_raw 已经是正确的伴随源（矩阵级验证通过）
   
   Js = coeff_base * w(s) * Js_raw  → 物理意义：表面电流 J_s
   Ms = coeff_base * w(s) * Ms_raw  → 物理意义：表面磁流 M_s

   COMSOL 源项：
     Js0_COMSOL = conj(Js) * (-i)   [代码中的约定：-real + i*imag → -i*conj]
     Jms0_COMSOL = conj(Ms) * (-i)  [同样的约定]

   物理上不需要 /(omega*mu0)！

5. 但隔离测试表明 Ms-only cos=0.921（正确），Js-only cos=0.047（错误）
   而两者用的是相同的 COMSOL 约定（-i*conj），唯一区别是 Js 有 /(omega*mu0) 而 Ms 没有

   这说明：
   a) Ms 的约定 -i*conj(Ms) 是正确的
   b) Js 的约定 -i*conj(Js)/(omega*mu0) 是错误的

   修正：Js 也应该用 -i*conj(Js)（去掉 omega*mu0）

6. 但 Round 2 去掉 omega*mu0 后 eps_r sign=-1, hole sign=+1（方向分裂）
   这说明 Js 本身的符号也需要翻转

   分析：Js_raw = n̂ × v_perp，而物理 J_s = n̂ × H
   在正向 lightcone_project 中 n̂×H 被用于积分核
   但在伴随中 Js_raw = n̂ × (v_perp) 也是 n̂ 在前

   COMSOL SurfaceCurrent 的 Js0 是直接加到方程右端的 J_s 项
   正向核 K_J = (I - k̂k̂ᵀ)(n̂×) 作用于 H
   伴随核 K_J^T·v = n̂ × (v - k̂(k̂·v))

   关键：COMSOL 求解的 E_s 由 J_s 驱动
   E_s 满足 ∇×∇×E_s - k₀²εE_s = iωμ₀J_s（在散射场公式中，背景场为零时）

   所以 J_s → E_s 的传递函数是 iωμ₀ 的倒数
   即 E_s = G * iωμ₀ * J_s

   这意味着如果要产生特定的 lambda 场，J_s 应该 = lambda_target / (iωμ₀)
   所以 Js0 = Js / (iωμ₀) = -i*Js / (ωμ₀)... 这就是原始 /(omega*mu0) 的物理来源！

   但隔离测试说 Js-only cos=0.047...

   让我重新检查：COMSOL 的 SurfaceCurrent Js0 到底是什么？
   在 COMSOL EMW 中：
   - ExternalCurrentDensity (vec1)：Je 是体积电流密度 J [A/m²]
     弱形式：∫ J·w dV → Maxwell: ∇×∇×E - k₀²εE = iωμ₀J
   - SurfaceCurrent (sc_adj)：Js0 是表面电流密度 [A/m]
     弱形式：∫_S Js0·w dS → 相当于体积源的表面极限

   代码中的 Js0 表达式：(-int_sc_im + i*int_sc_re) / (omega*mu0)
   这等于 (-i*conj(Js)) / (omega*mu0)
   = conj(Js) * (-i/(omega*mu0))
   = conj(Js) * (-i/(omega*mu0))

   而物理上需要 Js0 = J_s = n̂×H_s_adj
   伴随源 Js 已经包含了正确的物理量

   所以 Js0 应该直接等于 conj(Js)（含 -i 共轭约定），不需要 /(omega*mu0)

   但 Ms 路径没有 /(omega*mu0)，且 cos=0.921（正确）
   Js 路径有 /(omega*mu0)，且 cos=0.047（错误）

   结论：去掉 /(omega*mu0) 是对的，但需要同时翻转 Js 符号

   为什么翻转符号？因为：
   - 正向核 K_J·H = (I-k̂k̂ᵀ)(n̂×H) = k̂(k̂·(n̂×H)) - (n̂×H)
   - 伴随核 K_J^T·v = n̂×(v_perp) = n̂×(v - k̂(k̂·v))
   - 但 COMSOL SurfaceCurrent 产生的是 ∇×(Js0) 类型的场
     而 Maxwell 方程中 ∇×H = J_s + iωεE → J_s = ∇×H - iωεE
     即 J_s 对应 n̂×H_t（切向 H 的叉积）

   正向光锥投影中 n̂×H 是"从 H 提取切向信息"
   伴随中 n̂×v_perp 是"把 v 的残差投射回 H 空间"
   
   但 COMSOL SurfaceCurrent Js0 是加到 ∇×E 方程的源项
   J_s 的物理意义导致 E_s 的方向可能差一个叉乘符号

   让我用数值验证确认正确的符号和缩放
"""

import numpy as np

def fibonacci_sphere(N):
    pts = np.zeros((N, 3)); g = np.pi*(3-np.sqrt(5))
    for i in range(1, N+1):
        y = 1-(i-0.5)*2/N; r = np.sqrt(1-y**2); th = g*(i-1)
        pts[i-1] = [np.cos(th)*r, np.sin(th)*r, y]
    return pts, (4*np.pi/N)*np.ones(N)

def build_grid(R, Nt, Np):
    tv = np.linspace(0, np.pi, Nt+1); tv = tv[:-1]+np.diff(tv)/2
    pv = np.linspace(0, 2*np.pi, Np+1); pv = pv[:-1]+np.diff(pv)/2
    dt, dp = np.pi/Nt, 2*np.pi/Np
    pos=[]; nrm=[]; wt=[]
    for t in tv:
        for p in pv:
            pos.append([R*np.sin(t)*np.cos(p), R*np.sin(t)*np.sin(p), R*np.cos(t)])
            nrm.append([np.sin(t)*np.cos(p), np.sin(t)*np.sin(p), np.cos(t)])
            wt.append(R**2*np.sin(t)*dt*dp)
    return np.array(pos), np.array(nrm), np.array(wt)

# 物理参数
R=0.26; c=299792458; freq=1e9; omega=2*np.pi*freq; k0=omega/c
eps0=8.854187817e-12; mu0=4*np.pi*1e-7; eta0=np.sqrt(mu0/eps0)
N_theta, N_phi, N_k = 6, 12, 16
pos, nrm, wt = build_grid(R, N_theta, N_phi)
k_dir, dOmega = fibonacci_sphere(N_k)
N_s = len(pos)

# 构建正向矩阵 M_E, M_H
M_E = np.zeros((3*N_k, 3*N_s), dtype=complex)
M_H = np.zeros((3*N_k, 3*N_s), dtype=complex)
I3 = np.eye(3)
for i in range(N_k):
    ki = k_dir[i]
    for s in range(N_s):
        ns = nrm[s]; ph = np.exp(-1j*k0*np.dot(ki, pos[s])); wp = wt[s]*ph
        nc = np.array([[0,-ns[2],ns[1]],[ns[2],0,-ns[0]],[-ns[1],ns[0],0]])
        M_H[3*i:3*i+3, 3*s:3*s+3] = wp*(np.outer(ki,ki)-I3)@nc
        ndk = np.dot(ns,ki)
        M_E[3*i:3*i+3, 3*s:3*s+3] = wp*(np.outer(ns,ki)-ndk*I3)/eta0

# ============================================================
# 核心推导：COMSOL 源项到 lambda 的传递函数
# ============================================================
print("=" * 65)
print("  COMSOL 源项物理约定推导")
print("=" * 65)

print("""
Scattered-field Maxwell eq (bg=0):
  curl(mu_r^-1 curl E_s) - k0^2 eps_r E_s = -i*w*mu0*J_src

Weak form (test func w):
  int mu_r^-1(curl E_s).(curl w) dV - int k0^2 eps_r E_s.w dV
  = -i*w*mu0 * int J_src.w dV     (volume source)

SurfaceCurrent Js0:
  weak form contribution = int_S Js0.w dS
  equiv. to J_src = Js0*delta(n) at surface

SurfaceMagneticCurrentDensity Jms0:
  Maxwell: curl(E) = -i*w*mu0*H - M_src
  weak form: -int_S Jms0.w dS (note minus!)

Lambda vs source:
  lambda = G * source_term
  G = Maxwell Green function

  Js0: source = -i*w*mu0 * Js0
  Jms0: source = -Jms0
""")

# ============================================================
# 验证：不同的 COMSOL 源项约定对 lambda 的影响
# ============================================================
# 用随机数据测试 4 种约定

rng = np.random.default_rng(42)
E_surf = rng.standard_normal((N_s,3)) + 1j*rng.standard_normal((N_s,3))
H_surf = rng.standard_normal((N_s,3)) + 1j*rng.standard_normal((N_s,3))
dJ = rng.standard_normal((N_k,3)) + 1j*rng.standard_normal((N_k,3))
E_vec = E_surf.reshape(-1); H_vec = H_surf.reshape(-1); dJ_vec = dJ.reshape(-1)

# 精确伴随源（L^H · dJ）
Js_exact = (M_H.conj().T @ dJ_vec).reshape(N_s, 3)  # 对应 H 变分
Ms_exact = (M_E.conj().T @ dJ_vec).reshape(N_s, 3)  # 对应 E 变分

# J_s 和 M_s 的物理量（Love/Schelkunoff 等效定理）
# 正向：J_obs(k) = ∫ [K_H·(n̂×H) + K_E·E/η₀] e^{-ikr} w dS
# 其中 n̂×H 是物理表面电流 J_s = n̂×H
# E 对应物理表面磁流 M_s = -n̂×E = E×n̂

# 注意正向核中：
# K_H 作用于 (n̂×H)，即 M_H 矩阵已含 (n̂×) 算子
# K_E 作用于 E，即 M_E 矩阵含 E 的直接项

# 伴随核的输出：
# Js_exact 对应 L^H 作用于 dJ，映射回 H 空间 → Js_exact 是"伴随表面电流"
# Ms_exact 对应 L^H 作用于 dJ，映射回 E 空间 → Ms_exact 是"伴随表面磁流"

# COMSOL 中 SurfaceCurrent 的 Js0 和 SurfaceMagneticCurrentDensity 的 Jms0：
# 代码约定：Js0 = (-int_sc_im + i*int_sc_re) = -i * conj(Js) / scaling
# 其中 scaling = omega*mu0（旧版）或 1（新版）

print("=" * 65)
print("  Js 和 Ms 的物理量验证")
print("=" * 65)

# 验证 1：Js_exact 与物理表面电流 n̂×H 的关系
# 正向 M_H · H = sum_s w(s) * phase * (k̂k̂ᵀ-I)(n̂×) · H
# 伴随 M_H^H · dJ 中，(n̂×) 的转置是 -(n̂×)（因为叉乘矩阵的转置 = 负叉乘矩阵）
n_cross = np.zeros((3,3))
# 叉乘矩阵 [n̂×] 的转置 = -[n̂×]，因为 n̂×是反对称矩阵

# 验证叉乘矩阵的反对称性
for s in range(3):  # 测试前 3 个表面点
    ns = nrm[s]
    nc = np.array([[0,-ns[2],ns[1]],[ns[2],0,-ns[0]],[-ns[1],ns[0],0]])
    # 验证 nc^T = -nc
    asym_err = np.max(np.abs(nc.T + nc))
    if s == 0:
        print(f"  Cross matrix [nx] antisymmetry: |nc^T + nc|_max = {asym_err:.2e}")
        print(f"  -> [nx]^T = -[nx] (antisymmetric)")

print(f"\n  So (nx)^H = -(nx)")
print(f"  Forward M_H contains (kk-I)(nx)")
print(f"  Adjoint M_H^H contains (nx)^H(kk-I)^H = -(nx)(kk-I)")
print(f"  But (nx)(kk-I) != (kk-I)(nx) (non-commuting)")

# 关键验证：M_H^H 作用于 dJ 是否等于 n̂ × (v_perp)？
# 代码中 K_J^T·v = n̂ × (v - k̂(k̂·v)) = n̂ × v_perp
# 而 M_H^H·dJ 的实际值应该 = w(s) * sum_k conj(phase) * [n̂×]^H * (k̂k̂ᵀ-I) * dJ
# = w(s) * sum_k conj(phase) * [-(n̂×)] * (k̂k̂ᵀ-I) * dJ  ... 不对

# 让我直接检查 M_H 的子块结构
print(f"\n{'='*65}")
print("  M_H subblock check (k=0, surface=0)")
print(f"{'='*65}")

i, s = 0, 0
ki, ns = k_dir[i], nrm[s]
nc = np.array([[0,-ns[2],ns[1]],[ns[2],0,-ns[0]],[-ns[1],ns[0],0]])
sub_H = (np.outer(ki,ki)-I3) @ nc  # M_H 的 3×3 子块

print(f"  k_hat = [{ki[0]:.4f}, {ki[1]:.4f}, {ki[2]:.4f}]")
print(f"  n_hat = [{ns[0]:.4f}, {ns[1]:.4f}, {ns[2]:.4f}]")
print(f"\n  M_H subblock (kk-I)(nx) =")
for row in range(3):
    print(f"    [{sub_H[row,0]:+.6f}, {sub_H[row,1]:+.6f}, {sub_H[row,2]:+.6f}]")

# 伴随子块 = M_H^H 的对应块 = conj(M_H)^T = conj(sub_H)^T
# 但 M_H 含相位 exp(-ikr)，所以 M_H^H 的子块 = conj(wp) * conj(sub_H)^T
# 因为 wp = w*exp(-ikr)，conj(wp) = w*exp(+ikr)
sub_H_adj = sub_H.conj().T  # sub_H 是实矩阵，所以 sub_H_adj = sub_H.T
print(f"\n  Adjoint subblock conj(sub_H)^T = sub_H^T =")
for row in range(3):
    print(f"    [{sub_H_adj[row,0]:+.6f}, {sub_H_adj[row,1]:+.6f}, {sub_H_adj[row,2]:+.6f}]")

# 代码中的 K_J^T·v = n̂ × (v - k̂(k̂·v)) = n̂ × v_perp
# 验证：sub_H.T · v 是否等于 n̂ × v_perp？
v_test = np.array([0.5, 0.3, 0.8])
# M_H^H · v（矩阵级）
mh_adj_v = sub_H.T @ v_test
# 代码中的 K_J^T·v = n̂ × (v - k̂(k̂·v))
kdv = np.dot(ki, v_test)
v_perp = v_test - ki * kdv
kj_adj_v = np.cross(ns, v_perp)

print(f"\n  Test vec v = {v_test}")
print(f"  M_H^H.v = sub_H^T.v       = [{mh_adj_v[0]:+.6f}, {mh_adj_v[1]:+.6f}, {mh_adj_v[2]:+.6f}]")
print(f"  K_J^T.v = nx(v_perp)      = [{kj_adj_v[0]:+.6f}, {kj_adj_v[1]:+.6f}, {kj_adj_v[2]:+.6f}]")
print(f"  Match? {np.allclose(mh_adj_v, kj_adj_v)}")

if not np.allclose(mh_adj_v, kj_adj_v):
    print(f"\n  *** KEY: M_H^H.v != nx(v_perp)! ***")
    print(f"  diff = M_H^H.v - nx(v_perp) = [{(mh_adj_v-kj_adj_v)[0]:+.6f}, ...]")
    
    # 尝试 n̂×v_perp 的负值
    print(f"\n  Check -nx(v_perp) = [{-kj_adj_v[0]:+.6f}, {-kj_adj_v[1]:+.6f}, {-kj_adj_v[2]:+.6f}]")
    print(f"  M_H^H.v == -nx(v_perp)? {np.allclose(mh_adj_v, -kj_adj_v)}")
    
    # 尝试 v_perp × n̂
    vpxn = np.cross(v_perp, ns)
    print(f"\n  Check v_perp x n = [{vpxn[0]:+.6f}, {vpxn[1]:+.6f}, {vpxn[2]:+.6f}]")
    print(f"  M_H^H.v == v_perp x n? {np.allclose(mh_adj_v, vpxn)}")
    
    # 直接从 M_H 结构推导正确的伴随核
    # M_H 子块 = (k̂k̂ᵀ-I)(n̂×)
    # M_H^H 子块 = [(n̂×)]^H (k̂k̂ᵀ-I)^H = -(n̂×)(k̂k̂ᵀ-I)
    # 因为 (n̂×)^T = -(n̂×) 且 (k̂k̂ᵀ-I)^T = (k̂k̂ᵀ-I)（对称）
    correct_adj = -nc @ (np.outer(ki,ki) - I3)
    correct_adj_v = correct_adj @ v_test
    print(f"\n  Correct adjoint -(nx)(kk-I).v = [{correct_adj_v[0]:+.6f}, ...]")
    print(f"  M_H^H.v == -(nx)(kk-I).v? {np.allclose(mh_adj_v, correct_adj_v)}")
    
    # 展开 -(n̂×)(k̂k̂ᵀ-I)·v = -(n̂×)(k̂(k̂·v) - v) = -(n̂×k̂)(k̂·v) + (n̂×v)
    # = (n̂×v) - (k̂·v)(n̂×k̂)
    expanded_v = np.cross(ns, v_test) - kdv * np.cross(ns, ki)
    print(f"\n  Expand (nx v) - (k.v)(nx k) = [{expanded_v[0]:+.6f}, ...]")
    print(f"  Match? {np.allclose(mh_adj_v, expanded_v)}")
    
    print(f"\n  *** Correct adjoint K_J^T.v = (nx v) - (k.v)(nx k) ***")
    print(f"    code has: nx(v - k(k.v)) = nx(v) - (k.v)(nx k)")
    print(f"    Wait... n̂×v_perp = n̂×(v-k̂(k̂·v)) = n̂×v - (k̂·v)(n̂×k̂)")
    paradox = np.cross(ns, v_perp) - (np.cross(ns, v_test) - kdv*np.cross(ns, ki))
    print(f"    paradox = nx(v_perp) - [(nx v)-(k.v)(nx k)] = {np.max(np.abs(paradox)):.2e}")
    if np.max(np.abs(paradox)) < 1e-14:
        print(f"    -> Identity! nx(v_perp) = (nx v)-(k.v)(nx k) = correct adjoint")
        print(f"    -> Then why M_H^H.v != nx(v_perp)?")
        print(f"    M_H^H·v     = [{mh_adj_v[0]:+.6f}, {mh_adj_v[1]:+.6f}, {mh_adj_v[2]:+.6f}]")
        print(f"    n̂×v_perp    = [{kj_adj_v[0]:+.6f}, {kj_adj_v[1]:+.6f}, {kj_adj_v[2]:+.6f}]")
        print(f"    -(n̂×)(k̂k̂ᵀ-I)·v = [{correct_adj_v[0]:+.6f}, {correct_adj_v[1]:+.6f}, {correct_adj_v[2]:+.6f}]")
        print(f"    diff = M_H^H.v - correct = {(mh_adj_v - correct_adj_v)}")
        # 看看差值是否就是 (n̂×)^T 的符号问题
        ratio_check = mh_adj_v / kj_adj_v
        print(f"    比值 M_H^H·v / n̂×v_perp = {ratio_check}")

# ============================================================
# 全面检查：所有 (i,s) 对
# ============================================================
print(f"\n{'='*65}")
print("  Full check M_H^H.v vs nx(v_perp) (all k, surface pairs)")
print(f"{'='*65}")

rng2 = np.random.default_rng(99)
v_rand = rng2.standard_normal(3) + 1j*rng2.standard_normal(3)
max_err = 0
sign_flip_count = 0
total_count = 0
for i in range(N_k):
    ki = k_dir[i]
    for s in range(N_s):
        ns = nrm[s]
        nc = np.array([[0,-ns[2],ns[1]],[ns[2],0,-ns[0]],[-ns[1],ns[0],0]])
        sub_H = (np.outer(ki,ki)-I3) @ nc
        mh_v = sub_H.T @ v_rand  # 伴随（实矩阵，T = H）
        
        kdv = np.dot(ki, v_rand)
        v_perp = v_rand - ki*kdv
        kj_v = np.cross(ns, v_perp)
        
        err = np.max(np.abs(mh_v - kj_v))
        max_err = max(max_err, err)
        total_count += 1
        
        # 检查是否是精确反号
        if np.allclose(mh_v, -kj_v, atol=1e-10):
            sign_flip_count += 1

print(f"  Total {total_count} (k,s) pairs")
print(f"  Max error |M_H^H.v - nx(v_perp)|_max = {max_err:.6e}")
print(f"  Exact sign flip (M_H^H.v ~= -nx(v_perp)) count = {sign_flip_count}")

if sign_flip_count == total_count:
    print(f"\n  *** ALL SIGN FLIPPED! Correct adjoint = -nx(v_perp) ***")
    print(f"  i.e. K_J^T.v = -(n x v_perp) = v_perp x n")
elif max_err < 1e-10:
    print(f"\n  完全一致，代码核正确")
else:
    # 检查是否部分一致部分反号
    # 用矩阵范数
    diff_norm = np.linalg.norm(mh_v - kj_v)
    sum_norm = np.linalg.norm(mh_v) + np.linalg.norm(kj_v)
    print(f"  相对差异 = {diff_norm/sum_norm:.6f}")
    
    # 直接检查 sub_H.T vs -nc@(kk-I) 
    ns = nrm[0]; ki = k_dir[0]
    nc = np.array([[0,-ns[2],ns[1]],[ns[2],0,-ns[0]],[-ns[1],ns[0],0]])
    sub_H = (np.outer(ki,ki)-I3) @ nc
    correct = -nc @ (np.outer(ki,ki)-I3)
    print(f"\n  sub_H.T (代码用) vs -nc@(kk-I) (理论正确):")
    print(f"    sub_H^T = ")
    for r in range(3): print(f"      [{sub_H.T[r,0]:+.6f}, {sub_H.T[r,1]:+.6f}, {sub_H.T[r,2]:+.6f}]")
    print(f"    -nc@(kk-I) = ")
    for r in range(3): print(f"      [{correct[r,0]:+.6f}, {correct[r,1]:+.6f}, {correct[r,2]:+.6f}]")
    print(f"    一致？{np.allclose(sub_H.T, correct)}")
