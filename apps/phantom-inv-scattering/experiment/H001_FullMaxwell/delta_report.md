# Δ 基线对比报告 — exp_id: H001_FullMaxwell

> 角色定位：M5 基线评估者。本报告把 M4 的三件套实测置于固化基线坐标系（A12=5/7 / C01=4/6 / cos θ=0.9929 / F_cheb=0.091）中，产出 Δ 指标 + exceeds_baseline 判定 + 改进信号。
>
> **核心结论（一句话）**：**exceeds_baseline = false**。三件套中仅 cos θ 有数值 Δ（+0.0027），但因实验走 Born 路径且 eps_r=3.0 ≠ 基线 5.0，该 Δ **不可归因 H001**；F_cheb / A12 / C01 三项均未测得（需完整反演）。H001 的反演改进主张**未被本次实验验证**，改进信号驱动闭环回归 M1 启动同条件成对反演实验。
>
> **[round-4 再评估 2026-07-22]**：本轮 M4 已升级为第三轮 bit-for-bit 确证（V5a max F_k / cos θ / ratio 三项连续 round-2 / round-3 / round-4 一致），数据可信度进一步加强。三项指标数值未变（cos θ=0.995568），Δ 矩阵与归因性结论与上一轮评估完全一致——再评估确认：exceeds_baseline 维持 false，verdict 维持 fail_new_hypothesis。指标的不变性进一步坐实「Δ +0.0027 来自 eps_r 混淆变量而非 H001 改进」的归因判定。

---

## 一、基线消费审计（原则 1：只读消费）

| 审计项 | 结果 |
|--------|------|
| baseline/metrics_baseline.json 是否存在 | ✅ 存在 |
| 格式是否正确（含 A12_pass / C01_pass / cos_theta / F_cheb 四字段） | ✅ 正确 |
| 是否只读消费（未写入/未修改） | ✅ 只读，未触发任何写操作 |
| 基线值固化 | A12=5/7 · C01=4/6 · cos θ=0.9929 · F_cheb=0.091 |

**结论**：基线坐标系完整且未被漂移，可作为 Δ 计算的参照原点。

---

## 二、输入约束检查（原则 2：仅 VALID 进入评估）

| 检查项 | 结果 | 依据 |
|--------|------|------|
| M4 result_status | **VALID** | analysis_report.md §1.3：mphserver REACHABLE、verify_forward_pipeline 10 步全产出、无发散/越界、NaN/Inf PASS、值域 PASS |
| 是否 EMPTY / DIVERGED / NOT_CONVERGED | 否 | 不进入降级流程 |

**结论**：输入通过约束，进入 Δ 计算。（注：result_status=VALID 不等于 verification_status=PASS——前者是数据健全性，后者是假设验证结论，二者正交。本次 verification_status=INCONCLUSIVE，但数据本身健全，可进入基线对比。）

---

## 三、Δ 指标计算（原则：三件套各自一维）

### 3.1 可计算项

| 指标 | 迭代值（实测） | 基线值 | Δ | 归因性 | 状态 |
|------|---------------|--------|---|--------|------|
| **cos θ (mean)** | 0.995568 | 0.9929 | **+0.002668** | ⚠️ **不可归因 H001** | 数值已算，因果断被拒 |

**cos θ Δ +0.0027 不可归因 H001 的三条证据链**（继承自 M4 §3.1）：
1. **路径不符**：verify_forward_pipeline 的 Path B 走 Born 链（equivalent_source + lightcone_hyp），**未调用** H001 改动的 compute_jhyp.m / compute_jhyp_comsol.m / linesearch.m
2. **条件不符**：脚本固定 eps_r_true=3.0，与 modification_log 基线（eps_r=5.0）**非同条件**
3. **物理预期**：弱散射（eps_r=3.0）下 Born 近似更准确，cos θ 自然偏高——Δ 主要由 eps_r 差异贡献，而非 full_maxwell 切换

**推论**：将 Δ +0.0027 直接计入 H001 改进 = 混淆变量谬误（散射强度 vs 算法切换）。该 Δ 在归因上**视为无效改进证据**。

### 3.2 未测得项（Δ 无法计算）

| 指标 | 迭代值 | 基线值 | Δ | 缺失原因 |
|------|--------|--------|---|----------|
| **F_cheb** | 未测得 | 0.091 | N/A | 需完整反演 A12_multi_freq_inversion，本次仅正演验证未触发 |
| **A12 PASS** | 未测得 | 5/7 | N/A | 需多频反演场景，本次未运行 |
| **C01 PASS** | 未测得 | 4/6 | N/A | 需多场景反演，本次未运行 |

**结论**：三件套中 **3/4 无 Δ**（F_cheb / A12 / C01），唯一有数值的 cos θ Δ 又因归因性被拒。**Δ 证据矩阵严重不完整**。

---

## 四、exceeds_baseline 判定

### exceeds_baseline = false

**判定依据**（综合三件套 Δ）：

| 维度 | 是否支持 exceeds_baseline=true | 理由 |
|------|------------------------------|------|
| cos θ Δ +0.0027 | ❌ 不支持 | 数值正向但**不可归因 H001**（Born 路径 + eps_r 混淆），不可作为 H001 超越基线的证据 |
| F_cheb Δ | ❌ 不支持 | 未测得，无证据 |
| A12 PASS Δ | ❌ 不支持 | 未测得，无证据 |
| C01 PASS Δ | ❌ 不支持 | 未测得，无证据 |

