# app.yaml 声明式编排范式

## 一、设计原则

### 1.1 唯一权威源

每条信息只在一个地方声明：

- **路由目标**：只写在 `edges` 段的边上，不写在角色定义中
- **条件路由值（verdict）**：只写在边的 `when:` 表达式中，角色不需要声明 `verdicts` 列表
- **循环上限**：只写在边的 `max_executions` 属性中，不使用角色级 `loop` 字段
- **物料携带**：只写在边的 `carries` 属性中（编译器自动推导），不在 registry 中手写 `feedback_inputs`

### 1.2 编译期确定性

所有确定性的路由、物料、同步约束均由 compiler.py 在编译期计算并写入 ROUTER.json 和 registry.json。运行时引擎（router.py / orchestrator.py）只读取，不推断。

### 1.3 边的平等性

所有边都是平等的连接，不存在 fail 边、loop 边等特殊类型。边的唯一差异由三个属性表达：

| 属性 | 说明 |
|---|---|
| `type` | `normal`（默认）或 `backward`（回退） |
| `carries` | 该边携带的物料列表 |
| `max_executions` | 该边最多执行次数，超过则掐断 |

---

## 二、文件结构

```yaml
app_name: 应用名

knowledge:           # 公共知识文档（选择性注入到指定角色）
  - 名称: 路径
    inject_to: [角色A, 角色B]   # 仅注入列出的角色；缺省 inject_to 则不注入

roles:               # 角色定义
  角色名:
    type: producer / standard
    confirm: manual / auto
    inputs:
      - 名称: 路径
    outputs:
      - 名称: 路径

edges:               # 路由编排（唯一权威源）
  - A → B
  - A → [B, C]
  - [A, B] → C
  - A → B when: result.verdict == "xxx"
  - A → B when: result.verdict == "fail" max_executions: 5   # 声明边级执行上限
  - A → 完成
```

---

## 三、角色定义（roles）

### 3.1 字段清单

| 字段 | 必填 | 取值 | 说明 |
|---|---|---|---|
| `type` | 否 | `producer` / `standard` | producer 自动展开为 执行+校验 两个步骤（详见 §3.5） |
| `confirm` | 否 | `manual` / `auto` | manual 需用户确认后推进；auto 自动推进。默认 manual |
| `inputs` | 否 | `[名称: 路径]` | 角色正常执行所需的输入物料 |
| `outputs` | 必填 | `[名称: 路径]` | 角色的产出物料 |

### 3.2 物料类型

inputs/outputs 列表项支持两种物料类型：

```yaml
inputs:
  - 需求文档: 00-需求描述.md                        # 默认 deliverable
  - 运行时日志: outputs/xxx.log, type=process      # 运行时临时产出
```

| 类型 | 默认 | 运行时路径 | 说明 |
|---|---|---|---|
| `deliverable` | 是 | `{workspace_root}/{path}` | 正式交付物，存放在 workspace 根目录 |
| `process` | 否 | `{workspace}/process/{path}` | 运行时临时产出，存放在 process 子目录 |

### 3.3 不再包含的字段

| 已删除字段 | 原因 |
|---|---|
| `verdicts` | 条件路由值只写在边的 `when:` 中，保证唯一权威源 |
| `loop` | 循环上限只写在边的 `max_executions` 中 |
| `gate` | Gate 只有 PASS/FAIL 二元结果，无需分级 |

### 3.4 示例

```yaml
roles:
  需求接收者:
    type: producer
    confirm: manual
    outputs:
      - 需求文档: 00-需求描述.md

  架构执行者:
    type: standard
    confirm: auto
    inputs:
      - 需求文档: 00-需求描述.md
    outputs:
      - App架构文件: app.yaml

  需求红队:
    type: standard
    confirm: auto
    inputs:
      - 需求文档: 00-需求描述.md
    outputs:
      - 对抗分析报告: outputs/需求红队-对抗分析报告.json
```

### 3.5 producer 自动校验角色

`type: producer` 的角色在编译期自动展开为两个 step：

