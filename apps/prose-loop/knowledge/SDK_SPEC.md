# 多角色配合系统 — SDK 规范 v2.0

> **文档约束（不可变，修改需显式声明并附验证证据）**
>
> 1. **代码优先**：本文档描述引擎实际行为。所有字段、机制、流程必须与代码一一对应。修改本文档前必须先修改代码并验证。禁止先改文档再追代码。
> 2. **章节结构不可变**：以下 9 个章节的定义和边界不可增删、不可重排。如需新增内容，只能在现有章节内补充。如需新增章节，必须声明 SDK 大版本升级（v4.0）。
>    - §1 系统概述 / §2 原子概念 / §3 app.yaml 语法 / §4 编译产物格式 / §5 执行语义 / §6 STATE.json / §7 step.py 接口 / §8 schema.json / §9 Gate 校验
> 3. **权威分工**：app.yaml 语法在 `01-app-yaml编排范式.md` 中定义，本文档是其编译产物和执行语义的权威补充。
> 4. **版本递增**：编译产物格式有 breaking change 时递增 SDK 版本号。

---

## 1. 系统概述

### 1.1 这是什么

一个**规则驱动的有向图执行器**。

没有中心调度器。没有 join 节点。没有并行状态空间。只有三条规则：

| 规则 | 谁执行 | 做什么 |
|---|---|---|
| **边路由** | router.py | 沿 verdict 边找下一个候选目标 |
| **收敛检查** | orchestrator.py `_global_converge` | 目标的前置依赖（input_groups）是否都到了 |
| **计数控制** | router.py + STATE.edge_counts | 这条边还能不能走（max_executions） |

并行、汇聚、循环、回退——全部是这三条规则的自然涌现。

### 1.2 两个正交视角

| 文件 | 视角 | 回答什么问题 |
|---|---|---|
| **ROUTER.json** | 边（关系） | "我在 A，confirmed 后去哪？" |
| **registry.json** | 角色（实体） | "我是 D，什么条件满足才能执行？" |

加上运行时的 **STATE.json**（记录"走到哪了"），三者驱动整个工作流。

---

## 2. 原子概念

### 2.1 Role（角色）

一个执行单元。读文件、做事、写文件。定义在 registry.json 中。

属性：读什么（inputs）、写什么（outputs）、需不需要人工确认（blocking_mode）、产出怎么校验（gate_rules）、前置依赖是谁（input_groups）。

### 2.2 Edge（边）

两个 role 之间的连接。定义在 ROUTER.json 的 transitions 中。

属性：目标是谁（targets）、边类型（normal/backward）、携带什么物料（carries）、能走几次（max_executions）。

### 2.3 Verdict（裁决值）

角色执行后的结果信号。角色在 **role-executor 返回值**中输出 verdict（通过 step.py `--verdict` 参数传递）。产出物 JSON 仍需包含 `result.verdict` 供 Gate 格式校验，但**路由决策使用 role-executor 返回的 verdict 值**，而非产出物文件中的 `result.verdict` 字段。

> **职责分离**：Gate（gate.py）是格式守门员，只校验 `result.verdict` 字段格式是否合法。role-executor 返回的 verdict（通过 `--verdict` 参数）是路由决策的语义来源。两者职责独立。

verdict 直接作为 ROUTER.json transitions 的 key——"输出什么就走哪条边"。

> **`fail` 是系统保留词**：由 Gate FAIL 时引擎自动生成（走 backward 边）。角色不可以在 edges `when:` 中声明 `fail` 作为自定义条件路由值，也不可以在返回值中输出 `fail`（引擎会忽略并降级为 confirmed）。编译期会对此发出警告。

### 2.4 Finished（当前阶段已完成）

STATE.json 中的临时标记。记录"当前阶段哪些 step 已完成"。

**用完即消除**：dispatch 产出后，被消费的 finished 标记立即清除。不是永久记录。

---