**综合判定**：四维证据中 **0 维有效支持** H001 超越基线。exceeds_baseline=false 是对当前证据矩阵的诚实反映——**不是**说 H001 一定没有改进（可能改进了，只是没测到），而是说**基于本次实验数据，无法确认 H001 超越基线**。

**与 verification_status=INCONCLUSIVE 的一致性**：M4 判 INCONCLUSIVE（无反向证据也未证实核心主张），M5 判 exceeds_baseline=false（无有效改进证据）——两者逻辑自洽，均指向同一行动：**补跑同条件成对反演**。

---

## 五、改进信号（原则 3：结构化且可决策）

### 5.1 Δ 汇总

- **Δ cos θ**: +0.002668（数值正向，**但归因性被拒**——Born 路径 + eps_r=3.0≠5.0 混淆变量）
- **Δ F_cheb**: N/A（未测得）
- **Δ A12 PASS**: N/A（未测得）
- **Δ C01 PASS**: N/A（未测得）

### 5.2 exceeds_baseline: false

（见 §四）

### 5.3 启动新假设建议: **yes**

**理由（结构化）**：

1. **核心主张未验证**：H001 的三项反演改进目标（cos θ 同条件提升 / F_cheb ≤ 0.080 / A12 ≥ 6/7 / C01 ≥ 5/6）**均未被本次实验直接测量**。停留在「未证伪也未证实」状态 = 闭环在分析阶段半断链。

2. **正向间接证据存在，值得追**：V5a max F_k = 2.239e-2（超严格阈值 1e-3 但 < Born 偏差上限 0.05）——这是 H001 假设的物理基础（Born 单次散射在 ka=2.72 下引入系统性前向偏差）。WARN 信号与假设动机方向一致，**必要非充分**，值得通过完整反演验证是否为充分证据。

3. **明确的下一步实验设计**（消除混淆变量）：
   - Run-1：Born 基线反演（eps_r=5.0，同 modification_log 条件）
   - Run-2：Full Maxwell 改进反演（eps_r=5.0，同条件）
   - 同条件对比方能合法计算 Δ F_cheb / Δ A12 / Δ C01，验证 H001 反演改进主张

4. **不启动新假设的代价**：若就此停止，H001 永远停留在 INCONCLUSIVE，前期 full_maxwell 基础设施投入（compute_jhyp_comsol.m + build_adjoint_source_fullmaxwell.m）无法兑现为反演精度提升，闭环退化为开环。

### 5.4 次要改进信号（供 M1 参考）

- **eps_r 参数化**：verify_forward_pipeline.m 固定 eps_r_true=3.0，建议参数化为 config 可控，消除条件不一致根因
- **计算成本评估**：Full Maxwell 单次 J_hyp 需 COMSOL 全波求解，建议补跑反演时记录 wallclock 对比（精度 vs 成本权衡）

---

## 六、verdict 判定

### verdict = fail_new_hypothesis

**判定过程**（对照 skill.md verdict 规则表）：

| verdict 候选 | 触发条件 | 是否满足 | 排除理由 |
|-------------|----------|----------|----------|
| `confirmed` | exceeds_baseline=true 且研究结论已确认 | ❌ | exceeds_baseline=false，研究结论 INCONCLUSIVE |
| `fail_new_hypothesis` | Δ 已计算 + exceeds_baseline=false + 改进信号结构化 | ✅ | — |
| `fail` | 基线缺失/被写、输入 EMPTY/DIVERGED、Δ 计算失败、信号缺失 | ❌ | 基线完整只读、输入 VALID、可算的 Δ 已算、信号结构化 |

**关键区分**：本次不是 `fail`——Δ 计算没有"失败"，而是**部分指标因实验范围限制未测得**（这是实验设计问题，不是评估流程错误）。可计算的 cos θ Δ 已诚实计算并标注归因性限制。改进信号结构化且可决策（含明确的下一步实验设计）。

**闭环动作**：fail_new_hypothesis → 闭环回归 M1，M1 基于 §5.3 的改进信号启动同条件成对反演实验（可作为 H001 的延续验证，或提炼为新假设 H002「Full Maxwell 在同 eps_r=5.0 条件下消除 Born 反演偏差」）。

---

## 七、自检（对照 skill.md）

- [x] baseline/metrics_baseline.json 是否只读消费（未被修改）？ → §一 审计通过，零写操作
- [x] 输入 result_status 是否为 VALID（非 VALID 已拦截）？ → §二 VALID，通过约束
- [x] Δ 指标是否按三件套各自计算？ → §三 cos θ Δ 已算（+0.0027），F_cheb/A12/C01 标注未测得
- [x] exceeds_baseline 判定是否有明确依据？ → §四 四维证据逐项分析，0 维有效支持
- [x] 改进信号是否结构化（Δ + exceeds_baseline + 启动新假设建议 + 理由）？ → §五 含 Δ 汇总 + false 判定 + yes 建议 + 4 条理由
- [x] delta_report.md 是否已产出？ → 本文件
- [x] 返回值是否符合扁平 JSON 格式 {step, workspace_id, verdict, outputs}？ → 见返回值