```
执行STEP（confirmed）→ 校验STEP（confirmed/fail）→ 下游角色
                                        ↓ fail
                                   回退到执行STEP
```

编译器自动行为：

- **校验角色名**：`{原角色名}（校验）`，如 `需求接收者` → `需求接收者（校验）`
- **校验角色 verdict**：固定为 `confirmed`/`fail` 二元结果
- **校验角色 inputs**：自动继承执行角色的 outputs
- **校验角色 outputs**：自动生成 `{原角色名}-validation.json`
- **用户显式定义**：如果开发者在 roles 中显式定义了 `{角色名}（校验）` 角色，编译器使用用户定义的数据（skill/inputs/outputs），仅追加元数据标记 `_is_validator`

---

## 四、路由编排（edges）

### 4.1 四种原子模式

#### 模式 1：单步前进

```
A → B
```

A 完成后执行 B。生成一条 `normal` 边。

#### 模式 2：并行扇出

```
A → [B, C, D]
```

A 完成后同时启动 B、C、D。生成一条多 target 的 `normal` 边。

#### 模式 3：同步汇入

```
[A, B, C] → D
```

A、B、C **全部完成**后才执行 D。编译器展开为三条独立边，同时在 D 上标注 `input_groups`。

> 同步汇入是无条件的——只要多个来源指向同一目标且声明了同步约束，就必须全部到达。

#### 模式 4：终态出口

```
A → 完成
```

A 完成后工作流结束。生成 targets 为空的 `normal` 边。

### 4.2 条件路由

在边上用 `when:` 声明条件。角色的条件路由值（verdict）只出现在这里：

```yaml
edges:
  - 需求红队 → 架构执行者 when: result.verdict == "confirmed"
  - 需求红队 → 裁决审计者 when: result.verdict == "challenged"
```

角色本身不需要声明 `verdicts: [confirmed, challenged]`——边的 `when:` 表达式已经是唯一权威源。编译器自动从 edges 中提取 verdict 值，同步到 schema.json 的 enum 和 registry 的 verdicts 字段。

### 4.3 条件组合

| 组合写法 | 效果 |
|---|---|
| `A → B when: ... == "xxx"` | 仅特定 verdict 时走这条边 |
| `A → [B,C] when: ... == "xxx"` | 仅特定 verdict 时并行扇出 |
| 多条 `A → X when: ...` | 互斥条件路由（同一时刻只走一条） |

### 4.4 完整示例

```yaml
edges:
  # 顺序链
  - 需求接收者 → 需求接收者（校验）
  - 需求接收者（校验）→ 需求红队 when: result.verdict == "confirmed"
  - 需求接收者（校验）→ 需求接收者 when: result.verdict == "fail"

  # 条件路由
  - 需求红队 → 架构执行者 when: result.verdict == "confirmed"
  - 需求红队 → 裁决审计者 when: result.verdict == "challenged"

  # 并行扇出
  - 端到端模拟验证者 → 架构版本管理者 when: result.verdict == "validated"
  - 端到端模拟验证者 → 架构红队 when: result.verdict == "validated"

  # 同步汇入（三个审阅者全部完成才执行综合裁决者）
  - [结构演化审阅者, 对抗闭环审阅者, 生长空间审阅者] → 综合裁决者

  # 终态
  - 知识管理者 → 完成 when: result.verdict == "tracked"
```

---

## 五、边的属性

### 5.1 编译后的边结构（ROUTER.json）

```json
{
  "transitions": {
    "confirmed": {
      "targets": ["架构执行者"],
      "type": "normal",
      "carries": [
        {"path": "outputs/需求红队-gate-result.json", "type": "deliverable"}
      ],
      "max_executions": null
    },
    "fail": {
      "targets": ["需求接收者"],
      "type": "backward",
      "carries": [
        {"path": "outputs/对抗分析报告.json", "type": "feedback"},
        {"path": "outputs/需求红队-gate-result.json", "type": "feedback"},
        {"path": "outputs/需求接收者-validation.json", "type": "feedback"}
      ],
      "max_executions": 3
    }
  }
}
```

