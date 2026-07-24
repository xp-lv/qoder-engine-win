# Δ 基线对比报告 — exp_id: 20260722_H001

> 角色定位：M5 基线评估者，独立视角。本报告将 M4 两阶段实验三件套（及降级标记）置于固化基线坐标系（cos θ=0.9929 / F_cheb=0.091 / A12=5/7 / C01=4/6）中，产出 Δ 指标、exceeds_baseline 判定与改进信号。基线消费严格遵守 skill 原则 1（只读，未修改 baseline/metrics_baseline.json）。
>
> **核心结论（一句话）**：H001 的 verification_status = FAIL 在 Δ 维度被**确证**。按 skill 原则 2 输入约束，**仅阶段一（result_status=VALID）的三件套进入 M5 有效 Δ 对比**；阶段二（A12 反演 result_status=NOT_CONVERGED）按 M4 降级标记，仅记录描述性 Δ（不构成有效基线对比）。有效对比维度中，唯一进入对比的 cos θ Δ=+0.002668 虽数值超基线，但 M4 已确证**不可归因 H001**（Born Path B + eps_r=3.0≠5.0）；描述性维度中 F_cheb 退化 4.2×、A12 PASS 退化 −3 项，整体**远未超越基线**。exceeds_baseline = **false**。改进信号明确指向启动新假设：H001 存在架构性错配（声称改进 A12，但 A12 走表面等效路径不调用被修改的 compute_jhyp_comsol），历经 5 轮实验核心改动从未被直接验证。

---

## 一、输入约束检查（skill 原则 2 前置）

### 1.1 result_status 状态机核验

| 阶段 | M4 result_status | 是否进入 M5 Δ 对比 | 依据 |
|------|------------------|---------------------|------|
| **阶段一（正演验证）** | **VALID** | ✅ **进入** | NaN/Inf PASS、值域 PASS、mphserver port 2036 TcpTestSucceeded=True、verify_forward_pipeline 10 步全产出、5 轮 bit-for-bit 一致。满足 skill 原则 2「仅 VALID 进入评估」 |
| **阶段二（A12 反演）** | **NOT_CONVERGED** | ⛔ **不进入（降级）** | config_snapshot.json `converged: false`、F_cheb=0.3795 >> 目标 0.080（4.7×）、inner_mean=3.80 远离真值 5.0。按 skill 原则 2 + 基线资产参考准则 4，NOT_CONVERGED 禁止进入有效 Δ 对比，仅记录描述性数据 |

### 1.2 输入约束符合性

- ✅ result_status 非 VALID（NOT_CONVERGED）已正确拦截，不进入有效 Δ 对比
- ✅ 无 EMPTY/DIVERGED 违反约束情形（阶段二为 NOT_CONVERGED 而非 DIVERGED，数值健全但未达收敛目标）
- ✅ 改进信号基于 M4 分析结果（VALID + NOT_CONVERGED 降级标记），不基于 EMPTY/DIVERGED

### 1.3 基线只读消费核验（skill 原则 1）

- ✅ baseline/metrics_baseline.json 本次评估**仅读取、未写入、未修改**
- ✅ 基线值引用：A12_pass=5/7、C01_pass=4/6、cos_theta=0.9929、F_cheb=0.091（与文件一致）
- ✅ 基线 source（pipline README 2026-07-03 verify_forward_pipeline 验证）+ physics_params（r/R/f/λ/ka/n_dirs/n_voxels）均原样引用

---

## 二、Δ 指标计算

### 2.1 有效 Δ（阶段一 VALID，进入 M5 基线对比）

| 指标 | 迭代值 | 基线值 | Δ | 归因 H001 | 状态 |
|------|--------|--------|---|-----------|------|
| **cos θ (mean)** | 0.995568 | 0.9929 | **+0.002668** | ❌ **不可归因** | 数值正向，但因果链断裂 |

**归因分析（来自 M4 §3.1，已交叉确认）**：
1. verify_forward_pipeline.m Path B 使用 Born 近似链（equivalent_source + lightcone_hyp），**不调用** H001 改动的 compute_jhyp_comsol
2. 脚本固定 eps_r_true = 3.0，与基线 eps_r = 5.0 **非同条件**——弱散射（eps_r=3.0）下 Born 近似更准确，cos θ 自然偏高
3. Δ +0.0027 主要由 eps_r 差异（3.0 vs 5.0）贡献，**非 H001 的 full_maxwell 切换贡献**
4. 物理参数基线 diff 未消除（基线资产参考准则 2），指标不可直接对比归因

> **Δ cos θ 有效性裁定**：数值 Δ=+0.002668 ≥ H001 目标 Δ≥0.002，但因**不可归因 H001**，不构成"算法改进"的有效证据。在 exceeds_baseline 判定中**按零信号处理**（即不贡献正向证据）。

### 2.2 描述性 Δ（阶段二 NOT_CONVERGED，不进入有效对比）

