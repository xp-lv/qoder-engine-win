# SDK 陷阱规避（v8.0 版本）

> 本文档集中说明所有**校验角色 + 跨层回退 + 信号识别**相关的 SDK 机制陷阱。这些陷阱源于引擎设计约束，非业务规则。
>
> **v8.0 变更**：原 v7.x 版本围绕 producer 自动展开机制，已全部失效。本 v8.0 版本围绕**显式校验角色**重新编写。
>
> **适用角色**：所有校验角色（需求分析师校验 / 架构设计师校验）、架构设计师（跨层回退执行者）、终审裁决者（M1 max_executions 检测）。

---

## 陷阱 1：校验角色 verdict 直接 emit（v8.0 新增）

**问题背景**：v8.0 删除 producer 类型后，校验角色不再通过"producer emit confirmed → validate step 转译业务 verdict"的间接语义链。校验角色**直接 emit 业务 verdict**。

**陷阱**：校验角色 skill.md 若仍写"emit confirmed 由 SDK 转译"，会导致 verdict 不匹配 ROUTER transitions，路由失败。

**正确做法**：
- 校验角色直接 emit 对应的业务 verdict（如 `blueprint_v1_ready` / `unregistered_requirement` / `loop`）
- 业务 verdict 必须在 ROUTER.json transitions 中有对应边
- schema.json 的 verdict enum 从 edges 自然推导（compiler 自动生成）

---

## 陷阱 2：C1 修复后链路——REQ-ID 增补的路由实现

**问题背景**：架构师在响应记录中标注 `unregistered_requirement` 后，需要路由到终审审批。审批通过后需求分析师执行 L2 解冻-写入-重冻结，架构师从 R1 重跑。

**路由实现（v8.0）**：

```
架构设计师 emit unregistered_requirement
    ↓ ROUTER.json transitions
架构设计师校验（若校验通过，透传 unregistered_requirement）
    ↓ ROUTER.json transitions
终审裁决者（审批）
    ↓ reqid_approved
需求分析师（L2 解冻-写入-重冻结）
    ↓ confirmed
需求分析师校验
    ↓ confirmed
架构设计师（通过 carries 中的 REQ-ID增补审批.json 识别"增补后重跑"）
    ↓ blueprint_v1_ready
架构设计师校验
    ↓
结构红队 R1（从 R1 重跑全部 4 轮，F3-001）
```

**关键约束**：
- `unregistered_requirement` verdict 必须在架构设计师 + 架构设计师校验的 transitions 中都有对应边
- 终审审批结果（`reqid_approved` / `reqid_rejected`）通过 restrict_verdict 限定
- 架构师通过 **dispatch 注入的 carries 信号**（REQ-ID增补审批.json）识别"增补后重跑"，不依赖 verdict 标签

---

## 跨层回退信号识别（M2 + F3-001 合一）

### M2 修复：跨层回退归档

**问题背景**：跨层回退（consistency_defect / reqid_approved 链路）触发时，架构师覆盖固定路径前必须先归档当前产出，否则 AC-4 severity 变化链断裂。

**信号识别**：架构师通过 **dispatch 注入的 carries** 识别跨层回退：
- 收到 `consistency_defect` verdict 的 dispatch → 一致性回退，必须归档
- dispatch inputs 含 `REQ-ID增补审批.json` → 增补后重跑，必须归档 + 从 R1 重跑

**归档操作的唯一权威源**：《归档策略》（含完整 cp 命令清单、run-{N} 计数规则）。

### F3-001 修复：增补后重跑信号

**问题背景**：C1 修复后，需求分析师更新 L2 后 emit confirmed。架构师需要一种机制识别"这次 dispatch 是 REQ-ID 增补后的重跑"，以触发 F3-001（从 R1 重跑全部 4 轮）。

**信号识别（v8.0）**：
- 架构师检查 dispatch 注入是否含 `REQ-ID增补审批.json`（carries 信号）
- 存在 → 增补后重跑，按入口路径一产出 v1，从 R1 重跑
- 不存在 → 初次 v1，正常产出

**关键约束**：不依赖 verdict 标签（如 `l2_updated`），因为 v8.0 后所有角色直接 emit 业务 verdict，无 SDK Phase 3 覆盖。

---

## M1 检测机制：max_executions 耗尽后强制 emit terminated

**问题背景**：终审的 `consistency_defect` 和 `reqid_approved` 边都有 `max_executions: 2` 限制。耗尽后，若终审仍 emit 这些 verdict，router 找不到匹配边 → 路由失败。

**检测机制**：
- 终审每次执行时检测 `dispatch.schema_constraints.verdict_enum`
- 若已不含 `consistency_defect` 或 `reqid_approved`（max_executions 耗尽，router 动态过滤）
- 立即 emit `terminated`（强制终止，标注未决项）

**SDK 支持**：router.py 在 dispatch 时根据 edge_counts 动态过滤 verdict_enum（已耗尽的 verdict 从 enum 中移除）。

---

## 自检清单（校验角色 + 跨层回退执行者）

### 校验角色自检（需求分析师校验 / 架构设计师校验）

- [ ] 我是否**直接 emit 业务 verdict**（而非统一 confirmed）？
- [ ] 我 emit 的 verdict 是否在 ROUTER.json transitions 中有对应边？
- [ ] 校验不通过时是否 emit `loop`（而非依赖 SDK fail 边）？
- [ ] emit loop 时是否附 findings（具体问题描述 + evidence）？

### 跨层回退执行者自检（架构设计师）

- [ ] 收到 consistency_defect 时是否先归档（参考《归档策略》）？
- [ ] dispatch 含 REQ-ID增补审批.json 时是否识别为"增补后重跑"？
- [ ] 增补后重跑是否从 R1 重跑全部 4 轮（F3-001）？
- [ ] 跨层回退重跑是否从空白蓝图重起（不保留前次 v1）？

### 终审裁决者自检（M1 检测）

- [ ] 每次执行时是否检测 verdict_enum 是否含 consistency_defect / reqid_approved？
- [ ] max_executions 耗尽后是否立即 emit terminated？
- [ ] terminated 是否标注所有未决项？