### 5.2 属性说明

#### type: normal / backward

- **normal**：默认边类型。沿 DAG 前进方向。
- **backward**：回退边。编译器根据拓扑自动推断（fail/fail_* verdict 的边为 backward）。

> type 不在 app.yaml 中手写——编译器从 verdict 语义自动推断。

#### carries: 携带物料

编译器自动推导，不在 app.yaml 中手写：

- **normal confirmed 边**：自动携带上游 gate-result（Gate 校验详情，供下游角色参考）
- **backward 边**：自动携带源角色产出 + gate 结果 + 用户反馈（仅 manual 角色）+ target 自身上一轮产出

> Gate 是 PASS/FAIL 二态校验。gate-result.json 包含 verdict 和 errors 数组，通过 carries 注入给下游。

#### max_executions: 执行上限

在边上用 `max_executions:` 声明。适用于 normal 和 backward 边。

```yaml
edges:
  - A → B when: result.verdict == "fail" max_executions: 5
```

- **声明了 max_executions 的 backward 边**：使用声明的值
- **未声明的 backward 边**：默认 3 次
- **normal 边**：可用于控制循环/重试次数上限（如条件路由边的执行上限）
- 超过上限的边会被 router 掐断，不再调度

> 这是唯一的循环/重做控制机制。不存在独立的 loop 概念。

---

## 六、同步约束

### 6.1 两种来源

| 来源 | 语法 | 机制 |
|---|---|---|
| **显式声明** | `[A, B, C] → D` | 编译器展开为独立边 + 在 D 上写 input_groups |
| **隐式推断** | fork 点扇出后汇聚 | 编译器 BFS 可达集分析，自动计算 input_groups |

### 6.2 input_groups 语义

```
组内 AND：同一组内所有来源全部完成才能调度
组间 OR：任一组满足即可调度
```

示例：`(A1 ∧ A2 ∧ A3) ∨ B`

```json
"input_groups": [
  ["A1", "A2", "A3"],
  ["B"]
]
```

### 6.3 orchestrator 汇集阶段检查

orchestrator 在全局汇集阶段读取 registry 的 `input_groups` 判断每个候选是否满足执行条件：

```python
if input_groups:
    if from_step not in any group:   # 独立来源 → 直接放行
        pass
    elif any(group ⊆ finished):     # 任一组全完成 → 放行
        pass
    else:                             # 等待
        continue
```

---

## 七、编译器自动行为

以下功能由 compiler.py 在编译期自动完成，开发者无需在 app.yaml 中声明：

| 功能 | 触发条件 | 行为 |
|---|---|---|
| **fail 边生成** | 所有角色 | 从 confirmed 来源反推，自动生成 backward 边 |
| **carries 推导** | 所有边 | normal→gate result；backward→源产出+gate+用户反馈+自身产出 |
| **input_groups 计算** | fork 扇出 + 显式 `[A,B,C]→D` | BFS 可达集分析 + 显式声明合并 |
| **producer 展开** | `type: producer` | 自动创建校验角色 + 校验 step |
| **verdicts 同步** | edges 中的 `when:` 表达式 | 自动提取 verdict 值，同步到 schema.json enum 和 registry verdicts 字段 |
| **knowledge 注入** | 顶层 `knowledge:` 段 | 按 `inject_to` 选择性合并到目标角色 inputs；缺省 `inject_to` 则不注入 |
| **骨架生成** | 所有角色 | 生成 skill.md / schema.json 骨架 |
| **manifest 目录** | 全部 inputs/outputs | 自动收集目录结构 |

---

## 八、范式总结

```
app.yaml = roles（角色物料声明） + edges（路由拓扑）

edges 只需 4 种原子写法：
  A → B              单步前进
  A → [B, C, D]      并行扇出
  [A, B, C] → D      同步汇入
  A → 完成            终态出口

加 when: 条件表达式 → 条件路由

编译器全自动：
  fail 边反推 / carries 推导 / input_groups 计算 /
  producer 展开 / verdicts 同步 / 骨架生成
```
