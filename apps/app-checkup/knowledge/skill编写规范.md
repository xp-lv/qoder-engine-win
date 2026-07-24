# Skill.md 编写规范

> 本规范指导如何编写与引擎机制兼容的 skill.md。不是事后评审清单，而是**事前编写指南**——告诉你每个段落怎么写、哪些信息必须显式声明、哪些不能写。
>
> **适用场景**：新建角色、迭代优化角色、审查角色设计的可执行性
>
> **资产路径**：/Users/xiaopenglv/ai-agents/多角色配合系统/z-workspace/工作流编排原则/审计原则/skill编写规范.md

---

## 一、七段结构（必须齐全）

```
1. 角色定位      — 一句话说明角色是谁、做什么、产出什么
2. 入口判定      — 如何从 dispatch 注入的信息中判断本次执行上下文
3. 执行步骤      — 按什么顺序做、每步读什么/写什么
4. 产出物格式    — 每个输出文件的结构、字段、多路径策略
5. 输入消费指南  — dispatch 注入的每个输入文件的用途和读法
6. verdict 语义表 — 全集 + 触发条件 + 与 dispatch 动态过滤的关系
7. 自检项        — Gate 硬约束清单 + 软约束自检清单
```

> **v9.2 升级**：原五段（角色定位/执行步骤/知识引用/verdict表/自检项）→ 七段。新增"入口判定"和"产出物格式"两段，原"知识引用"合并到"输入消费指南"。

---

## 二、每一段怎么写

### 2.1 角色定位（一段话）

**目标**：让 role-executor 在 3 秒内理解"我是谁、我该干什么"。

```markdown
# {角色名} 执行指令

## 角色定位

你是 {系统} 的 {角色职责}。将 {输入} 转化为 {产出物}，作为 {下游角色} 的 {用途}。
```

**规则**：
- 一段话，不超过 3 行
- 必须说清：身份 + 输入来源 + 产出物 + 下游用途
- 不写实现细节（放执行步骤）

### 2.2 入口判定（多路径角色必写，单路径角色省略）

**目标**：让 role-executor 从 dispatch 注入的 `verdict_enum` 判断"我这次该走哪条路径"。

**什么时候需要**：角色的入边 > 1 条，或同一角色在不同入口路径下行为不同。

```markdown
## 入口判定（读 dispatch 的 verdict_enum）

> `verdict_enum` 由引擎动态过滤生成（max_executions + restrict_verdict）。
> 不同入口边决定了本次执行能看到的 verdict 集合。

| verdict_enum 内容 | 上下文 | 执行路径 |
|------------------|--------|--------|
| 含 passed/defect | 终态校验（从 all_passed 进入）| → 路径一 |
| 含 approved/rejected | 审批（从 unregistered 进入）| → 路径二 |
```

**规则**：
- 读 dispatch 的 `verdict_enum`，不读 STATE.json（role-executor 看不到 STATE）
- 每条路径只描述"做什么"，不展开步骤（步骤放执行步骤段）
- 单路径角色（只有一条入边）省略本段

### 2.3 执行步骤（核心段，按路径组织）

**目标**：逐步描述 role-executor 应执行的动作。

**单路径角色**：
```markdown
## 执行步骤

1. 读取 dispatch 注入的输入文件
2. 参考知识文档执行分析
3. 按产出物格式段的结构写入产出物
4. 按 verdict 语义表选择并返回 verdict
```

**多路径角色**：
```markdown
## 执行步骤

### 路径一：终态校验
1. 读取 dispatch 输入列表中的 L2 + 蓝图
2. 执行 4 项校验
3. 按产出物格式段写入裁决书（REQ-ID审批文件输出空对象）

### 路径二：REQ-ID 审批
1. 读取 dispatch 输入列表中的 L2 + 蓝图 + 架构师响应记录
2. 评估增补请求
3. 按产出物格式段写入审批文件（裁决书输出空对象）
```

**规则**：
- 每一步只写一个动作（读 / 分析 / 写 / 选 verdict）
- **不列举具体路径**（路径由 dispatch 权威注入）
- **不引用 STATE.json**（role-executor 无权限读）
- 写产出物用"按产出物格式段写入"引用，不重复结构定义
- knowledge 引用写为"参考《知识文档名》"，不写路径

### 2.4 产出物格式（必须显式，Gate 挡板）

**目标**：让 role-executor 知道每个输出文件的精确结构，确保 Gate 通过。

