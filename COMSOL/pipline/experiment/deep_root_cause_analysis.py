#!/usr/bin/env python3
"""
从第一性原理完整推导伴随梯度链，定位 CV=0.66 的根因。

推导链：
1. COMSOL 正向: K·e = f  (K 复对称)
2. 观测算子: J_obs = L(e)  (线性)
3. 目标函数: F = mean_k |Delta_J(k)|^2 / (|J_obs(k)|^2 * 6)
4. 梯度: dF/deps_v = ?

关键问题：F 是 J_obs 的函数，J_obs 是 e 的函数，e 是 deps 的函数。
完整链式法则需要无遗漏。
"""

import numpy as np

print("=" * 70)
print("  从第一性原理推导完整梯度链")
print("=" * 70)

print("""
STEP 1: 正向链
================
COMSOL 散射场公式: K·e_s = f_contrast
  e_s = 散射场 (COMSOL 变量 emw.relE)
  f_contrast = k0^2 * (eps_r - eps_bg) * E_bg  (对比度源)
  K = curl(mu_r^-1 curl) - k0^2 eps_r  (复对称)

注意: COMSOL 求解的变量是 e_s (散射场)。
总场 E_total = E_bg + e_s。

STEP 2: 观测算子 L
===================
extract_scattered 从测量球面提取 E_s, H_s (散射场):
  E_s_surf = emw.relE (球面上的散射场)
  H_s_surf = emw.relH (球面上的散射场 H)

lightcone_project 计算 J_obs:
  J_obs(k) = int_S [K_H * (n x H_s) + K_E * E_s / eta0] * exp(-ikr) * w(s) dS

这是散射场 E_s 和 H_s 的线性泛函。

所以 J_obs = L(E_s)，其中 L 包含了从 e_s 到 (E_s_surf, H_s_surf) 的提取
和从表面场到 J_obs 的积分。

关键: L 作用在 e_s (散射场) 上，不是 E_total。

STEP 3: 目标函数 F
====================
F = (1/(N_k*6)) * sum_k |Delta_J(k)|^2 / |J_obs(k)|^2

其中 Delta_J(k) = J_obs_truth(k) - J_obs(k)

注意: F 中的 |J_obs(k)|^2 是归一化因子。
它来自当前假设分布的 J_obs（不是真值）。

实际上，仔细看代码:
  F = mean(sum(|dJ|^2, 2) ./ Jos / 6)
其中 Jos = max(|J_obs|^2, floor)

这里 Jos 是**当前**假设分布的 J_obs 的模平方。
所以 F = sum_k |Delta_J(k)|^2 / (6 * |J_obs(k)|^2)

但 Delta_J(k) = J_obs_truth(k) - J_obs_hyp(k)
J_obs_hyp 是 e_s 的函数: J_obs_hyp(k) = L_k(e_s)
J_obs_truth 是常数（不依赖 e_s）

所以 F = sum_k |J_obs_truth(k) - L_k(e_s)|^2 / (6 * |L_k(e_s)|^2)

注意: 分母 |L_k(e_s)|^2 也依赖 e_s！

这是一个非线性目标函数！

STEP 4: 变分分析
==================
dF = sum_k dF_k

dF_k = d[|Delta_J(k)|^2 / (6*|J_obs(k)|^2)]

Let a_k = J_obs_truth(k), b_k = L_k(e_s) = J_obs(k)
  d_k = a_k - b_k (Delta_J)
  
  |d_k|^2 = conj(d_k) * d_k
  |b_k|^2 = conj(b_k) * b_k

  F_k = conj(d_k)*d_k / (6*conj(b_k)*b_k)

  dF_k = [d(conj(d_k)*d_k) * 6*conj(b_k)*b_k 
          - conj(d_k)*d_k * 6*d(conj(b_k)*b_k)] / (6*|b_k|^2)^2

  d(conj(d_k)*d_k) = conj(d(d_k)) * d_k + conj(d_k) * d(d_k)
                   = -conj(db_k) * d_k - conj(d_k) * db_k
  (因为 d(d_k) = d(a_k - b_k) = -db_k)

  d(conj(b_k)*b_k) = conj(db_k)*b_k + conj(b_k)*db_k

代入并简化:

  dF_k = [-conj(db_k)*d_k - conj(d_k)*db_k] / (6*|b_k|^2)
         - |d_k|^2 * [conj(db_k)*b_k + conj(b_k)*db_k] / (6*|b_k|^4)

这比线性情况复杂得多！

关键发现: 分母中的 |J_obs|^2 导致目标函数是**非线性的**，
梯度公式包含额外的项（第二项），它涉及 conj(b_k)*db_k/|b_k|^2。

当前代码只用了第一项的近似！
""")

print("=" * 70)
print("  根因定位")
print("=" * 70)

