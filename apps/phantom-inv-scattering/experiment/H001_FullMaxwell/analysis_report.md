# 分析报告 — exp_id: H001_FullMaxwell

> 角色定位：M4 结果分析者，独立视角。本报告从 M3 两阶段实验产出（阶段一正演验证 + 阶段二 A12 反演）中提炼三件套指标，前置执行健全性校验拦截静默错误，不含 M3 推理过程。
>
> **核心结论（一句话）**：经过**两阶段实验**（首次产出完整反演数据），H001 的 verification_status 从 INCONCLUSIVE 升级为 **FAIL**。阶段一确认正演管线完整性（cos θ=0.995568），但 Δ +0.0027 不可归因 H001（Born Path B + eps_r=3.0≠5.0）。阶段二 A12 反演**严重失败**——F_cheb=0.3795（超目标 4.7×）、PASS=2/7（基线 5/7）、inner_mean 从 4.0 漂移至 3.80（远离真值 5.0）。**关键发现**：A12 走表面等效路径（extract_scattered→lightcone_project→J_obs_perp），**完全不经过** H001 改动的 compute_jhyp_comsol 体积积分路径，因此 A12 失败虽是负面科学发现，但不能直接归因 H001。H001 FAIL 的核心依据：①预期效果（cos θ 同条件改进 / F_cheb≤0.080 / A12≥6/7）全部未达成；②假设存在架构性错配——声称改进 A12 但 A12 不使用被修改的代码路径；③历经 5 轮实验仍无任何支持性证据。

---

## 一、健全性校验（前置，IF-8 强制）

### 1.1 阶段一（正演验证）必选项

| 检查项 | 结果 | 依据 |
|--------|------|------|
| **NaN/Inf 检测** | ✅ PASS | forward_metrics.json 全部字段为有限实数；log.md §四 stdout 无 NaN/Inf 关键字；FEM 确定性求解退出码 0、stderr=none |
| **值域断言** | ✅ PASS | cos θ mean/min/max = (0.995568, 0.931554, 0.999986) ∈ [-1, 1]；V5a max F_k = 2.239e-2 ≥ 0；\|J_obs\|/\|J_hyp\| = 0.9844 ≥ 0 |

### 1.2 阶段二（A12 反演）必选项

| 检查项 | 结果 | 依据 |
|--------|------|------|
| **NaN/Inf 检测** | ✅ PASS | A12_inversion_log.csv 全部 10 行 × 20 列为有限实数；A12_5_judges.csv 7 项 judge 值有限；A12_per_d_F_k.csv 64×7 矩阵有限；A12_worst_mean.csv / A12_cos_theta.csv 无 NaN/Inf（ripgrep 全目录搜索零命中）|
| **值域断言** | ✅ PASS | F_cheb = 0.3795 ≥ 0；cos θ = 0.0001 ∈ [-1, 1]；PASS = 2 ∈ [0, 7]；inner_mean = 3.8024 > 0（物理合理）；worst F_k = 1.370 ≥ 0 |

> **判定说明**：阶段二数据无 NaN/Inf、无值域越界，**不是 DIVERGED**（非数值发散）。但 config_snapshot.json `converged: false`、F_cheb=0.3795 远超目标 ≤0.080、inner_mean 远离真值 5.0，属 **NOT_CONVERGED**（算法完整运行但未达到收敛目标）。

### 1.3 可选项

| 检查项 | 结果 | 说明 |
|--------|------|------|
| **可重复性交叉验证（阶段一）** | ✅ PASS（5 轮确证） | log.md §8.4+§9.4+§10.3：连续 5 轮 verify_forward_pipeline 实测 V5a max F_k = 2.239224e-02 / cos θ = 0.995568 / ratio = 0.9844，**bit-for-bit 一致**。确定性 FEM + 同 git HEAD（6b3d8b3）+ 同物理参数 → 同结果，满足科研可复现性 |
| **benchmark 交叉校验** | ⏭️ SKIP | 实验目录未含 benchmark_solution.json；据知识库「benchmark 仅对基线球型几何有效」判定本次为正演验证 + A12 反演场景，不适用 benchmark 交叉校验。**跳过原因已记录**（避免审计盲区）|

### 1.4 边界输入降级判定

| 阶段 | result_status | 判定依据 |
|------|---------------|---------|
| **阶段一（正演验证）** | **VALID** | mphserver port 2036 TcpTestSucceeded=True；verify_forward_pipeline 10 步全部产出；NaN/Inf PASS、值域 PASS；无发散/越界。**三件套计算可继续** |
| **阶段二（A12 反演）** | **NOT_CONVERGED → 降级** | config_snapshot.json `converged: false`；F_cheb=0.3795 >> 目标 0.080（4.7×）；inner_mean=3.80 远离真值 5.0；iter 2-10 全部 Armijo rejected。NaN/Inf/值域虽 PASS（非 DIVERGED），但未达收敛目标。**按原则 2 降级处理：标记 result_status=NOT_CONVERGED，三件套不进入 M5 基线 Δ 对比，在报告中记录降级原因** |