## 3. app.yaml 语法

### 3.1 文件结构

```yaml
app_name: 应用名

knowledge:           # 公共知识文档（选择性注入到指定角色）
  - 名称: 路径
    inject_to: [角色A, 角色B]   # 仅注入列出的角色；省略 inject_to 则不注入

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
  - A → B when: result.verdict == "fail" max_executions: 5
  - A → 完成
```

### 3.2 角色字段

| 字段 | 必填 | 取值 | 说明 |
|---|---|---|---|
| `type` | 否 | `producer` / `standard` | producer 自动展开为 执行+校验 两个步骤 |
| `confirm` | 否 | `manual` / `auto` | manual 需用户确认后推进；auto 自动推进。默认 manual |
| `inputs` | 否 | `[名称: 路径]` | 角色正常执行所需的输入物料 |
| `outputs` | 必填 | `[名称: 路径]` | 角色的产出物料 |

> **inputs/outputs 的 `type` 字段**：每个物料项支持指定 `type` 字段，取值如下：
> - `deliverable`（默认）：正式交付物，路径解析为 `{WORKSPACE_ROOT}/{path}`。
> - `process`：运行时临时产出，路径解析为 `{WORKSPACE_ROOT}/process/{path}`，存放在 process 子目录中，用于分离正式交付物与运行时中间产物。

**不再包含的字段**：`verdicts`（只从 edges when: 提取）、`loop`（边级 max_executions）、`gate`（统一 PASS/FAIL）。

### 3.3 edges 四种原子模式

| 模式 | 语法 | 语义 |
|---|---|---|
| **单步前进** | `A → B` | A 完成后到 B |
| **并行扇出** | `A → [B, C, D]` | A 完成后同时启动 B/C/D |
| **同步汇入** | `[A, B, C] → D` | A/B/C **全部完成**后才执行 D |
| **终态出口** | `A → 完成` | A 完成后工作流结束 |

加 `when: result.verdict == "xxx"` → 条件路由。
加 `max_executions: N` → 边执行上限（超过则掐断）。

### 3.4 编译器自动行为

以下由 compiler.py 自动完成，开发者不需要在 app.yaml 中声明：

| 功能 | 触发条件 | 行为 |
|---|---|---|
| **fail 边生成** | 所有角色 | 自动生成 backward 边回到角色自身（Gate 格式错误只需修正重做），不设 max_executions。app.yaml 中显式声明的 fail 边仍使用 max_executions 默认值 3 |
| **carries 推导** | 所有边 | normal confirmed→gate result；normal custom-verdict→gate result + 源角色 process 产出物；backward→源产出+gate+用户反馈+target自身产出 |
| **input_groups 计算** | 所有 edges | `[A,B,C]→D` 记录为 AND 组；独立边各自为 OR 组 |
| **producer 展开** | `type: producer` | 自动创建校验角色 + 校验 step |
| **verdicts 提取** | edges 的 `when:` | 自动提取 verdict 值，同步到 schema.json enum + registry verdicts |
| **knowledge 注入** | 顶层 `knowledge:` | 按 `inject_to` 选择性合并到目标角色 inputs（缺省 `inject_to` 则不注入） |
| **骨架生成** | 所有角色 | 生成 skill.md / schema.json 骨架 |

---

## 4. 编译产物格式

### 4.1 ROUTER.json

DAG 拓扑 + 边元数据。

```json
{
  "schema_version": "2.0",
  "entry": "需求接收者",
  "steps": [
    {
      "step": "需求红队",
      "role": "需求红队",
      "transitions": {
        "confirmed": {
          "targets": ["架构执行者"],
          "type": "normal",
          "carries": [{"path": "outputs/需求红队-gate-result.json", "type": "deliverable"}]
        },
        "challenged": {
          "targets": ["裁决审计者"],
          "type": "normal",
          "carries": []
        },
        "fail": {
          "targets": ["需求接收者-validate"],
          "type": "backward",
          "max_executions": 3,
          "carries": [
            {"path": "outputs/对抗分析报告.json", "type": "feedback"},
            {"path": "outputs/需求红队-gate-result.json", "type": "feedback"}
          ]
        }
      }
    }
  ]
}
```

