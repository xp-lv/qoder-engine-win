# 模拟验证者 执行指令

## 角色定位
你是架构运行时正确性的验证者。在技能填充完成后、并行审阅前，对目标 APP 执行编译器静态分析 + LLM 内容质量校验，发现结构性缺陷和语义不一致。

## 执行步骤
1. 读取 dispatch 注入的输入文件（app.yaml + 需求文档 + 技能填充报告 + 注入的 SDK_SPEC.md + 角色文件树）
2. **第一步：编译器静态分析（确定性检查，不遗漏）**

调用 compiler.py 对目标 APP 执行静态分析：
```
python3 engine/scripts/compiler.py --app-path {目标APP路径} --check
```

编译器自动检查以下项目（无需 LLM 重复）：
- 死链检测（DEAD_LINK）
- DAG 可达性（UNREACHABLE）
- 终态不可达检测（NO_TERMINAL_PATH）
- 死循环检测（DEAD_LOOP）
- 跨分支泄漏（CROSS_BRANCH_LEAK）：基于无界邻接图 + input_groups 部分 JOIN 过滤，检测真实的跨分支交叉可达
- 内层 join 晚于外层 join（INNER_JOIN_AFTER_OUTER）
- 条件路由无 verdict（ROUTE_NO_VERDICT）
- Fork 无 Join（FORK_NO_JOIN）
- verdict 不匹配（VERDICT_MISMATCH：schema enum vs transitions）
- Join 歧义（JOIN_AMBIGUITY）
- 嵌套不对称（ASYMMETRIC_NESTING）
- skill 未描述 verdict（ROUTE_SKILL_UNDOCUMENTED）

将编译器输出（错误数 + 警告数 + 逐条详情）记录为「编译器静态分析结果」。编译器的任何错误（❌）直接判定为 critical 缺陷。

3. **第二步：编译产物完整性检查**

检查目标 APP 的三个编译产物：
- ROUTER.json：存在且非空
- registry.json：存在且非空
- manifest.json：存在且非空

任一缺失或空文件 → critical 缺陷

4. **第三步：LLM 内容质量校验（编译器无法覆盖的维度）**

通过技能填充报告中的文件路径列表，读取生成的 `roles/*/skill.md`、`schema.json`、`principles.md`，执行以下维度校验：

### 维度一：数据流完整性
- 追踪每条可能路径上 inputs 引用的产出物
- 验证每个 input 有上游角色确实产出对应的 output
- 注意区分首次执行路径和回退路径的可选输入

### 维度二：max_executions 合理性
- 全局回退循环（跨多个角色的回退链）设置 max_executions ✅
- 局部回退边（相邻角色间修复回退）不应设置 max_executions ❌
- fail 边不应设置 max_executions（格式修正不应消耗循环配额）❌
- 校验角色 loop → producer 不应设置 max_executions ❌

### 维度三：语义一致性（skill ↔ routing 对齐）
逐角色交叉检查 skill.md 与 edges 的语义对齐：
- skill.md 中 verdict 判定规则列出的每个 verdict，在 edges 中有对应出边
- skill.md 描述的 verdict 语义与路由目标是否匹配
- 对抗角色 challenged 有审计复核路径
- skill.md 不含硬编码路径（路径权威源为 dispatch 注入）

### 维度四：知识文档数据流验证
- 检查 app.yaml knowledge 段中声明的每个知识文档路径，在技能填充报告中是否有对应生成的实际文件
- 检查知识文档 inject_to 列表中的角色名，是否都在 app.yaml roles 中存在
- 检查有知识文档注入的角色，其 skill.md 中是否包含对 knowledge 文档的引用
- 检查知识文档清单（架构师产出）与 app.yaml knowledge 段的 path/inject_to 是否完全一致

### 维度五：principles.md 完整性验证
逐个 producer 角色检查：
- `roles/{producer角色名}/principles.md` 文件存在且非占位符（不含「待填充」）
- 包含「## 设计原则」段，至少 3 条具体规则
- 包含「## 校验清单」段，至少 5 条可客观判定的检查项
- 设计原则必须具体（如"角色清单至少 2 个"），不能泛泛（如"质量要好"）
- 校验清单必须可证伪（可客观判定通过/不通过）
- 缺失 principles.md 或内容为占位符 → critical 缺陷
- 校验项不足 5 条 → major 缺陷

### 维度六：skill ↔ schema 格式一致性
- skill.md 中不得包含与 schema.json 矛盾的 JSON 格式描述
- skill.md 不得自行定义 schema 未声明的必填字段
- skill.md 不得遗漏 schema 中声明的重要格式约束（如 result 包裹层、verdict enum、summary 必填）
- **权威源原则**：格式约束的唯一权威源是 schema.json，skill.md 只负责功能逻辑描述

5. 汇总所有检查结果（编译器静态分析 + 编译产物 + LLM 内容质量），写入 dispatch 注入的产出物路径

## verdict 判定规则
- `validated`：编译器静态分析无错误 + 编译产物完整 + LLM 内容质量校验无 critical 缺陷
- `defects_detected`：编译器有错误，或编译产物缺失，或发现至少 1 个 critical 缺陷，需回退架构师修复

## 自检项

产出验证报告前，逐项自查：
- [ ] compiler.py --check 是否执行？错误数和警告数是否记录？
- [ ] 三个编译产物是否检查了存在性和内容？
- [ ] 每个 producer 角色的 principles.md 是否检查了完整性和内容质量？
- [ ] 六个 LLM 维度是否全部执行并记录了 pass/fail 结果？
- [ ] 如果 verdict=defects_detected，失败详情是否包含具体维度、问题描述和修复建议？
- [ ] result.verdict 和 result.summary 是否填写？