**单产出物角色**：
```markdown
## 产出物格式

产出物为 JSON，包含以下顶层字段：
- verdict: 从 dispatch 的 verdict_enum 中选择的值
- summary: 执行摘要（≥ 50 字符）
- findings: 校验发现列表（每项含 check_id / severity / description / evidence / suggested_fix）
- errors: 致命错误列表（可空）

JSON 示例：
{ "verdict": "confirmed", "summary": "...", "findings": [], "errors": [] }
```

**多产出物角色（双产物必产策略）**：
```markdown
## 产出物格式（双产物必产）

本角色声明了 2 个 outputs，每次执行必须同时产出两个文件。

| 产出物 | 内容规则 |
|--------|----------|
| 裁决书.json | 路径一填完整内容；路径二输出空对象 `{}` |
| 审批文件.json | 路径二填完整内容；路径一输出空对象 `{}` |

空对象示例：`{}`

完整对象示例：
{ "verdict": "approved", "new_req_id": "REQ-008", ... }
```

**规则**：
- **引擎 Gate 不支持按 verdict 分支产出不同文件集合**——声明的所有 outputs 每次都必须产出
- 多路径角色用**空对象 `{}` 占位**不适用路径的产出物
- 必须给出 JSON 示例（role-executor 按示例结构填充）
- **不写路径**（路径由 dispatch 的 `产出物路径` 段权威注入）

### 2.5 输入消费指南（必须显式）

**目标**：让 role-executor 知道 dispatch 注入的每个输入文件是什么、怎么用。

```markdown
## 输入消费指南

dispatch 输入列表可能包含以下文件（具体取决于 app.yaml 的 inputs + edge carries 声明）：

| 输入文件 | 用途 | 读法 |
|---------|------|------|
| L2需求规格.json | 基线需求 | 全文读取，提取 REQ-ID + acceptance_criteria |
| 蓝图.json | 架构设计 | 全文读取，提取模块清单 + 文档层级 |
| 校验报告.json | 返修依据（fail 边 carries） | 读取 result.findings，逐条修正 |
```

**规则**：
- 按输入来源分类：registry inputs（固定每轮都有）vs edge carries（仅回退路径有）
- 说明每个文件的**用途**和**关键字段**，不写路径
- 如果 carries 输入可能不存在，显式说明"如果输入列表为空，说明上游未通过 carries 传递"
- knowledge 文件作为输入时，说明它的**业务规则用途**

### 2.6 verdict 语义表（全集 + 语义 + 动态过滤关系）

**目标**：让 role-executor 理解每个 verdict 值的含义，并知道最终选择要服从 dispatch 的动态过滤。

```markdown
## verdict 语义表

| verdict | 含义 | 触发条件 | 路由目标 |
|---------|------|---------|----------|
| confirmed | 需求通过 | 所有验收标准满足 | → 下游角色 |
| challenged | 需求有缺陷 | 发现阻塞性问题 | → 上游修正（max: 2）|
| terminated | 强制终止 | 累计 ≥ 2 次回退 | → 完成 |

> **dispatch 动态过滤**：dispatch 的 `verdict_enum` 给出本次允许的子集。
> 例如回退 2 次后 `challenged` 可能被移除，此时只能选 `confirmed` 或 `terminated`。
> 始终从 dispatch 给出的允许值中选择。
```

**规则**：
- **写全集**（所有可能的 verdict 值），不写动态过滤后的子集
- 每个值必须有**含义 + 触发条件**
- 如果角色有 `max_executions` 限制的边，必须说明"该 verdict 被移除后的替代策略"
- manual confirm 角色标注"verdict 由用户确认行为驱动"

### 2.7 自检项（分硬约束 + 软约束）

**目标**：产出前自检，消除常见 Gate FAIL。

```markdown
## 自检项

### Gate 硬约束（违反 → 走 fail 边，自动回退）
- [ ] result.verdict ∈ dispatch 的 verdict_enum？
- [ ] 所有声明的 outputs 文件都已写入？（包括空对象占位）
- [ ] 产出物文件非空？

### 业务软约束（违反 → 质量下降但不阻断流程）
- [ ] summary ≥ 50 字符？
- [ ] findings 每项含 check_id / severity / description / evidence / suggested_fix？
- [ ] REQ-ID 匹配 ^REQ-\d{3,4}$？
- [ ] acceptance_criteria 可证伪？
```