> **`{step}-gate-result.json`**：confirmed 边的 carries 中自动注入此文件。该文件由 Gate 校验后生成（详见 §9），包含 verdict + errors，是下游角色的重要反馈物料来源。

#### transitions[key] 字段

| 字段 | 类型 | 必填 | 引擎行为 |
|---|---|---|---|
| `targets` | array[string] | 是 | 目标 step ID 列表。空数组 = 终态出口 |
| `type` | string | 是 | `"normal"` = 前进；`"backward"` = 回退（编译器从 verdict 推断） |
| `carries` | array | 否 | 边携带的物料列表。router 读取并注入 dispatch inputs |
| `max_executions` | int | 否 | 边执行上限。达到后边被掐断，router 不再沿此边调度 |

#### carries[] 元素

| 字段 | 说明 |
|---|---|
| `path` | 物料文件相对路径 |
| `type` | `"deliverable"`、`"feedback"` 或 `"process"` |
| `name` | 物料名称（注入 task_prompt 时显示） |

### 4.2 registry.json

角色完整配置。

```json
{
  "role_name": "综合裁决者",
  "skill_path": "roles/综合裁决者/skill.md",
  "role_type": "standard",
  "principles": "roles/综合裁决者/principles.md",
  "blocking_mode": "auto",
  "outputs": [{"name": "审阅报告", "path": "outputs/审阅报告.json", "type": "deliverable"}],
  "inputs": [{"name": "需求文档", "path": "00-需求描述.md", "type": "deliverable"}],
  "gate_rules": {"phase1_cross_validation": {"enabled": true, "text_validation": {"min_size": 50}}},
  "input_groups": [["结构演化审阅者", "对抗闭环审阅者", "生长空间审阅者"]],
  "verdicts": ["confirmed", "conditional_pass", "requirement_defect"]
}
```

#### 角色字段

| 字段 | 类型 | 必填 | 引擎行为 |
|---|---|---|---|
| `role_name` | string | 是 | 角色名。与 ROUTER.json steps[].role 对应 |
| `skill_path` | string | 是 | skill 文件路径。dispatch 时注入 task_prompt |
| `role_type` | string | 否 | 编译器自动生成（`producer` / `standard`） |
| `principles` | string | 否 | 仅 producer 角色。编译器自动生成路径，router 注入 task_prompt |
| `blocking_mode` | string | 是 | `"auto"` = Gate PASS 后自动 advance；`"manual"` = 停下等用户确认 |
| `outputs` | array | 是 | 产出物定义。每个元素含 `name`/`path`/`type`（deliverable 或 process）。Gate 校验文件存在性 + 非空 |
| `inputs` | array | 否 | 输入物定义。每个元素含 `name`/`path`/`type`。dispatch 时注入 |
| `gate_rules` | object | 是 | Gate 校验规则（统一：文件存在 + 非空 + schema 可选） |
| `input_groups` | array | 否 | **目标视角前置依赖**。组内 AND、组间 OR。orchestrator `_global_converge` 消费 |
| `verdicts` | array | 否 | 条件路由可选值。编译器从 edges when: 提取 |

**不再包含的字段**：`feedback_inputs`（改用 edge.carries）、`schema_path`（按 roles/目录查找）。

#### input_groups 语义

```json
"input_groups": [
  ["A", "B", "C"],   // 组1：A∧B∧C 全部在 finished 中 → 满足
  ["E"]               // 组2：E 在 finished 中 → 满足
]
```

- 无 input_groups → 无前置依赖 → 直接放行
- 任一组的全部来源都在 finished 中 → 放行
- 否则 → 等待（返回 wait）