---

## 二、三件套指标

### 2.1 阶段一（result_status: VALID — 三件套已计算）

| 指标 | 本次实测 | 基线 | Δ | 物理值域 | 状态 |
|------|---------|------|---|---------|------|
| **cos θ (mean)** | 0.995568 | 0.9929 | **+0.002668** | ∈ [-1, 1] ✅ | 已测得 |
| **cos θ (min)** | 0.931554 | — | — | ∈ [-1, 1] ✅ | 已测得（64 方向最劣）|
| **cos θ (max)** | 0.999986 | — | — | ∈ [-1, 1] ✅ | 已测得（64 方向最优）|

> **归因限定**：Δ +0.0027 超过 H001 目标 Δ ≥ 0.002，但**不可归因 H001**。verify_forward_pipeline Path B 使用 Born 链（equivalent_source + lightcone_hyp），不调用 compute_jhyp_comsol；且 eps_r_true=3.0 ≠ 基线 5.0（弱散射下 Born 更准确，cos θ 自然偏高）。

### 2.2 阶段二（result_status: NOT_CONVERGED — 已降级，三件套不进入 M5）

> **降级说明**：按 skill 原则 2，NOT_CONVERGED 输入禁止进入三件套计算用于 M5 基线对比。以下数值为实验 postprocess 步骤自动产出的**描述性数据**（记录失败程度），**不作为 M5 Δ 对比的有效三件套**。

| 指标 | 实验实测（描述性） | 基线 | H001 目标 | 状态 |
|------|-------------------|------|----------|------|
| **F_cheb（Chebyshev 残差）** | 0.3795 | 0.091 | ≤ 0.080 | ⛔ 降级（NOT_CONVERGED）— 超基线 4.2×、超目标 4.7× |
| **PASS 项数 A12** | 2/7 | 5/7 | ≥ 6/7 | ⛔ 降级（NOT_CONVERGED）— 较基线 -3 项 |
| **cos θ（反演，非正演）** | 0.0001 | — | — | ⛔ 降级 — J_obs ⊥ J_hyp（近正交，反演停滞）|

**PASS 项明细（A12_5_judges.csv）**：

| Judge | Value | Threshold | Result |
|-------|-------|-----------|--------|
| P1 inner_mean_error | 1.1976 | < 0.1 | **FAIL**（inner_mean=3.80 vs 真值 5.0）|
| P2 inner_std | 0.0341 | < 0.05 | PASS |
| P3 F_cheb | 0.3795 | < 0.15 | **FAIL** |
| P4 worst_F_k | 1.370 | < 0.15 | **FAIL**（k=35 方向）|
| P5 J_obs_consistent | 1 | = 1 | PASS |
| P6 per_d_mean | 3.485 | < 0.15 | **FAIL** |
| P7 cos_theta | 0.0001 | > 0.90 | **FAIL**（近正交）|

### 2.3 辅助前向指标（阶段一，非三件套）

| 指标 | 实测 | 阈值参考 | 解读 |
|------|------|---------|------|
| V5a max F_k | 2.239224e-02 | < 1e-3（严格）/ < 0.05（Born 固有偏差上限）| **WARN**：超严格阈值但 < 0.05，属 Born 近似在 ka=2.72 下的固有前向偏差——这是 H001 假设的物理动机 |
| \|J_obs\|/\|J_hyp\| ratio | 0.9844 | ≈ 1.0 | PASS：Born 等效源幅值与 COMSOL 全波偏离 1.56% |

---

## 三、科学解读（核心能力占比 ≥ 60%）

### 3.1 阶段一：cos θ Δ +0.0027 不可归因 H001（与上轮分析一致）

**证据链**：
1. verify_forward_pipeline.m Path B 使用 Born 近似链（equivalent_source + lightcone_hyp），**不调用** H001 改动的 compute_jhyp / compute_jhyp_comsol / linesearch
2. 脚本固定 eps_r_true = 3.0，与基线 eps_r = 5.0 **非同条件**——弱散射（eps_r=3.0）下 Born 近似更准确，cos θ 自然偏高
3. Δ +0.0027 主要由 eps_r 差异（3.0 vs 5.0）贡献，**非 H001 的 full_maxwell 切换贡献**

**结论**：将 Δ 直接归因 H001 = 因果推断谬误（混淆变量：散射强度）。H001 改动**未破坏**正演管线前向正确性（正向证据），但**未证明** full_maxwell 本身的改进效果。

### 3.2 阶段二：A12 反演严重失败——但关键在于路径错配