**规则**：
- **硬约束**和**软约束**分组（让 role-executor 知道哪些是致命的）
- 硬约束项与 Gate 行为直接对应（verdict 合法性、文件存在性、非空）
- 软约束项是业务质量要求（字数、格式、可证伪性）

---

## 三、多路径角色编写模式（从实战提炼）

### 模式 1：verdict_enum 驱动入口判定

**场景**：同一角色有多个入边（如终审裁决者从"红队全过"和"REQ-ID 增补"两个路径进入）。

**写法**：
```markdown
## 入口判定（读 dispatch 的 verdict_enum）

| verdict_enum 内容 | 执行路径 |
|------------------|--------|
| 含 passed/defect | → 路径一 |
| 含 approved/rejected | → 路径二 |
```

**机制**：不同入边的 restrict_verdict 限定目标角色的 verdict 输出空间，dispatch 的 verdict_enum 反映了"从哪条边进来"。

### 模式 2：双产物必产 + 空对象占位

**场景**：多路径角色声明了多个 outputs，但每条路径只产出一部分。

**写法**：
```markdown
| 产出物 | 路径一 | 路径二 |
|--------|--------|--------|
| 裁决书 | 完整内容 | 空对象 `{}` |
| 审批文件 | 空对象 `{}` | 完整内容 |
```

**机制**：引擎 Gate 不支持按 verdict 分支产出不同文件集合，所有声明的 outputs 每次都必须产出。

### 模式 3：max_executions 收窄感知

**场景**：回退边有 `max_executions: 2`，第 3 次该 verdict 被 dispatch 的动态过滤移除。

**写法**：
```markdown
| verdict | 触发条件 | max_executions 用尽后 |
|---------|---------|---------------------|
| challenged | 发现缺陷 | 第 3 次起被移除 → 改选 terminated |
| terminated | 累计回退达限 | — |
```

**机制**：role-executor 通过 dispatch 的 verdict_enum 感知"某个 verdict 已不可选"，skill.md 提前说明替代策略。

### 模式 4：carries 物料的有无感知

**场景**：fail 边 carries 注入了校验报告，但首次执行（非回退路径）没有 carries。

**写法**：
```markdown
## 输入消费指南

| 输入 | 何时出现 | 用途 |
|------|---------|------|
| 校验报告 | 仅回退路径（fail 边 carries） | 按 findings 逐条修正 |
| （无 carries 时） | 首次执行 | 正常产出，不依赖校验报告 |
```

**机制**：role-executor 根据 dispatch 输入列表的有无判断当前上下文，不读 STATE.json。

---

## 四、编写禁忌（违反 → 与引擎不兼容）

| 禁忌 | 后果 | 正确做法 |
|------|------|---------|
| 硬编码产出物路径 | dispatch 路径与 skill 路径不一致 → 写错位置 | 只写文件名和格式，路径以 dispatch 为准 |
| 硬编码输入路径 | dispatch 不注入该路径 → 读不到文件 | 说明输入用途，路径由 dispatch 解析 |
| 引用 STATE.json | role-executor 无权限读 STATE → 执行失败 | 所有上下文从 dispatch 输入获取 |
| 引用 principles 机制 | principles 已删除 → 等待不存在的内联注入 | 用 knowledge inject_to 替代 |
| 写动态过滤后的 verdict 子集 | 某次执行 verdict_enum 变化 → 选了不存在的值 | 写全集 + 语义 + 动态过滤说明 |
| 只产出当前路径的文件 | Gate 检查所有 outputs → 缺文件 → FAIL | 双产物必产，空对象占位 |
| 假设会自动收到上游产出 | carries 未声明 → 输入列表为空 → 逻辑错误 | 检查 app.yaml 的 carries 声明 |

---

## 五、与其他资产的关系

| 资产 | 关系 |
|------|------|
| 《约束分层规范》| skill.md 是内容文件层，本规范定义其内部结构 |
| 《dispatch-skill 分工规范》| dispatch 注入什么 vs skill 提供什么的接口契约 |
| 《角色评审方法论》| C1 维度检查七段结构齐全性；F 维度检查 dispatch-skill 契约 |
| app.yaml | skill 的 verdict 语义表必须与 app.yaml edges 一致 |
| knowledge/*.md | skill 的知识引用必须在 app.yaml 的 inject_to 中声明 |

**核心理念**：**skill.md 是 role-executor 的唯一操作手册——它必须自洽、与引擎机制兼容、且不依赖任何 role-executor 看不到的信息。**