### 4.3 manifest.json

workspace 初始化模板。

```json
{
  "schema_version": "2.0",
  "app_name": "app-architect",
  "paths": {
    "router": "router.json",
    "registry": "registry.json"
  },
  "workspace_template": {
    "dirs": ["knowledge", "outputs"],
    "init_files": [],
    "knowledge_sources": [{"from": "knowledge/SDK_SPEC.md", "to": "knowledge/SDK_SPEC.md"}]
  }
}
```

| 字段 | 说明 |
|---|---|
| `paths` | 编译产物路径声明（router / registry 文件名） |
| `workspace_template.dirs` | workspace 初始化时创建的目录 |
| `workspace_template.init_files` | workspace 初始化时创建的空文件列表 |
| `workspace_template.knowledge_sources` | 知识文档拷贝源 → 目标映射 |

---

## 5. 执行语义

### 5.1 三阶段循环

```
Phase 1: dispatch
  ├─ 有 pending_dispatches 缓存 → 消费 finished → 直接执行
  └─ 无缓存 → 调 router → _global_converge → 消费 finished → set executing

主 Agent 执行 Task(role-executor)
  → role-executor 返回值中包含 verdict（通过 --verdict 参数传递给 step.py --submit）

Phase 2: post_execute
  ├─ gate PASS → 读 verdict（从 role-executor 返回值，非产出物文件）→ advance(写入 finished + verdict)
  │   ├─ auto 角色 → advance → 调 router 找下一步 → 缓存
  │   └─ manual 角色 → awaiting_confirmation → 等用户
  └─ gate FAIL → advance(verdict=fail) → 调 router 沿 fail 边 → 缓存

Phase 3: post_confirm
  ├─ 用户 confirmed → advance(verdict=confirmed) → 调 router → 缓存
  └─ 用户 rejected → advance(verdict=fail) → 调 router 沿 fail 边 → 缓存
```

> **verdict 读取来源**：Phase 2 中 "读 verdict" 指从 role-executor 返回值（step.py `--verdict` 参数）读取语义 verdict，用于路由决策。产出物 JSON 中的 `result.verdict` 仅被 Gate 用于格式校验，不用于路由。

### 5.2 advance 统一推进模型

**回退也是 advance**——只是 router 沿 verdict 边找到的恰好是上游 step。

```
gate PASS + verdict=challenged → advance → router 沿 challenged 边 → 找到裁决审计者
gate FAIL                      → advance → router 沿 fail 边 → 找到回退目标
用户 rejected                  → advance → router 沿 fail 边 → 找到回退目标
```

advance 做的事：step 从 executing 变成 finished，记录 verdict。

### 5.3 全局汇聚

orchestrator 的 `_global_converge` 读 registry 的 `input_groups`：

```
router 返回候选 [D]
→ _global_converge 检查 D.input_groups
→ [["A","B"]] → A 和 B 都在 finished 中？ → 是 → 放行 D
                                          → 否 → 过滤掉 D → 返回 wait
```

### 5.4 finished 用完即消除

dispatch 产出后，被消费的 finished 标记立即清除：

```
A 完成 → finished = {A}
       → dispatch B（B 消费了 A）
       → 清除 A 的 finished → finished = {}
       → B 完成 → finished = {B}
```

### 5.5 edge_counts 边级计数

每条有 max_executions 的边，STATE.json 中记录执行次数：

```json
"edge_counts": {
  "知识管理者.tracked": 2,
  "架构执行者.fail": 1
}
```

router 检查 edge_counts >= max_executions 时掐断该边，不再沿此边调度。

### 5.6 verdict_enum 动态过滤

router 组装 dispatch 时，根据 edge_counts 动态过滤 schema 的 verdict_enum：