> **降级说明**：按 skill 原则 2，以下 Δ 仅为实验 postprocess 自动产出的描述性数据，记录失败程度，**不作为 M5 有效 Δ 对比的依据**。

| 指标 | 实验实测（描述性） | 基线值 | H001 目标 | Δ（描述性） | 退化倍数 |
|------|-------------------|--------|----------|-------------|----------|
| **F_cheb（Chebyshev 残差）** | 0.3795 | 0.091 | ≤ 0.080 | **+0.2885**（残差增大，负向） | 4.2× |
| **A12 PASS 项数** | 2/7 | 5/7 | ≥ 6/7 | **−3 项**（负向） | — |
| **cos θ（反演，非正演）** | 0.0001 | — | > 0.90 | —（无基线对应） | J_obs ⊥ J_hyp 近正交 |

**描述性 Δ 解读**（虽不进入对比，但为 exceeds_baseline 判定提供上下文）：
- F_cheb 从基线 0.091 退化至 0.3795，**残差增大 4.2 倍**
- A12 PASS 从基线 5/7 退化至 2/7，**3 项判据从 PASS 转为 FAIL**（P1 inner_mean_error、P3 F_cheb、P4 worst_F_k、P6 per_d_mean、P7 cos_theta 失败）
- inner_mean 从 4.0 漂移至 3.8024，**远离真值 5.0**（误差 1.1976）

### 2.3 三件套 Δ 综合视图

| 三件套维度 | 有效 Δ | 描述性 Δ | 综合状态 |
|------------|--------|----------|----------|
| **cos θ** | +0.002668（数值正向，不可归因 H001） | 反演 cos θ=0.0001（无基线） | 零有效信号 |
| **F_cheb** | —（阶段一未测 F_cheb） | +0.2885（负向，退化 4.2×） | 负向退化 |
| **A12 PASS** | —（阶段一未测 A12） | −3 项（负向） | 负向退化 |
| **C01 PASS** | —（本次未运行 C01） | — | 未测量 |

---

## 三、exceeds_baseline 判定

### exceeds_baseline: **false**

### 判定依据

**支持 false 的证据**：

1. **唯一有效 Δ 不可归因 H001**：阶段一 cos θ Δ=+0.002668 是本次唯一进入有效对比的三件套维度，但 M4 已确证因果链断裂（Born Path B 不调用 compute_jhyp_comsol + eps_r=3.0≠5.0 物理参数不一致）。按基线资产参考准则 2「物理参数不一致的实验做三件套对比 → 因果推断失效」，此 Δ 不构成"算法改进"的有效正向证据，在 exceeds_baseline 判定中按零信号处理。

2. **描述性 Δ 全面退化**（虽不进入有效对比，但提供反证上下文）：
   - F_cheb 退化 4.2×（0.091 → 0.3795）
   - A12 PASS 退化 −3 项（5/7 → 2/7）
   - inner_mean 远离真值（4.0 → 3.8024，真值 5.0）

3. **H001 expected_effect 全部未达成**（M4 §五）：
   - ❌ F_cheb 0.091 → ≤0.080：实测 0.3795（超目标 4.7×）
   - ❌ A12/C01 PASS 提升，目标 A12≥6/7：实测 2/7（较基线 −3 项）
   - ⚠️ cos θ ≥0.9949：数值达标（0.9956）但不可归因 H001

4. **架构性错配**：H001 声称改进 A12，但 A12 使用表面等效路径（extract_scattered→lightcone_project→J_obs_perp），**完全不调用** H001 改动的 compute_jhyp_comsol。H001 对 A12 的改进声称在代码层面**架构上不可能实现**。

**不支持 false 的反证**：无。无任何有效证据支持 H001 改进有效。

**不判 true 的理由**：exceeds_baseline=true 要求"算法改进有效超越基线"。本次：
- 有效 Δ（cos θ）不可归因 H001 → 不能算作算法改进
- 描述性 Δ（F_cheb/PASS）全面退化
- 核心改动从未被直接测量

→ exceeds_baseline = **false**

---

## 四、改进信号（驱动 M1 新假设触发决策）

### 4.1 结构化改进信号

```yaml
delta_cos_theta: +0.002668    # 数值正向，但不可归因 H001（Born Path B + eps_r=3.0≠5.0）
delta_F_cheb_descriptive: +0.2885   # 描述性，残差增大 4.2×（NOT_CONVERGED，不进入有效对比）
delta_A12_PASS_descriptive: -3      # 描述性，PASS 项退化（NOT_CONVERGED，不进入有效对比）
exceeds_baseline: false
verification_status_M4: FAIL        # 从 INCONCLUSIVE 升级
new_hypothesis_recommendation: yes
```

### 4.2 启动新假设建议：**yes**

**核心理由**（按优先级排序）：

