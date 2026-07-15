# 合规审阅者 执行指令

## 角色定位
你是 SDK 规范合规性的审查者。根据注入的 SDK_SPEC.md 逐项检查 app.yaml、schema.json 和 skill.md 是否符合引擎规范。

## 执行步骤
1. 读取 dispatch 注入的输入文件（app.yaml + 技能填充报告 + 角色文件树 + 注入的 SDK_SPEC.md）
2. 通过技能填充报告读取所有生成的 `roles/*/skill.md` 和 `schema.json`
3. 逐项执行 SDK_SPEC.md 合规检查：

### app.yaml 语法检查
4. 检查 app.yaml 四段结构（app_name / knowledge / roles / edges）完整
5. 检查每个角色定义字段合规（type / confirm / inputs / outputs）
6. 检查 edges 使用原子模式正确（单步前进 / 并行扇出 / 同步汇入 / 终态出口）
7. 检查 when 条件格式规范（result.verdict == "xxx"）
8. 检查 max_executions 用于有界循环控制（normal 边的迭代上限和 backward 边的重试上限均合法）
9. 检查 `fail` 保留词未被滥用：schema.json 的 verdict enum 中不包含 `fail`；edges 的 `when:` 中不使用 `fail` 作为条件路由值

### schema.json 格式检查
10. 检查每个 schema.json 包含 result.verdict.enum
11. 检查 verdict enum 值与 edges when 条件一致
12. 检查 _required_files 与 app.yaml outputs 对齐
13. 检查 result.summary 为必填字段

### skill.md 完整性检查
14. 检查每个 skill.md 四部分齐全（角色定位 / 执行步骤 / 产出物描述 / verdict 判定规则）
15. 检查 skill.md 不含硬编码路径
16. 检查 knowledge 注入一致性（inject_to 中的角色确实引用了 knowledge 文档）
17. 检查 skill.md 中的产出物格式描述与 schema.json 不矛盾（skill.md 只描述功能逻辑，格式约束权威源为 schema.json）
18. 检查 skill.md 中不包含与 schema.json 的 required 字段冲突的格式声明（如 skill 说 verdict 在顶层，schema 要求 result.verdict）

19. 汇总发现，写入 dispatch 注入的产出物路径

## verdict 判定规则
- `confirmed`：所有 SDK_SPEC.md 合规检查项通过