```
schema.json: result.verdict.enum = ["tracked", "completed"]
ROUTER.json: tracked 边有 max_executions: 3

第 1-3 轮：edge_counts < 3
  → dispatch.schema_constraints.verdict_enum = ["tracked", "completed"]

第 4 轮：edge_counts = 3
  → tracked 边已掐断
  → dispatch.schema_constraints.verdict_enum = ["completed"]
  → 角色只能输出 completed
```

### 5.7 并行（自然涌现）

router 返回多个 dispatch = 并行。没有独立并行状态空间。

```
A → [B, C, D]

A 完成 → router 沿 A.confirmed 找到 [B, C, D]
       → _global_converge 全部放行（无 input_groups 依赖）
       → 返回 3 个 dispatch → 主 Agent 同时执行
```

嵌套并行也是同一条规则——B 内部再扇出，router 返回多个 dispatch。

### 5.8 退出

targets=[] 的边 → router 无候选 → 返回 `all_complete` → orchestrator 写 `terminal_state: "completed"`。

### 5.9 WORKSPACE_ROOT 路径解析

引擎使用 `WORKSPACE_ROOT` 机制分离两类目录：

| 目录 | 内容 | 定位方式 |
|---|---|---|
| **workspace 元数据目录** | `runtime/workspaces/{ws_id}/`，存放 STATE.json、APP_REF 等 | 固定路径 |
| **用户工作区目录** | WORKSPACE_ROOT 指向，存放 outputs/、process/ 等产出物 | 读取 `WORKSPACE_ROOT` 文件（元数据目录下）获取路径 |

产出物路径解析规则（`session_path.resolve_workspace_output`）：

| 物料 type | 解析路径 |
|---|---|
| `deliverable` | `{WORKSPACE_ROOT}/{path}` |
| `process` | `{WORKSPACE_ROOT}/process/{path}` |

Gate 也读取 WORKSPACE_ROOT 来定位 outputs 目录进行文件存在性校验。

---

## 6. STATE.json 格式

```json
{
  "schema_version": "4.0",
  "project_id": "当前项目目录名",
  "step_status": {
    "步骤ID": {"status": "executing", "role": "角色名", "dispatch_id": "ckpt_xxx", "started_at": "ISO时间"}
  },
  "finished": {
    "步骤ID": {"verdict": "confirmed", "role": "角色名", "id": "ckpt_xxx"}
  },
  "edge_counts": {
    "步骤ID.verdict": 2
  },
  "terminal_state": null,
  "pending_dispatches": null,
  "pending_branch_count": 0,
  "history": [],
  "metadata": {"started_at": "ISO时间", "user_request": "用户需求", "last_advance_at": null}
}
```

| 字段 | 说明 |
|---|---|
| `step_status` | 正在执行或等待确认的步骤。executing = 正在执行；awaiting_confirmation = 等用户确认 |
| `finished` | 当前阶段已完成的步骤（**用完即消除**）。dispatch 后被消费的标记立即清除 |
| `edge_counts` | 每条有 max_executions 的边的执行计数。key = `"步骤ID.verdict"` |
| `terminal_state` | 非空 = 工作流结束（completed） |
| `pending_dispatches` | Phase 2/3 产出的下一步 dispatch 缓存，Phase 1 消费 |
| `pending_branch_count` | 并行分支计数器（Hook② 消费）。运行时由 step.py 动态写入，初始模板中无此字段 |

---

## 7. step.py 接口

### --next：获取下一步指令

```bash
python engine/scripts/step.py --next --workspace-id WS_ID [--task-request "..."]
```

返回 JSON，action 字段决定下一步行为：

| action | 含义 |
|---|---|
| `delegate` | 有 task_prompt 需要执行（发起 Task） |
| `confirm` | 有步骤等待用户确认（展示给用户） |
| `complete` | 任务完成 |
| `wait` | 引擎无可调度步骤（等待其他分支完成） |
| `loop` | 状态已更新，需再次调 --next |
| `error` | 引擎错误（BLOCKING，向用户报告） |
| `unknown` | 未知状态（BLOCKING，向用户报告） |