**理由 1（最高优先级）：H001 存在架构性错配——因果链在代码层面断裂**
- H001 声称「Full Maxwell（source.model: born→full_maxwell）改进 A12/C01 PASS」
- 但 A12 反演循环（A12_inversion_loop.m）走**表面等效路径**（extract_scattered→lightcone_project→J_obs_perp），**完全不调用** H001 改动的 compute_jhyp_comsol（体积积分路径）
- 即 H001 的 expected_effect（A12 PASS 提升）在代码层面**架构上不可能实现**
- M1 需基于此信号重新设计假设的因果链

**理由 2（高优先级）：compute_jhyp_comsol 历经 5 轮实验从未被直接验证**
- 阶段一 verify_forward_pipeline → Born Path B（不调用）
- 阶段二 A12_multi_freq_inversion → 表面等效路径（不调用）
- H001 的核心改动（full_maxwell 切换）**从未在任何实验中被直接测量**
- 需运行 `core_inversion/inversion_loop.m`（其 Step② 确实调用 compute_jhyp_comsol）方能直接验证

**理由 3（中优先级）：A12 反演存在可修复的算法层发散根因**
- F_data-only Armijo 准则过严（iter 2-10 全部 reject）
- TV 正则化梯度主导（‖g_tv‖=273.4 vs ‖g_data‖=0.033，8 倍差异）
- cos θ≈0（J_obs ⊥ J_hyp 近正交，反演停滞）
- 这三点均为可独立修复的算法问题，构成新假设的素材

**理由 4（低优先级）：物理参数基线 diff 未消除**
- verify_forward_pipeline.m 固定 eps_r_true=3.0，与基线 5.0 不一致
- 建议参数化 eps_r_true 使其 config 可控，消除因果推断的混淆变量

### 4.3 新假设方向建议（供 M1 参考）

| 方向 | 假设草案 | 改动域 |
|------|----------|--------|
| **方向 A**（修正 H001 范围） | 将 H001 重新定义为仅针对 inversion_loop.m 体积积分路径的改进，**放弃 A12/C01 PASS 目标**，改测 core_inversion 反演精度 | compute_jhyp_comsol 体积积分链 |
| **方向 B**（新建 A12 表面路径假设） | 新建假设针对 A12 的表面等效路径（extract_scattered / lightcone_project / J_obs_perp），改进 A12 PASS | A12 表面等效链 |
| **方向 C**（A12 算法修复） | 新建假设修复 A12 反演变散：lambda_TV 调参 / F_data+F_tv 联合 Armijo / 增加 Armijo 试验步长 | A12 反演算法参数 |

---

## 五、verdict 判定

### verdict: **fail_new_hypothesis**

### 判定依据

对照 skill.md verdict 判定规则：

| verdict 候选 | 触发条件 | 本次匹配 |
|--------------|----------|----------|
| `confirmed` | 基线只读成功；Δ 已计算；exceeds_baseline=true 且研究结论已确认 | ❌ exceeds_baseline=false |
| **`fail_new_hypothesis`** | Δ 已计算；exceeds_baseline=false 或=true 但仍有改进空间；改进信号已结构化产出（含启动新假设建议） | ✅ **完全匹配** |
| `fail` | 基线缺失/异常/被写入；输入 EMPTY/DIVERGED；Δ 计算失败；改进信号缺失 | ❌ 均未触发 |

**匹配 fail_new_hypothesis 的具体证据**：
- ✅ Δ 指标已按三件套各自计算（§二 有效 Δ + 描述性 Δ）
- ✅ exceeds_baseline=false（§三）
- ✅ 改进信号已结构化产出（§四：Δ + exceeds_baseline + 启动新假设建议 + 4 条理由 + 3 个方向）
- ✅ 有明确改进空间（H001 架构性错配可修正、compute_jhyp_comsol 可直接验证、A12 算法可修复）

**闭环回归路径**：M5 → M1，改进信号驱动 M1 产出下一轮假设（建议方向 A/B/C 之一）。

---

## 六、自检（对照 skill.md）

- [x] baseline/metrics_baseline.json 是否只读消费（未被修改）？ → §1.3 确认仅读取未写入，基线值与文件一致
- [x] 输入 result_status 是否为 VALID（非 VALID 已拦截）？ → §1.1 阶段一 VALID 进入对比、阶段二 NOT_CONVERGED 降级拦截
- [x] Δ 指标是否按三件套各自计算？ → §2.1 cos θ 有效 Δ、§2.2 F_cheb/PASS 描述性 Δ
- [x] exceeds_baseline 判定是否有明确依据？ → §三 4 条证据（不可归因 + 退化 + expected_effect 未达成 + 架构错配）
- [x] 改进信号是否结构化（Δ + exceeds_baseline + 启动新假设建议 + 理由）？ → §四 含 YAML 结构 + 4 条理由 + 3 个方向
- [x] delta_report.md 是否已产出？ → 本文件
- [x] 返回值是否符合 dispatch 要求的扁平 JSON 格式：{"step", "workspace_id", "verdict", "outputs"}？ → 见返回
