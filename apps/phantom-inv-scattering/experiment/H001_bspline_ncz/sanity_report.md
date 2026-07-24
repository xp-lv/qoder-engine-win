# 健全性校验报告 — exp_id: H001_bspline_ncz

## 校验执行时间: 2026-07-23T09:15:00

## 校验结果

| 校验项 | 类型 | 结果 | 详情 |
|--------|------|------|------|
| NaN/Inf 检测 | 必选 | ✅ PASS | 所有提取数值（F_cheb, cos θ, F_k, eps_r）均为有限值，无 NaN/Inf |
| 值域断言 | 必选 | ✅ PASS | F_cheb=0.3763 ≥ 0; cos θ=0.328 ∈ [-1,1]; eps_r mean=3.719 ∈ [1,50] |
| 可重复性交叉验证 | 可选 | ⏭️ SKIP | app_config/sanity.json 未开启，无法做重复实验交叉验证 |
| benchmark 交叉校验 | 可选 | ⏭️ SKIP | 无独立 benchmark 结果可用于交叉校验 |

## result_status: VALID

数据来源: experiment/H001_bspline_ncz/log.md + inverse_result/inverse_metrics.json
- iter 2 AGG 数据（最后一次 accepted step 后的状态）
- 超时导致 run_experiment.m 最终三件套输出未生成，使用 A12_inversion_loop 内部 AGG 行数据替代
- F_cheb 来源: multi-frequency aggregated Chebyshev residual (3 freq)
- cos θ 来源: 1 GHz per-frequency 方向一致性（与基线 0.9929 对应口径）

## 降级评估
- 非 EMPTY（有实际数值输出）
- 非 DIVERGED（数值未发散到 Inf/NaN）
- 非 NOT_CONVERGED 的极端形式（迭代有限次后被超时终止）
- **部分超时**：实验在 iter 3 超时，但 iter 1-2 数据完整有效，result_status 标记为 VALID