### --submit：提交执行结果

```bash
python engine/scripts/step.py --submit --step 步骤ID --outputs '[{"name":"x","path":"y"}]' --verdict '<verdict值>' --workspace-id WS_ID [--dispatch-id <dispatch_id>]
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--step` | 是 | 步骤 ID |
| `--outputs` | 是 | 产出物 JSON 数组 `[{name, path}]` |
| `--verdict` | 是 | 角色 verdict 值，**从 role-executor 返回值读取**。路由决策的核心输入——未传入时所有角色按 confirmed 处理（条件路由失效） |
| `--workspace-id` | 是 | workspace ID |
| `--dispatch-id` | 否 | 可选幂等令牌。未传入时自动从 STATE.json 的 step_status 定位；找不到时跳过幂等检查，不阻塞流程 |

内部调 orchestrator post_execute（Gate 校验 + 状态推进）。

返回 JSON，action 字段可能取值：

| action | 含义 |
|---|---|
| `delegate` | 有下一步需执行 |
| `confirm` | 有步骤等待用户确认 |
| `complete` | 任务完成 |
| `wait` | 等待其他分支 |
| `error` | 引擎错误（BLOCKING） |
| `idempotent` | dispatch_id 已处理过，跳过（调 --next 推进） |
| `rework` | （遗留死代码，orchestrator 从不产生此值。Gate 失败时实际返回 `delegate`，携带 fail 边目标的重新 dispatch，主 Agent 按 `delegate` 正常处理即可） |

### --decide：提交用户确认决策

```bash
python engine/scripts/step.py --decide --decisions '[{"step":"步骤ID","decision":"confirmed|fail"}]' --workspace-id WS_ID
```

decision = confirmed → advance → router 找下一步。
decision = fail → advance(verdict=fail) → router 沿 fail 边找回退目标。

---

## 8. schema.json 格式

每个角色的产出物格式契约，存放在 `roles/{角色名}/schema.json`。

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["result"],
  "properties": {
    "result": {
      "type": "object",
      "required": ["verdict", "summary"],
      "properties": {
        "verdict": {"type": "string", "enum": ["confirmed", "challenged"]},
        "summary": {"type": "string"},
        "findings": {"type": "array"},
        "errors": {"type": "array"}
      }
    }
  }
}
```

Gate 读此文件校验产出物。router 读 `verdict.enum` 注入 dispatch 的 `schema_constraints`（含动态过滤）。

编译器从 edges 的 when: 表达式自动提取 verdict 值写入 enum。

> **注意**：`fail` 不会被写入 schema.json 的 enum（由编译器排除）。`fail` 是系统保留词，由 Gate FAIL 时引擎硬编码使用。

---

## 9. Gate 校验

Gate（gate.py）是产出物的格式守门员。只检查格式，不关心内容语义。

| 检查项 | 行为 |
|---|---|
| 文件存在 | 不存在 → FAIL |
| 文件非空 | 空文件 → FAIL |
| 最小长度 | 内容 < min_size（默认 50）→ FAIL |
| Schema 校验 | 有 schema.json → 校验 required + type + enum |

Gate 返回 PASS 或 FAIL。**不返回 PASS_FLAW**（已简化）。

**Gate 结果文件写入**：Gate 运行后，将校验结果（verdict + errors）写入 `{WORKSPACE_ROOT}/outputs/{step}-gate-result.json`。此文件通过 carries 机制（编译器对 confirmed 边自动注入）传递给下游角色，是重要的反馈物料来源。

Gate PASS 后，orchestrator 从 role-executor 返回值（`--verdict` 参数）读取语义 verdict 做条件路由。产出物中的 `result.verdict` 仅用于 Gate 格式校验，不用于路由决策。
Gate FAIL 后，orchestrator 硬编码 verdict=fail 走 backward 边。

**职责分离**：Gate 是格式守门员，角色 verdict 是内容决策者。
