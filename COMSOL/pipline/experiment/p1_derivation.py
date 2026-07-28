#!/usr/bin/env python3
"""
P1: 三维投影一致性的精确推导

问题: F = sum_k sum_d |dJ(k,d)|^2
     |dJ(k,d)|^2 = conj(dJ(k,d)) * dJ(k,d)

这是 Hermitian 形式。伴随推导用普通转置（K 复对称）。

关键推导:
  F = sum_k sum_d conj(dJ_kd) * dJ_kd
  dJ_kd = J_truth_kd - J_hyp_kd
  J_hyp_kd = (L * e_s)_kd  (正向线性算子)

  dF/de_s = sum_k sum_d [conj(d(dJ_kd)/de_s) * dJ_kd + conj(dJ_kd) * d(dJ_kd)/de_s]
           = sum_k sum_d [-conj(dL_kd/de_s) * dJ_kd - conj(dJ_kd) * dL_kd/de_s]

  = -sum_k sum_d [conj(dL_kd/de_s) * dJ_kd + conj(dJ_kd) * dL_kd/de_s]

  第一项: conj(dL_kd/de_s) * dJ_kd
    = (dL_kd/de_s)^* * dJ_kd
    
  第二项: conj(dJ_kd) * dL_kd/de_s
    = (dJ_kd)^* * dL_kd/de_s

对于实值目标函数 F, dF/de_s 必须是实数（或可以取实部）。

利用 F 实值 -> dF = conj(dF):
  dF = -sum [conj(dL/de_s)*dJ + conj(dJ)*dL/de_s]
  conj(dF) = -sum [dL/de_s*conj(dJ) + dJ*conj(dL/de_s)]
  dF = conj(dF) 意味着两者相等（对称性验证 OK）

关键是: dF/de_s 包含两项，它们是复共轭对。
  dF/de_s = -2 * Re[ sum_k sum_d conj(dJ_kd) * dL_kd/de_s ]

所以 dF/de_s = -2 * Re[ sum_k conj(dJ_kd) * (dL_kd/de_s) ]

这就是 Hermitian 形式!

然后 lambda = K^{-1} * dF/de_s（复对称 K）:
  lambda 满足 K*lambda = dF/de_s

但 dF/de_s 是实数（Re[...] 取了实部）！
这意味着 lambda 的源项是实数。

而 K 是复对称的（含虚部）。
K * lambda = real_source 意味着 lambda 是复数。

最终梯度:
  dF/deps_v = lambda^T * d(K*e_s)/deps_v ... 

不对，让我更仔细地推导。

实际上，对于 |dJ|^2 类型的目标函数:

  F = sum_kd conj(dJ_kd) * dJ_kd
  
  dF = sum_kd conj(d(dJ_kd)) * dJ_kd + conj(dJ_kd) * d(dJ_kd)
     = -sum_kd [conj(dJ_kd) * (dL*de_s) + conj(dL*de_s) * dJ_kd] ... 
     
等一下，这里 (dL/de_s) 是一个线性算子（矩阵），不是一个标量。
让我用矩阵符号。

e_s: 3N_v x 1 向量（体素场）
J_hyp: 3N_k x 1 向量（展开 k 和 d）
L: 3N_k x 3N_v 矩阵

J_hyp = L * e_s
dJ = J_truth - J_hyp = J_truth - L*e_s

F = conj(dJ)^T * dJ = dJ^H * dJ  (Hermitian 模平方)

dF = d(dJ^H) * dJ + dJ^H * d(dJ)
   = -(d(L*e_s))^H * dJ - dJ^H * d(L*e_s)
   = -(de_s)^H * L^H * dJ - dJ^H * L * de_s
   = -conj(de_s)^T * conj(L)^T * dJ - conj(dJ)^T * conj(L) * de_s
   = -conj(de_s)^T * conj(L)^T * dJ - conj(dJ^T * conj(L)) * de_s ... 

太乱了。用标准矩阵微积分:

F = (J_truth - L*e)^H (J_truth - L*e)
  = J_truth^H J_truth - J_truth^H L e - (L e)^H J_truth + (L e)^H (L e)

dF/de = -J_truth^H L - ... 这个是 Wirtinger 导数。

实际上，对于复变量，标准做法是:
  dF/de = (dF/de*)^* (共轭 Wirtinger)

dF/de* = -(J_truth - Le) = -dJ ... 不对。

标准结果: 对 F = ||y - Ax||^2,
  dF/dx = -2 * Re[A^H (y - Ax)]  (对实数 x)
  
但如果 x 是复数:
  dF/dx* = -A^H (y - Ax) = A^H dJ  (Wirtinger)
  dF/dx = -(A^H dJ)^* ... hmm

实际上对于 F = dJ^H dJ，其中 dJ = J_truth - L*e_s:

  dF/de_s^* = L^H * dJ  (Wirtinger 导数)

  因为 F = dJ^H dJ = (J_truth - L e_s)^H (J_truth - L e_s)
  dF/d(e_s^*) = (J_truth - L e_s)^H * (-L) ... 不对

正确: 对 F = ||dJ||^2, dJ = J_truth - L*e_s
  F = dJ^H dJ
  dF = d(dJ^H) dJ + dJ^H d(dJ)
  d(dJ) = -L de_s
  d(dJ^H) = -de_s^H L^H = -(de_s)^*T L^H

  dF = -(de_s)^*T L^H dJ - dJ^H L de_s

  提取 dF/de_s* (Wirtinger):
  dF = ... 两项中 de_s 的共轭部分:
  dF = -conj(de_s)^T (L^H dJ) - (L^T conj(dJ))^T de_s
  
  对实值 F: dF/d(e_s^*) = -L^H dJ  ... hmm

让我换一种方式。用 L^H (Hermitian adjoint):

  dF/de_s = -2 * Re[L^H dJ]  (如果 e_s 是复数)
  
  但 K 复对称意味着 K^{-1} = K^{-T} (不是 K^{-H})
  
  lambda = K^{-1} * (-2 Re[L^H dJ]) ... 这有问题

关键洞察: L^H dJ vs L^T conj(dJ) vs L^T dJ
"""

