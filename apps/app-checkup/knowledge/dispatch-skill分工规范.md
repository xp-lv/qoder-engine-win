# Dispatch-Skill 分工规范

> 本规范明确运行时信息传递的双轨制：**dispatch 指令**（引擎生成）与 **skill.md**（手写内容）各负责什么，以及两者之间的契约边界。
>
> 源自评审中发现的结构性盲区：审计原则只覆盖文件层面（schema/registry/ROUTER vs skill/principles/knowledge），未覆盖运行时的 dispatch→skill 数据传递。
>
> **资产路径**：/Users/xiaopenglv/ai-agents/多角色配合系统/z-workspace/工作流编排原则/审计原则/dispatch-skill分工规范.md

---

## 一、核心分工原则

**角色执行 = dispatch 提供确定性上下文 + skill 提供业务方法**

| 信息轨 | 来源 | 性质 | 生成时机 |
|---------|------|------|---------|
| **Dispatch 指令** | 引擎（router.py → step.py `_build_task_prompt`）| 确定性、编译期可推 | 运行时（每次 --next） |
| **Skill.md** | 人工编写 | 创造性、业务方法 | 设计时（compiler 不覆盖） |

role-executor 收到的是 `_build_task_prompt` 生成的 **task_prompt**（一个完整的 markdown 字符串），其中同时包含 dispatch 上下文和 skill 引用。

---

## 二、Dispatch 指令负责什么（引擎生成，role-executor 直接消费）

`step.py:_build_task_prompt` 根据 `router.py` 产出的 dispatch_instruction 组装以下信息：

### 2.1 确定性上下文（dispatch 独占，skill.md 不应重复）

| 字段 | dispatch 提供的内容 | skill.md 的正确姿态 |
|------|-------------------|-------------------|
| **step** | 步骤 ID（如 `需求分析师`）| 引用 `{step}` 变量，不硬编码 |
| **skill 路径** | skill.md 的绝对路径 | skill 自身就是被读取方 |
| **产出物路径** | **权威绝对路径**（从 registry outputs 解析） | skill 中的相对路径仅作参考，**以 dispatch 路径为准** |
| **schema 约束** | 必填字段 + verdict 允许值（**已动态过滤**）| skill verdict 表应说明语义，不列举动态过滤后的值 |
| **输入文件** | 解析后的绝对路径列表（registry inputs + edge carries）| skill 中说明如何使用输入，不列举路径 |
| ~~principles~~ | ~~v9.2 已删除~~（用 knowledge inject_to 替代） | 如需原则指导，在 knowledge 中声明 inject_to |

| **用户需求** | task_context.user_request 原文 | skill 不硬编码需求 |

### 2.2 动态过滤机制（dispatch 独有，skill 无法预知）

dispatch 的 `schema_constraints.verdict_enum` 经历了两层动态过滤：

```
编译期：从 edges 提取原始 verdict 集合
    ↓
运行期过滤 1：max_executions 达限的 verdict 被移除
    ↓
运行期过滤 2：verdict_context（边级 restrict_verdict）限定输出空间
    ↓
最终 verdict_enum 交给 role-executor
```

**关键含义**：skill.md 的 verdict 表描述的是**全集**，而 dispatch 每次只给出**当前允许的子集**。role-executor 必须从 dispatch 的 `verdict_enum` 中选择，不能自行决定。

### 2.3 carries 物料注入（编译期声明，运行时解析）

```
app.yaml 边级声明：  carries: [outputs/校验报告.json]
      ↓ compiler.py
ROUTER.json edge：   "carries": [{"path": "outputs/校验报告.json"}]
      ↓ router.py
dispatch inputs：    ["/abs/path/outputs/校验报告.json"]
      ↓ step.py
task_prompt：        "## 输入文件\n- /abs/path/outputs/校验报告.json"
```

不写 carries 的边 → 下游零物料注入。skill.md 不能假设"会自动收到上游产出物"。

---

## 三、Skill.md 负责什么（手写内容，dispatch 不涉及）

### 3.1 业务方法（skill 独占）

| 内容 | 说明 |
|------|------|
| **执行步骤** | 角色做什么、按什么顺序做（创造性的业务方法） |
| **知识引用** | 需要读取哪些 knowledge 文档（显式清单） |
| **verdict 语义表** | 每个 verdict 值的含义和触发条件（全集，非动态过滤后的子集） |
| **自检项** | 产出质量的自检清单（软约束，放 skill 不放 schema） |
| **SDK 陷阱警告** | 常见错误和规避方法 |

### 3.2 skill.md 不应包含的内容（dispatch 重复 = 冗余设计 D2）

| ❌ 禁止内容 | 原因 | 正确做法 |
|-----------|------|---------|
| 硬编码的产出物路径 | dispatch 已提供权威绝对路径 | 只写文件名和格式说明 |
| 硬编码的输入文件路径 | dispatch 从 registry + carries 解析 | 只说明输入的用途和读法 |
| 动态过滤后的 verdict 子集 | dispatch 经 max_executions + verdict_context 过滤 | 写 verdict 全集 + 语义 |
| principles 全文 | ~~v9.2 已删除~~（用 knowledge inject_to 替代原则注入） | 如需原则，在 knowledge 中声明 inject_to |

| 用户需求原文 | dispatch 注入 task_context.user_request | 只说明如何理解需求 |

---

## 四、两轨契约（dispatch ↔ skill 的接口约定）

