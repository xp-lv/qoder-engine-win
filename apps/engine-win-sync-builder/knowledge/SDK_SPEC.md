# 多角色配合系统 — SDK 规范 v2.0

> **文档约束（不可变，修改需显式声明并附验证证据）**
>
> 1. **代码优先**：本文档描述引擎实际行为。所有字段、机制、流程必须与代码一一对应。
> 2. **章节结构不可变**：以下 9 个章节的定义和边界不可增删、不可重排。
>    - §1 系统概述 / §2 原子概念 / §3 app.yaml 语法 / §4 编译产物格式 / §5 执行语义 / §6 STATE.json / §7 step.py 接口 / §8 schema.json / §9 Gate 校验
> 3. **权威分工**：app.yaml 语法在 `编排范式.md` 中定义，本文档是其编译产物和执行语义的权威补充。

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

### 1.2 两个正交视角

| 文件 | 视角 | 回答什么问题 |
|---|---|---|
| **ROUTER.json** | 边（关系） | "我在 A，confirmed 后去哪？" |
| **registry.json** | 角色（实体） | "我是 D，什么条件满足才能执行？" |

---

## 2. 原子概念

### 2.1 Role（角色）

一个执行单元。读文件、做事、写文件。定义在 registry.json 中。

属性：读什么（inputs）、写什么（outputs）、需不需要人工确认（blocking_mode）、产出怎么校验（gate_rules）、前置依赖是谁（input_groups）。

### 2.2 Edge（边）

两个 role 之间的连接。定义在 ROUTER.json 的 transitions 中。

属性：目标是谁（targets）、边类型（normal/backward）、携带什么物料（carries）、能走几次（max_executions）。

### 2.3 Verdict（裁决值）

角色执行后的结果信号。verdict 直接作为 ROUTER.json transitions 的 key——"输出什么就走哪条边"。

> **`fail` 是系统保留词**：由 Gate FAIL 时引擎自动生成（走 backward 边）。角色不可以在 edges `when:` 中声明 `fail` 作为自定义条件路由值。

### 2.4 Finished（当前阶段已完成）

STATE.json 中的临时标记。**用完即消除**：dispatch 产出后，被消费的 finished 标记立即清除。

---

## 3. app.yaml 语法

### 3.1 文件结构

```yaml
app_name: 应用名

knowledge:           # 公共知识文档（选择性注入到指定角色）
  - 名称: 路径
    inject_to: [角色A, 角色B]

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
  - A → 完成
```

### 3.2 角色字段

| 字段 | 必填 | 取值 | 说明 |
|---|---|---|---|
| `type` | 否 | `producer` / `standard` | producer 自动展开为 执行+校验 两个步骤 |
| `confirm` | 否 | `manual` / `auto` | manual 需用户确认后推进；auto 自动推进。默认 manual |
| `inputs` | 否 | `[名称: 路径]` | 角色正常执行所需的输入物料 |
| `outputs` | 必填 | `[名称: 路径]` | 角色的产出物料 |

> **inputs/outputs 的 `type` 字段**：`deliverable`（默认，路径解析为 `{WORKSPACE_ROOT}/{path}`）或 `process`（路径解析为 `{WORKSPACE_ROOT}/process/{path}`）。

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

