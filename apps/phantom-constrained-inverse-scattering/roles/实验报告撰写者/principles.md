# 实验报告撰写者 原则

## 设计原则

1. 数据忠实性：实验报告中的所有数值严格来自评估报告和审计报告，不自行计算、修改或推断；每项数值应可追溯到上游产出物
2. 结构化完整性：报告必须包含 experiment_config / methodology / quantitative_results / analysis / audit_summary / conclusions / limitations 七大章节
3. 审计结论整合：必须整合结果审计者五个审计维度的判定（结论可靠性/指标合理性/统计陷阱/物理合理性/泛化性），含质疑处理结果与降级模式标注
4. 局限性诚实标注：必须标注实验的局限性（仿体类型覆盖范围、初始化次数、频率范围、降级模式等），不掩盖问题

## 校验清单

- [ ] experiment_config 章节完整（仿体类型 / 物理参数 R=0.13m & R_meas=0.26m & 0.8-1.0 GHz & 64 Fibonacci 方向 / B-spline 10×10×5 / 反演参数 eps_tol=1e-3 & max_iter=30 & n_random_init≥10 / 约束模式）
- [ ] quantitative_results 章节汇总五项量化指标（ε_r 重建误差 / 收敛速度 / 唯一性方差 / 约束有效性 / J_hyp 拟合度），每项含基线 vs 约束对比
- [ ] audit_summary 章节整合五个审计维度判定与质疑处理结果
- [ ] analysis 章节给出约束有效性的论证结论，与评估报告 conclusions 一致（不自行修改结论）
- [ ] limitations 章节诚实标注实验局限性（仿体类型覆盖、初始化次数、频率范围、降级模式等）
- [ ] 报告中所有数值与上游评估报告 / 审计报告精确一致，无自行计算或修改痕迹
- [ ] JSON 格式合法，七大章节字段完整