### 4.1 路径权威源契约

```
dispatch.output_targets  >  skill.md 中的相对路径
```

role-executor 收到 task_prompt 后：
1. **产出物路径**：必须严格按 dispatch 的 `产出物路径` 段写入，**禁止自行截取/修改/拼接**
2. **输入文件路径**：必须从 dispatch 的 `输入文件` 段读取，不能猜测路径

### 4.2 verdict 选择契约

```
dispatch.schema_constraints.verdict_enum  >  skill.md verdict 表
```

role-executor 选择 verdict 时：
1. 从 dispatch 的 `verdict 允许值` 中选择（经动态过滤后的子集）
2. 用 skill.md 的 verdict 语义表理解每个值的含义和触发条件

### 4.3 knowledge 原则注入（v9.2 替代 principles）

| app.yaml 声明 | dispatch 行为 | skill.md 行为 |
|-------------|-------------|-------------|
| `knowledge` 段有 inject_to 角色A | compiler 注入到 registry inputs → dispatch 解析路径注入 | skill 知道输入列表会包含该 knowledge 文件 |
| 未声明 inject_to | 不注入 | skill 不应假设会自动收到 knowledge |

### 4.4 输入物料消费契约

| 输入来源 | dispatch 注入方式 | skill.md 应说明 |
|---------|-----------------|---------------|
| **registry inputs** | 从 registry.json 的 `inputs` 数组解析 | 每个输入文件的用途和读法 |
| **edge carries**（v8.4 显式声明）| 从 ROUTER.json edge.carries 解析 | carries 物料的含义（如校验报告 = 返修依据） |
| **无 carries 的边** | 零物料注入 | 不应假设会自动收到上游产出 |

---

## 五、违规案例与正确做法

### 案例 1：skill 硬编码产出物路径

```markdown
# ❌ 错误（skill 硬编码路径）
## 产出物
写入 outputs/需求分析师/需求分析报告.json

# ✅ 正确（dispatch 权威路径，skill 只说明格式）
## 产出物格式
产出物为 JSON 格式，包含以下字段：
- summary: 摘要
- requirements: 需求列表
（路径以 dispatch 指令中的权威路径为准）
```

### 案例 2：skill 列举动态过滤后的 verdict

```markdown
# ❌ 错误（skill 写死动态子集）
## verdict
本次只能从以下值中选择：confirmed, challenged
（如果 max_executions 到限或 verdict_context 过滤后会变化）

# ✅ 正确（skill 写全集 + 语义，dispatch 给子集）
## verdict 语义表
| verdict | 含义 | 触发条件 |
|---------|------|---------|
| confirmed | 需求确认通过 | 所有验收标准满足 |
| challenged | 需求存在缺陷 | 发现阻塞性问题 |

> dispatch 指令会给出本次允许的 verdict 子集（经 max_executions + verdict_context 过滤）。
```

### 案例 3：skill 假设会自动收到上游产出物

```markdown
# ❌ 错误（假设 carries 自动注入）
## 执行步骤
1. 读取上游架构师的产出物

# ✅ 正确（显式说明输入来源）
## 执行步骤
1. 读取 dispatch 注入的输入文件（如果列表中包含架构师产出物）
2. 如果输入列表为空，说明上游未通过 carries 声明物料传递
```

### 案例 4：skill 依赖已被删除的 principles 机制

```markdown
# ❌ 错误（principles 机制已删除，dispatch 不再内联注入）
## 执行步骤
1. 按 dispatch 注入的原则指导执行（已内联在指令中）

# ✅ 正确（使用 knowledge inject_to 机制）
## 执行步骤
1. 读取 dispatch 输入列表中的 knowledge 文件（如已通过 inject_to 注入）
2. 如果输入列表不含该文件，说明 app.yaml 未声明 inject_to
```

---

## 六、检查流程（评审 skill.md 时必做）

```
1. skill 是否硬编码了产出物路径？
   ├─ 是 → ❌ 删除，改为格式说明（路径以 dispatch 为准）
   └─ 否 → ✅

2. skill 的 verdict 表是否写了全集 + 语义？
   ├─ 只写了子集 → ❌ 补全全集
   ├─ 写了全集但无语义 → ❌ 补充触发条件
   └─ 全集 + 语义 → ✅

3. skill 是否假设会自动收到上游产出物？
   ├─ 是 → ❌ 检查 app.yaml 的 carries 声明是否匹配
   └─ 否 → ✅

4. skill 是否引用了 principles？
   ├─ 是 → ❌ principles 机制已删除，改用 knowledge inject_to
   └─ 否 → ✅

5. skill 是否列举了输入文件路径？
   ├─ 是 → ❌ 改为说明用途（路径由 dispatch 解析）
   └─ 否 → ✅
```

---

## 七、与其他资产的关系

| 资产 | 关系 |
|------|------|
| 《约束分层规范》| 文件层面的约束分层（什么放 schema/registry/ROUTER vs skill/principles/knowledge） |
| 本规范 | **运行时层面**的信息分工（dispatch 注入什么 vs skill 提供什么） |
| 《skill 编写规范》| skill.md 七段结构的编写方法与多路径模式 |
| 《角色评审方法论》| F 维度检查 dispatch-skill 契约一致性 |

**核心理念**：**dispatch 提供"确定性的 What/Where"，skill 提供"创造性的 How/Why"**。