print("""
目标函数 F 的完整梯度:

  dF/de_s = sum_k [-conj(dL_k/de_s)*d_k - conj(d_k)*dL_k/de_s] / (6*|b_k|^2)
           - sum_k |d_k|^2 * [conj(dL_k/de_s)*b_k + conj(b_k)*dL_k/de_s] / (6*|b_k|^4)

当前代码的梯度公式 g = k0^2 * dV * Re(lambda .* E_s) 
只计算了第一项的一个分量（通过伴随变量 lambda）。

**第二项（归一化因子的变分）被完全忽略了！**

这就是 CV=0.66 的根因——目标函数的非线性（归一化因子依赖 e_s）
导致梯度有一个被忽略的额外贡献。

第二项的物理含义：
  归一化因子 |J_obs(k)|^2 随参数变化而变化。
  当参数改变时，不仅 Delta_J 改变，分母也改变。
  分母变化对梯度的贡献被当前公式忽略了。

这个第二项的影响程度取决于 |d_k|^2/|b_k|^2 的比值——
即目标函数的当前值（越小则第二项越不重要）。

当前 F ≈ 0.2（从 FD 结果），意味着 |d_k|^2/|b_k|^2 ≈ 0.2*6*N_k ≈ 比较大。
所以第二项贡献不可忽略！
""")

# 数值验证：第二项的相对重要性
# 从 FD 结果，F ≈ 0.2
# F = mean(|d_k|^2 / (6*|b_k|^2)) ≈ 0.2
# 所以 |d_k|^2 / |b_k|^2 ≈ 0.2 * 6 = 1.2
# 这意味着 d_k 和 b_k 量级相当！

print("数值验证:")
print("  F ≈ 0.2 (从 FD 结果)")
print("  |d_k|^2 / |b_k|^2 ≈ F*6 ≈ 1.2")
print("  第二项/第一项 ≈ |d_k|^2/|b_k|^2 ≈ 1.2")
print("  所以第二项和第一项量级相当，不能忽略！")
print()
print("结论：当前梯度公式忽略了归一化因子的变分贡献，")
print("这是 ratio CV=0.66 的数学根因。")
print()

print("=" * 70)
print("  修正方案")
print("=" * 70)
print("""
两个选择：

方案 A（简单）：修改目标函数，去掉归一化因子
  F_simple = sum_k |Delta_J(k)|^2 / (6*N_k)
  这使得 F 线性依赖 e_s，梯度公式精确。
  但这改变了反问题的数学定义。

方案 B（精确）：推导包含归一化变分的完整梯度
  lambda = K^{-1} * [dF/de_s]  (完整变分，含两项)
  其中 dF/de_s 需要包含第二项的贡献。
  
  这需要在伴随源构建中额外加入归一化变分项。
  归一化变分 = -|d_k|^2 * conj(b_k) * db_k / (6*|b_k|^4)
  对应的伴随源修改 = -conj(Delta_J) * |Delta_J|^2 / (|J_obs|^2 * 6 * |J_obs|^2)

方案 C（折中）：使用归一化因子的"冻结"近似
  在梯度计算时，分母 |J_obs(k)|^2 用当前迭代的固定值（不随参数变分）。
  这等价于: F_eff = sum_k |Delta_J(k)|^2 / C_k，其中 C_k = |J_obs(k)|^2 固定。
  
  梯度变为: dF_eff/de_s = sum_k [-conj(db_k)*d_k - conj(d_k)*db_k] / (6*C_k)
  这是线性的，现有伴随公式精确（只需把 J_obs_safe 视为常数而非 J_obs 的函数）。

  实际上... 仔细看代码:
    Delta_J_perp = Delta_J ./ J_obs_safe
  这里 J_obs_safe = max(|J_obs|^2, floor)
  然后 build_adjoint_source 用的 Delta_J_perp 已经除以了 J_obs_safe。

  但问题是: Delta_J_perp 本身也依赖 e_s (因为 Delta_J 和 J_obs_safe 都依赖 e_s)。

  如果把 J_obs_safe 视为冻结常数（不随参数变），则:
    Delta_J_perp ≈ (J_obs_truth - J_obs_hyp) / C_k
    d(Delta_J_perp)/de_s ≈ -dJ_obs_hyp/de_s / C_k

  这就回到了线性问题。

  代码中实际做的是:
    lc.Delta_J_perp = Delta_J ./ J_obs_safe
  其中 Delta_J 和 J_obs_safe 都来自同一个 e_s。
  
  如果 J_obs_safe 被视为冻结（方案 C），则伴随源应该是:
    adj_source ∝ conj(Delta_J_perp) = conj(Delta_J) / C_k
  这是当前代码做的事情（隐式地）。

  但如果 J_obs_safe 不是冻结的，那么:
    d(Delta_J ./ J_obs_safe) / de_s 
    = d(Delta_J)/de_s / J_obs_safe - Delta_J * d(J_obs_safe)/de_s / J_obs_safe^2
    
  第二项就是被忽略的归一化变分！

  所以问题的本质是: build_adjoint_source 中的 Delta_J_perp = Delta_J ./ J_obs_safe
  这一步如果 J_obs_safe 不是冻结的，就引入了非线性。

验证方法: 把 J_obs_safe 替换为固定的 1.0（去掉归一化），
看 ratio 是否一致。
""")

print("=" * 70)
print("  快速验证方案")
print("=" * 70)
print("""
最简单的验证: 把 F 中的归一化去掉，即:

  F_test = mean(sum(abs(dJ)^2, 2) / 6)  -- 不除以 Jos

然后重新做 FD 和伴随对比。

如果 CV 显著降低（< 0.1），就确认了归一化是根因。
""")