**反演失败量化**：
- F_cheb 从 cold start 0.4364 降至 0.3795（仅 iter 1 accepted，iter 2-10 全部 Armijo rejected，c 未更新）
- F_cheb=0.3795 超 H001 目标 ≤0.080 **4.7 倍**，超基线 0.091 **4.2 倍**
- inner_mean 从 4.0 漂移至 3.8024，**远离真值 5.0**（误差 1.1976）
- cos θ = 0.0001（J_obs ⊥ J_hyp 近正交）——正演场与观测场方向不一致，反演在错误方向停滞
- worst F_k = 1.370（k=35 方向），方向不均匀性显著（worst/mean=3.61）

**反演发散根因（log.md §10.4.6）**：
1. Armijo F_data 准则过严：iter 1 后所有试探步长（mu=0.1→0.000195，8 次减半）均 reject
2. TV 正则化梯度主导：‖g_tv‖=273.4 vs ‖g_data‖=0.033，TV 梯度比数据梯度大 8 倍
3. cos θ ≈ 0：J_obs 与 J_hyp 几乎正交，反演在错误参数区域停滞

### 3.3 核心发现：A12 路径错配——H001 改动的代码在 A12 中不被调用

**这是本轮最重要的科学发现**，直接决定 H001 的最终判定。

A12_inversion_loop.m 的 J_hyp 计算走**测量球面表面等效路径**：
```
sf = extract_scattered(model, grid);       % COMSOL 表面场提取
lc_new = lightcone_project(grid, sf, p);   % 光锥投影
J_hyp = lc_new.J_obs_perp;                 % 表面等效 J
```

H001 改动的代码路径（M2 modification_log）：
```
compute_jhyp.m → compute_jhyp_comsol.m    % 体积积分路径（mphint2 Gauss 积分）
inversion_loop.m Step② → compute_jhyp_comsol
linesearch.m compute_cost_fast → compute_jhyp_comsol
```

**两条路径完全不同**。A12 使用表面等效路径，H001 改动的是体积积分路径。modification_log 明确记录：「A12/C01 反演循环不在此假设声明维度内（其已使用测量球面表面等效路径，非 Born 链），未改动」。

**推论**：
- A12 的反演失败**不能直接归因 H001**（因果链断裂：H001 改动 → compute_jhyp_comsol，但 A12 不调用此函数）
- 但 H001 的 expected_effect 声称「A12/C01 PASS 项数提升」——这个声明**架构上不可能实现**，因为 A12 不经过被修改的代码路径
- H001 假设的设计前提存在根本性缺陷：假设 Full Maxwell 改进 A12 反演，但 A12 的 J_hyp 来自表面路径而非体积路径

### 3.4 综合科学判定

| 维度 | 证据 | 归因 H001 |
|------|------|-----------|
| 正演管线完整性 | cos θ=0.9956 ∈ 合规域 ✅ | H001 改动**未破坏**前向正确性（正向证据）|
| cos θ 改进 | Δ +0.0027 ≥ 0.002 目标 | ❌ 不可归因（Born Path B + eps_r=3.0≠5.0）|
| F_cheb ≤0.080 | 0.3795（超 4.7×）| ❌ 不可归因（A12 不走 compute_jhyp_comsol）|
| A12 PASS ≥6/7 | 2/7（较基线 -3）| ❌ 架构性不可能（A12 不调用 H001 改动代码）|
| Full Maxwell 改进效果 | **从未被直接测量** | ❌ compute_jhyp_comsol 在两阶段中均未被调用 |

---

## 四、改进方向建议（驱动 M5 / 下一轮 M1）

### 4.1 最高优先级：运行真正调用 compute_jhyp_comsol 的反演循环

当前 5 轮实验中，**compute_jhyp_comsol 从未在任何实验脚本中被实际调用**：
- 阶段一 verify_forward_pipeline → Born Path B
- 阶段二 A12_multi_freq_inversion → 表面等效路径

**H001 的核心改动（source.model: born→full_maxwell）历经 5 轮实验仍未被直接验证**。需运行 `core_inversion/inversion_loop.m`（该脚本的 Step② 确实调用 compute_jhyp_comsol），方能直接测量 Full Maxwell 对反演精度的影响。

### 4.2 高优先级：修正 H001 的架构性错配

H001 声称改进 A12/C01 PASS 项数，但 A12/C01 使用表面等效路径（不经过 compute_jhyp_comsol）。建议两条路径：
- **路径 A**：将 H001 重新定义为仅针对 inversion_loop.m 体积积分路径的改进，放弃 A12/C01 PASS 目标
- **路径 B**：若要改进 A12/C01，需新建假设针对 A12 的表面等效路径（extract_scattered / lightcone_project），而非 compute_jhyp_comsol

### 4.3 中优先级：A12 反演发散的算法修复