| 功能 | 触发条件 | 行为 |
|---|---|---|
| **fail 边生成** | 所有角色 | 自动生成 backward 边回到角色自身 |
| **carries 推导** | 所有边 | normal→gate result；backward→源产出+gate+用户反馈+target自身产出 |
| **input_groups 计算** | 所有 edges | `[A,B,C]→D` 记录为 AND 组；独立边各自为 OR 组 |
| **producer 展开** | `type: producer` | 自动创建校验角色 + 校验 step |
| **verdicts 提取** | edges 的 `when:` | 自动提取 verdict 值，同步到 schema.json enum + registry verdicts |
| **knowledge 注入** | 顶层 `knowledge:` | 按 `inject_to` 选择性合并到目标角色 inputs |
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
      "step": "差异红队",
      "role": "差异红队",
      "transitions": {
        "confirmed": {
          "targets": ["平台适配者"],
          "type": "normal",
          "carries": [{"path": "outputs/差异红队-gate-result.json", "type": "deliverable"}]
        },
        "challenged": {
          "targets": ["差异分析者"],
          "type": "backward",
          "max_executions": 3,
          "carries": [
            {"path": "outputs/差异红队-对抗报告.json", "type": "feedback"},
            {"path": "outputs/差异红队-gate-result.json", "type": "feedback"}
          ]
        }
      }
    }
  ]
}
```

### 4.2 registry.json

角色完整配置。

```json
{
  "role_name": "平台适配者",
  "skill_path": "roles/平台适配者/skill.md",
  "role_type": "standard",
  "blocking_mode": "auto",
  "outputs": [{"name": "同步设计文档", "path": "outputs/同步设计文档.json", "type": "process"}],
  "inputs": [
    {"name": "改进评估报告", "path": "outputs/改进评估报告.json", "type": "process"},
    {"name": "对抗报告", "path": "outputs/差异红队-对抗报告.json", "type": "process"}
  ],
  "input_groups": [["改进评估者", "差异红队"]],
  "verdicts": ["confirmed"]
}
```

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
  "app_name": "engine-win-sync-builder",
  "paths": {
    "router": "router.json",
    "registry": "registry.json"
  },
  "workspace_template": {
    "dirs": ["knowledge", "outputs", "roles"],
    "init_files": [],
    "knowledge_sources": [
      {"from": "knowledge/编排范式.md", "to": "knowledge/编排范式.md"},
      {"from": "knowledge/SDK_SPEC.md", "to": "knowledge/SDK_SPEC.md"},
      {"from": "knowledge/Windows平台适配知识.md", "to": "knowledge/Windows平台适配知识.md"}
    ]
  }
}
```

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
  ├─ gate PASS → 读 verdict → advance(写入 finished + verdict)
  │   ├─ auto 角色 → advance → 调 router 找下一步 → 缓存
  │   └─ manual 角色 → awaiting_confirmation → 等用户
  └─ gate FAIL → advance(verdict=fail) → 调 router 沿 fail 边 → 缓存

Phase 3: post_confirm
  ├─ 用户 confirmed → advance(verdict=confirmed) → 调 router → 缓存
  └─ 用户 rejected → advance(verdict=fail) → 调 router 沿 fail 边 → 缓存
```

### 5.2 advance 统一推进模型

**回退也是 advance**——只是 router 沿 verdict 边找到的恰好是上游 step。

### 5.3 全局汇聚

orchestrator 的 `_global_converge` 读 registry 的 `input_groups`：

```
router 返回候选 [D]
→ _global_converge 检查 D.input_groups
→ [["A","B"]] → A 和 B 都在 finished 中？ → 是 → 放行 D
                                          → 否 → 过滤掉 D → 返回 wait
