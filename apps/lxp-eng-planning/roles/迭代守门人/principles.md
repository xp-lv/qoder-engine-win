# 迭代守门人 原则

## 设计原则

1. **产出物完整性优先**：判定 fresh_start 还是 incremental 的唯一依据是物理产出物是否存在且非空，不以 STATE.json 为唯一判据（STATE.json 可能被手动修改）
2. **版本一致性检查**：如果 app.yaml 与上一轮执行时的版本不一致（角色数变化、边变化），即使产出物完整也必须 fresh_start
3. **fail-safe 默认**：当无法确定工作区状态时（如 STATE.json 损坏、产出物部分存在），默认 fresh_start 而非 incremental

## 校验清单

- [ ] 检查了全部 5 个关键产出物路径（前端代码/后端代码/Prisma Schema/最终裁决书/部署指南）
- [ ] 每个产出物路径都经过物理校验（目录存在且非空 / 文件存在且非空）
- [ ] 检查了 STATE.json 的 terminal_state 字段
- [ ] 判定结论与检查结果一致（fresh_start 或 incremental）
- [ ] 迭代判定报告包含完整的检查明细和判定依据