A12 在当前参数下严重发散（F_cheb 卡在 0.3795、cos θ≈0），根因是 Armijo 准则 + TV 梯度主导 + cos θ≈0 三重因素。建议：
- 降低 lambda_TV（当前 0.001 导致 TV 梯度比数据梯度大 8 倍）
- 或改用 F_data + F_tv 联合 Armijo 准则（当前 F_data-only 使 TV 梯度方向无法被 Armijo 接受）
- 或增加 Armijo 试验步长数量（当前 8 次减半均 reject）

### 4.4 低优先级：消除 eps_r 条件不一致

verify_forward_pipeline.m 固定 eps_r_true=3.0，与基线 5.0 不一致。建议参数化 eps_r_true 使其 config 可控。

---

## 五、verification_status 判定

**verification_status = FAIL**

### 判定依据

**支持 FAIL 的证据**：
1. ❌ H001 expected_effect 声明「F_cheb 0.091 → ≤0.080」——实测 F_cheb=0.3795（超目标 4.7×）
2. ❌ H001 expected_effect 声明「A12/C01 PASS 项数提升，目标 A12≥6/7」——实测 A12=2/7（较基线 5/7 退化 -3 项）
3. ❌ H001 expected_effect 声明「cos θ ≥0.9949」——数值达标（0.9956）但**不可归因 H001**（Born Path B + eps_r=3.0≠5.0）
4. ⚠️ **架构性错配**：H001 声称改进 A12，但 A12 使用表面等效路径，不调用 H001 改动的 compute_jhyp_comsol——H001 对 A12 的改进声称**架构上不可能实现**
5. ❌ 历经 5 轮实验，compute_jhyp_comsol 从未在任何实验中被实际调用——H001 的核心改动**从未被直接验证**

**不判 INCONCLUSIVE 的理由**：
- 上轮 INCONCLUSIVE 的依据是「核心主张未被直接测量，需补跑反演」
- 本轮已补跑完整 A12 反演（10 轮迭代），结果是**明确的失败**（F_cheb=0.3795、PASS=2/7、inner_mean 远离真值）
- 虽然该失败不完全归因 H001（路径错配），但 H001 的预期效果（含 A12 PASS 提升）已**被实验证伪**
- H001 存在架构性错配这一发现本身就是对假设的**否定性证据**——假设声称的因果链（Full Maxwell → A12 改进）在代码层面不存在

**不判 PASS 的理由**：无任何支持性证据（预期效果全部未达成）。

---

## 六、健全性校验报告（sanity_report.md 内嵌）

```markdown
# 健全性校验报告 — exp_id: H001_FullMaxwell（两阶段）

## 阶段一（正演验证）
- NaN/Inf 检测: PASS（必选）
- 值域断言: PASS（必选）— cos θ ∈ [-1,1], V5a F_k ≥ 0, ratio ≥ 0
- 可重复性交叉验证: PASS（可选，5 轮 bit-for-bit 一致）
- benchmark 交叉校验: SKIP（可选，无 benchmark_solution.json）

## 阶段二（A12 反演）
- NaN/Inf 检测: PASS（必选）— 全部 CSV/矩阵有限实数
- 值域断言: PASS（必选）— F_cheb ≥ 0, cos θ ∈ [-1,1], PASS ∈ [0,7]
- 可重复性交叉验证: SKIP（可选，仅单轮反演）
- benchmark 交叉校验: SKIP（可选，无 benchmark_solution.json）
- result_status: NOT_CONVERGED → 降级（converged=false, F_cheb >> 目标）
```

---

## 七、自检（对照 skill.md）

- [x] 健全性校验是否在三件套计算之前执行？ → §一 在 §二 之前
- [x] NaN/Inf 检测是否通过？值域断言（cos θ∈[-1,1]、F_cheb≥0）是否通过？ → §1.1+§1.2 两阶段均 PASS
- [x] EMPTY/DIVERGED 输入是否正确降级？ → §1.4 阶段一 VALID、阶段二 NOT_CONVERGED → 降级
- [x] analysis_report.md 是否含三件套结果（或降级标记）+ 改进方向？ → §二（三件套+降级标记）+ §四（改进方向）
- [x] hypothesis_chain.json 对应假设的 verification_status 是否已回填？ → INCONCLUSIVE → **FAIL**
- [x] 返回值是否符合 dispatch 要求的扁平 JSON 格式：{"step", "workspace_id", "verdict", "outputs"}？ → 见返回
- [x] 核心科研能力内容占比 ≥ 60%？（§三+§四+§五 为核心科研内容，核心占比约 65%）
- [x] 不包含协议原理重复解释？
- [x] 判定依据来自外部资产（基线/清单/值域断言），非主观推理？（基线 0.9929/0.091/5/7、Born 偏差阈值 0.05、值域 [-1,1] 均来自知识库 / baseline/metrics_baseline.json）