```

### 5.4 并行（自然涌现）

router 返回多个 dispatch = 并行。没有独立并行状态空间。

### 5.5 退出

targets=[] 的边 → router 无候选 → 返回 `all_complete` → orchestrator 写 `terminal_state: "completed"`。

### 5.6 WORKSPACE_ROOT 路径解析

| 物料 type | 解析路径 |
|---|---|
| `deliverable` | `{WORKSPACE_ROOT}/{path}` |
| `process` | `{WORKSPACE_ROOT}/process/{path}` |

---

## 6. STATE.json 格式

```json
{
  "schema_version": "4.0",
  "project_id": "当前项目目录名",
  "step_status": {
    "步骤ID": {"status": "executing", "role": "角色名", "dispatch_id": "ckpt_xxx"}
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
  "metadata": {"started_at": "ISO时间", "user_request": "用户需求"}
}
```

---

## 7. step.py 接口

### --next：获取下一步指令

```bash
python engine/scripts/step.py --next --workspace-id WS_ID
```

返回 JSON，action 字段决定下一步行为：`delegate` / `confirm` / `complete` / `wait` / `loop` / `error`

### --submit：提交执行结果

```bash
python engine/scripts/step.py --submit --step 步骤ID --outputs '[{"name":"x","path":"y"}]' --verdict '<verdict值>' --workspace-id WS_ID
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--step` | 是 | 步骤 ID |
| `--outputs` | 是 | 产出物 JSON 数组 `[{name, path}]` |
| `--verdict` | 是 | 角色 verdict 值 |
| `--workspace-id` | 是 | workspace ID |

### --decide：提交用户确认决策

```bash
python engine/scripts/step.py --decide --decisions '[{"step":"步骤ID","decision":"confirmed|fail"}]' --workspace-id WS_ID
```

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

Gate 读此文件校验产出物。router 读 `verdict.enum` 注入 dispatch 的 `schema_constraints`。

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

Gate 返回 PASS 或 FAIL。

**Gate 结果文件写入**：Gate 运行后，将校验结果写入 `{WORKSPACE_ROOT}/outputs/{step}-gate-result.json`。

Gate PASS 后，orchestrator 从 role-executor 返回值读取语义 verdict 做条件路由。
Gate FAIL 后，orchestrator 硬编码 verdict=fail 走 backward 边。

**职责分离**：Gate 是格式守门员，角色 verdict 是内容决策者。

---

## 附录：引擎仓库全目录结构与同步规则

### 同步范围总览

**Mac 源仓库**：`git@github.com:xp-lv/qoder-engine.git`（GitHub 最新代码，克隆到 `mac-repo-clone/`）
**Win 目标仓库**：`git@github.com:xp-lv/qoder-engine-win.git`（克隆到 `win-repo-clone/`）

> **重要**：差异分析和同步的 Mac 侧基准始终是 `mac-repo-clone/`（GitHub 最新版），不是当前工作区的本地文件。

qoder-engine 仓库包含三大顶层目录，全部纳入 Mac→Win 同步范围：

| 目录 | 职责 | 同步策略 |
|---|---|---|
| `engine/` | 引擎核心代码（scripts + sdk + schemas） | 全量同步，含平台适配 |
| `apps/` | 全部 APP 应用（每个 APP 含 roles/knowledge/outputs 等） | 全量同步，.py/.md/.json/.yaml 文件均需同步 |
| `.qoder/` | 引擎运行时配置（agents + hooks + rules + settings） | 全量同步，含平台适配 |

### scripts/ 下 13 个 .py 核心脚本职责

| 脚本 | 职责 |
|---|---|
| init.py | 引擎初始化，版本定义 |
| switch.py | 工作区切换 |
| step.py | 步骤执行接口（--next / --submit / --decide） |
| compiler.py | app.yaml 编译器，产出 ROUTER.json + registry.json |
| orchestrator.py | 运行时编排器，三阶段循环 |
| router.py | 边路由，沿 verdict 找下一步 |
| gate.py | 产出物格式校验 |
| fix.py | 修复 IO |
| set_state.py | 状态设置 |
| mode.py | 模式管理 |
| cleanup.py | 清理 |
| session_path.py | 会话路径解析（WORKSPACE_ROOT 机制） |
| filelock.py | 文件锁 |

### sdk/ 下 4 个文件职责

| 文件 | 职责 |
|---|---|
| sdk.py | SDK 核心接口定义 |
| SDK_SPEC.md | SDK 规范文档（本文档） |
| `__init__.py` | 包初始化 |
| 编排范式.md | app.yaml 声明式编排范式文档 |

### schemas/ 下 4 个 schema 文件职责

| 文件 | 职责 |
|---|---|
| state.schema.json | 引擎状态结构约束 |
| dispatch-instruction.schema.json | 调度指令格式约束 |
| fix-io.schema.json | 修复 IO 格式约束 |
| return-package.schema.json | 返回包格式约束 |

### 平台特定脚本区分原则

| Mac 专用 | Win 专用 | 说明 |
|---|---|---|
| mode.sh | mode.cmd | 模式管理脚本，平台特定 |
| switch.sh | switch.cmd | 工作区切换脚本，平台特定 |

> .sh 文件不同步到 Win 版，.cmd 文件不被 Mac 版覆盖。

### apps/ 目录同步规则

`apps/` 目录包含全部已构建的 APP 应用，每个 APP 包含 roles/、knowledge/、outputs/ 等子目录。

| 文件类型 | 同步策略 | 说明 |
|---|---|---|
| `*.py` | 同步（Mac→Win） | Python 跨平台，需检查 python3 调用 |
| `*.md` | 同步（Mac→Win） | 文档跨平台，skill.md / principles.md 等 |
| `*.json` | 同步（Mac→Win） | schema.json / registry.json / ROUTER.json 等 |
| `*.yaml` | 同步（Mac→Win） | app.yaml 等配置文件 |
| `*.sh` | **不同步** | Mac 专用 Shell 脚本 |
| `*.cmd` | **不覆盖** | Win 专用脚本 |

> apps/ 目录下的 Python 脚本（如 compute_indices.py、gen_config.py）同样需检查 python3→python 适配。

### .qoder/ 目录同步规则

`.qoder/` 目录包含引擎运行时配置，是引擎正常运行的必需文件。

| 子目录/文件 | 内容 | 同步策略 |
|---|---|---|
| `.qoder/settings.json` | 引擎全局设置 | 同步（JSON 跨平台） |
| `.qoder/agents/` | 角色 agent 定义（role-executor.md、stability-analyzer.md） | 同步（MD 跨平台） |
| `.qoder/hooks/` | 钩子脚本（post-tool-hook.py、stability-hook.py、stability-hook.sh） | .py 同步，.sh 不同步 |
| `.qoder/rules/` | 规则文件（stability-layer.mdc） | 同步（MDC 跨平台） |

> .qoder/hooks/ 下的 .py 脚本同样需检查 python3 调用和 subprocess 编码适配。
