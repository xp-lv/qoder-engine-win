# 实验日志 — exp_id: H001_bspline_ncz

## 实验信息
- **hypothesis_id**: H001
- **改动**: n_cz 2→5 (总控制点 200→500)
- **git_commit**: 7269fed
- **git_tag**: exp_H001_bspline_ncz
- **mphserver**: localhost:2036 (TcpTestSucceeded=True)
- **MATLAB**: R2023b (23.2.0.2365128)

---

## 阶段一：正演管线完整性验证 (verify_forward_pipeline)

**状态**: ✅ PASS

| 检查项 | 结果 | 阈值 |
|--------|------|------|
| cos θ (mean) | 0.995568 | > 0.99 ✅ |
| \|J_obs\|/\|J_hyp\| ratio | 0.9844 | ≈ 1.0 ✅ |
| max F_k (V5a) | 2.239e-02 | < 1e-3 WARN (Born 近似固有偏差，非管线 bug) |
| 内层体素 | 673 (3.5%) | — |
| Gauss 点 | 2692 (4×673) | — |
| ka | 2.7246 | — |

**结论**: 正向管线完好，可继续阶段二。

---

## 阶段二：反演实验 (run_experiment('plugin_a12'))

**状态**: ⚠️ TIMEOUT (600s) — 完成迭代 1-2，迭代 3 进行中超时

### B-spline 参数化
- 控制点网格: 10×10×**5** = **500** (n_cz=5 生效 ✅)
- B-spline 算子: NNZ=1,006,038, 密度 10.44%, 内存 16.10 MB
- PoU: min=1.000000 max=1.000000 mean=1.000000 ✅
- 自由度比: 192/500 = 1:2.6

### 反演迭代记录

#### iter 1/10 (mu=0.0500, ACCEPTED)
| 频率 | F_k mean | F_k max | cos θ |
|------|----------|---------|-------|
| 1 GHz | 0.1996 | 1.1507 | 0.453 |
| 2 GHz | 0.6740 | 7.2738 | -0.309 |
| 3 GHz | 0.4355 | 2.2958 | -0.035 |
- **AGG**: F_cheb=**0.4364**, F_max=2.6554, cos=0.037, inner=[4.000, 4.000], t=60.4s
- **Armijo**: ACCEPTED (trial=1, mu=0.050, F_data 0.4364→0.3763)
- TV: R_TV=3.85e-12 (initial c uniform → TV=0)

#### iter 2/10 (mu=0.1000, ALL REJECTED)
| 频率 | F_k mean | F_k max | cos θ |
|------|----------|---------|-------|
| 1 GHz | 0.2322 | 1.2169 | 0.328 |
| 2 GHz | 0.4956 | 2.9042 | -0.336 |
| 3 GHz | — | — | — |
- **AGG**: F_cheb=**0.3763**, F_max=1.1430, cos=-0.012, inner=[3.719, 3.881], std=0.038, t=54.4s
- **Armijo**: ALL 8 TRIALS REJECTED (F_data never below old_data=0.3763)
  - trial 1: mu=0.100, F_data=0.4554 reject
  - trial 2: mu=0.050, F_data=0.3971 reject
  - trial 3: mu=0.025, F_data=0.3817 reject
  - trial 4: mu=0.0125, F_data=0.3796 reject
  - trial 5: mu=0.0063, F_data=0.3779 reject
  - trial 6: mu=0.0031, F_data=0.3770 reject
  - trial 7: mu=0.0016, F_data=0.3766 reject
  - trial 8: mu=0.0008, F_data=0.3764 reject
- **iter 3**: 开始 freq=1 (1 GHz) 正演 → 超时于 freq=3 (3 GHz) 正演阶段

### 超时分析
- 每迭代 3 频率 × (正演+伴随+梯度+线搜索 8 trials) ≈ 60-120s
- iter 2 线搜索 8 trials 全部 rejected（每 trial 3 频率正演 = 24 次正演调用）
- 600s 超时仅完成 2 迭代（反演停滞在 iter 2，c 未更新）
- **反演未收敛**，停留在初始 c=4.0 附近的近均匀解

### 最佳可用数据 (iter 2 AGG, last accepted state)
- F_cheb (multi-freq): **0.3763** (基线 0.091)
- cos θ (1 GHz): **0.328** (基线 0.9929)
- inner eps_r: mean=3.719, std=0.038 (真值 5.0)
- converged: **false**

---

## 备注
- run_experiment.m 最终三件套输出未生成（进程被 600s 超时终止）
- 三件套指标从 AGG 行提取（A12_inversion_loop 内部计算）
- 反演实质上停滞：iter 2 所有线搜索均被拒绝，迭代 3+ 预计仍会停滞