import numpy as np

print("=" * 70)
print("  P1: 三维投影一致性 - 精确推导")
print("=" * 70)

print("""
F = ||dJ||^2 = sum_kd conj(dJ_kd) * dJ_kd

dJ = J_truth - L*e_s  (L 是线性算子, e_s 是散射场)

dF/de_s 的 Wirtinger 形式:
  dF/de_s* = L^H * dJ    (Hermitian adjoint!)

其中 L^H = conj(L)^T

而 K 复对称 -> lambda 满足:
  K * lambda = source
  source 应该来自 dF/de_s

但 dF/de_s* = L^H dJ 使用的是 Hermitian 转置。
而 K^{-1} 是复对称逆 -> lambda 的推导用普通转置。

矛盾在于:
  F 的梯度对 e_s* 用 L^H (Hermitian)
  但 K 的伴随用 K^T = K (普通转置)

解决方案:
  lambda = K^{-1} * L^H * dJ   (用 L^H，不是 L^T)
  
  然后: dF/deps = lambda^T * d(K e_s)/deps

  注意: lambda^T 是普通转置（因为 K 复对称）
  但 lambda 本身通过 L^H 构造（Hermitian）

这意味着 build_adjoint_source 中应该用 L^H 而非 L^T！

当前代码的 build_adjoint_source 用的是:
  Js_raw = sum_k K_J^T * v
  其中 K_J^T = n x v_perp (普通转置核)

正确的应该是:
  Js_raw = sum_k K_J^H * v = sum_k conj(K_J)^T * v = sum_k conj(K_J^T) * v
  = conj(n x v_perp) = n x conj(v_perp)

因为核 K_J 是实算子 (n, k 都是实向量):
  K_J = (I - kk^T)(nx)  -> 实矩阵
  K_J^H = conj(K_J)^T = K_J^T (实矩阵的 Hermitian = 转置)

所以对实核 L^H = L^T，没有区别！

这说明对当前的实核，三维投影一致性不是问题。

那 CV=0.27 的根因到底是什么？

回到目标函数:
  F = sum_kd |dJ_kd|^2 = sum_kd conj(dJ_kd) * dJ_kd

  dJ_kd = J_truth_kd - (L * e_s)_kd

  dF/de_s_v = sum_kd [conj(dJ_kd) * (-L_kdv) + (-conj(L_kdv)) * dJ_kd]
             = -2 * Re[ sum_kd conj(dJ_kd) * L_kdv ]

  这里 L_kdv 是复数（因为含 exp(-ikr) 相位）！

  所以 dF/de_s_v = -2 * Re[ sum_kd conj(dJ_kd) * L_kdv ]

  = -2 * Re[ (L^H dJ)_v ]   <- Hermitian!

  然后 lambda = K^{-1} * dF/de_s = K^{-1} * (-2 Re[L^H dJ])

  但 K^{-1} 作用于一个实向量会给出复数 lambda（因为 K 是复矩阵）。

  最终梯度:
  dF/deps_v = lambda^T * (d(K e_s)/deps_v)
  
  d(K e_s)/deps_v = -k0^2 * e_s_v * dV (复数！)

  所以 dF/deps_v = lambda^T * (-k0^2 * e_s_v * dV)
                 = -k0^2 * dV * sum_d lambda_{vd} * e_s_{vd}
                 = -k0^2 * dV * (lambda · e_s)  (bilinear, 普通乘积)

  这是正确的！

  但 lambda = K^{-1} * (-2 Re[L^H dJ])
  
  源项 S = -2 Re[L^H dJ] 是实数。

  当前代码中:
  - build_adjoint_source 输出 L^T * dJ (含 conj 相位)
  - solve_adjoint 把它作为 Je = -i*conj(f_adj)/(omega*mu0) 注入
  - 最终 lambda 源项 = -i*conj(coeff_base * w * L^T * dJ) / (omega*mu0)

  而正确源项应该是 -2*Re[L^H dJ]
  = -2*Re[conj(L)^T * dJ]

  如果 L 是实核（不含相位），L^H = L^T，则:
  正确源项 = -2*Re[L^T * dJ]

  但 L 含复数相位 exp(-ikr)！
  L^H = conj(L)^T = (exp(+ikr) * real_kernel)^T

  当前代码用 L^T = (exp(-ikr) * real_kernel)^T

  差异: exp(+ikr) vs exp(-ikr)

  这就是 conj(Delta_J) vs Delta_J 的差异！

  正确源项应该用 conj(Delta_J)，因为:
  L^H * dJ = conj(L)^T * dJ = sum_k conj(L_kernel) * exp(+ikr) * dJ
           = L_kernel * exp(+ikr) * dJ   (kernel 是实的)

  而当前代码用:
  L^T * dJ = L_kernel * exp(-ikr) * dJ  (相位反号)

  要修正: 把 dJ 替换为 conj(dJ)？不对。
  L^H dJ = conj(L)^T dJ
  当前用 L^T dJ = L^T dJ

  conj(L)^T ≠ L^T (因为 L 含复数相位)

  正确做法: 用 conj(dJ) 替代 dJ，然后 L^T * conj(dJ) = conj(conj(L)^T * dJ) ... 不对

  让我直接检查:
  L_{kd, sv} = w(s) * exp(-ik*r_s) * kernel(kd, sv)
  L^H_{sv, kd} = conj(L_{kd, sv}) = w(s) * exp(+ik*r_s) * kernel(sv, kd)

  L^H * dJ 的 v 分量:
  (L^H * dJ)_v = sum_kd L^H_{vd, kd} * dJ_kd
               = sum_kd w(v) * exp(+ik*r_v) * kernel(vd, kd) * dJ_kd

  当前代码的 L^T * dJ:
  (L^T * dJ)_v = sum_kd L_{kd, vd} * dJ_kd
               = sum_kd w(v) * exp(-ik*r_v) * kernel(kd, vd) * dJ_kd

  注意 kernel(kd, vd) = transpose of kernel(vd, kd)
  
  差异是 exp(+ikr) vs exp(-ikr)

  所以正确源项需要 conj 相位！

  修正: 在 build_adjoint_source 中，把 conj(Delta_J) 作为输入
  而非 Delta_J！
""")

# 数值验证
def fibonacci_sphere(N):
    pts = np.zeros((N, 3)); g = np.pi*(3-np.sqrt(5))
    for i in range(1, N+1):
        y = 1-(i-0.5)*2/N; r = np.sqrt(1-y**2); th = g*(i-1)
        pts[i-1] = [np.cos(th)*r, np.sin(th)*r, y]
    return pts

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

c=299792458; freq=1e9; omega=2*np.pi*freq; k0=omega/c
eps0=8.854187817e-12; mu0=4*np.pi*1e-7; eta0=np.sqrt(mu0/eps0)
pos, nrm, wt = build_grid(0.26, 6, 12)
kd = fibonacci_sphere(16)
Ns=len(pos); Nk=len(kd); I3=np.eye(3)

# Build L matrix (3Nk x 3Ns)
L = np.zeros((3*Nk, 3*Ns), dtype=complex)
for i in range(Nk):
    ki = kd[i]
    for s in range(Ns):
        ns = nrm[s]; ph = np.exp(-1j*k0*np.dot(ki, pos[s])); wp = wt[s]*ph
        nc = np.array([[0,-ns[2],ns[1]],[ns[2],0,-ns[0]],[-ns[1],ns[0],0]])
        # M_H: (kk-I)(nx)
        L[3*i:3*i+3, 3*s:3*s+3] += wp*(np.outer(ki,ki)-I3)@nc
        # M_E: (nk-nkI)/eta0
        ndk = np.dot(ns,ki)
        L[3*i:3*i+3, 3*s:3*s+3] += wp*(np.outer(ns,ki)-ndk*I3)/eta0

# Random test
rng = np.random.default_rng(42)
e_s = rng.standard_normal(3*Ns) + 1j*rng.standard_normal(3*Ns)
dJ = rng.standard_normal(3*Nk) + 1j*rng.standard_normal(3*Nk)

# Correct source: L^H * dJ
S_correct = L.conj().T @ dJ  # Hermitian adjoint

# Current code: L^T * dJ  
S_current = L.T @ dJ

# Check: is conj(S_current) == S_correct?
ratio = S_correct / np.conj(S_current)
print(f"\nL^H*dJ / conj(L^T*dJ): mean ratio = {np.mean(np.abs(ratio)):.15f}")
print(f"  max deviation = {np.max(np.abs(ratio - 1)):.2e}")

# Check: L^H * dJ = conj(L^T * conj(dJ))
S_test = np.conj(L.T @ np.conj(dJ))
print(f"\nL^H*dJ vs conj(L^T*conj(dJ)): match = {np.allclose(S_correct, S_test)}")

# The KEY: correct source uses conj(dJ) in L^T
S_fixed = L.T @ np.conj(dJ)
print(f"\nL^T*conj(dJ) vs L^H*dJ: match = {np.allclose(np.conj(S_fixed), S_correct)}")
# Actually L^H*dJ = conj(L)^T*dJ = conj(L^T * conj(dJ))
# So conj(L^T * conj(dJ)) = L^H * dJ ... wait
# L^H = conj(L)^T
# L^H * dJ = conj(L)^T * dJ
# conj(L^T * conj(dJ)) = conj(L^T) * dJ = conj(L)^T * dJ = L^H * dJ ✓
print(f"\n结论: L^H*dJ = conj(L^T * conj(dJ))")
print(f"  所以正确做法是: build_adjoint_source 中用 conj(Delta_J) 作为输入")
print(f"  然后 lambda 源项 = Re[coeff * L^T * conj(dJ)]")
print(f"  = Re[coeff * conj(L^H * dJ)]")
