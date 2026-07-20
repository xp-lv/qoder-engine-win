# REQ-ID 增补流程

> 对抗期发现隐含需求时的 REQ-ID 增补审批机制（§9.4）。
> 架构师和终审共享遵守。

## 什么时候触发

架构师在响应红队 problem 过程中，发现 L2 未注册的隐含需求（如推演出的边界约束、扩展能力需求未在 L2 中体现）。

**禁止私自添加未注册的 REQ-XXX**——红队可直接判 fail。

## 完整流程

```
架构师发现隐含需求
  ↓ 标注 unregistered_requirement（含推演依据）
  ↓ 输出 verdict = unregistered_requirement
  ↓
终审裁决者审批
  ├─ 批准 reqid_approved → 需求分析师 L2 解冻-写入-重冻结
  │                       ↓ 用户 manual confirm → confirmed
  │                       ↓ 架构师（从 R1 重跑全部 3 轮，F3-001）
  │
  └─ 驳回 reqid_rejected → 架构师按现有 L2 完成响应
                           （不得标注 unregistered_requirement）
```

## F3-001 信号识别（架构师如何知道是增补后重跑）

架构师从 dispatch 注入的输入文件中**检查是否含 `REQ-ID增补审批.json`**：

| 场景 | 信号识别 | 架构师行为 |
|------|---------|----------|
| 初次 v1 | 无 REQ-ID增补审批.json | 按 §6 产出完整蓝图 |
| REQ-ID 增补后重跑 | **存在** REQ-ID增补审批.json | 从 R1 重跑全部 3 轮（所有已完成轮次自动失效）|
| consistency_defect 重跑 | 无 REQ-ID增补审批.json | 从空白蓝图重起（§9.2）|

## 次数限制（max_executions: 2）

整个对抗期最多 2 次 REQ-ID 增补。

- 第 1-2 次：终审可输出 `reqid_approved`
- 第 3 次（max_executions 耗尽）：verdict_enum 动态过滤移除 reqid_approved，终审必须 emit `terminated`（死循环兜底）

## REQ-ID增补审批.json schema

```json
{
  "request_id": "REQID-APP-XXX",
  "applicant": "架构设计师",
  "proposed_req_id": "REQ-{现有最大编号+1}",
  "semantic_description": "隐含需求语义描述",
  "inference_basis": "引用蓝图章节作为推演链条",
  "verdict": "reqid_approved | reqid_rejected",
  "mechanism_reason": "批准/驳回的机制级理由",
  "cumulative_count": 1
}
```

## 终审审批的判定依据

| 判定 | 条件 | verdict |
|------|------|---------|
| 批准 | 推演链条成立 + 属新需求 + 未超 L1 scope | `reqid_approved` |
| 驳回 | 推演链条不成立 / 属已有 REQ-ID 细化 / 超 scope | `reqid_rejected` |

## 需求分析师 L2 更新步骤

收到 `reqid_approved` 后，需求分析师执行 L2 解冻-写入-重冻结。

> **L2 更新操作的唯一权威源：《L2需求规格编写指南》§六**（含完整字段约束、版本号演进、推断字段处理）。本节不重复操作步骤。

关键约束（抬到本流程供终审参考）：
- 仅追加新 REQ-ID（现有最大编号 +1），**不可修改既有 REQ**
- L2 版本号 +1
- 重冻结后 3 轮红队立即可见新 REQ-ID 集合

## 自检清单（架构师发现隐含需求时）

- [ ] 是否在响应记录中标注 unregistered_requirement + 隐含需求语义？
- [ ] 是否引用蓝图中具体章节作为推演链条？
- [ ] 是否输出 unregistered_requirement verdict → 终审审批？

## 自检清单（架构师增补后重跑时）

- [ ] 是否通过 dispatch 注入的 REQ-ID增补审批.json 识别"增补后重跑"信号？
- [ ] 是否从 R1 重跑全部 3 轮（增补后所有已完成轮次自动失效）？
- [ ] 是否在覆盖固定路径前归档当前产出（参考《归档策略》）？

## 自检清单（终审 REQ-ID 审批时）

- [ ] 是否评估推演链条（架构师引用的蓝图章节）是否成立？
- [ ] 批准时是否记录新 REQ-ID（按 L2 现有最大编号 +1）？
- [ ] 驳回时是否给出机制级理由（推演链条不成立 / 已有 REQ-ID 细化 / 超 scope）？
- [ ] 增补次数是否累计（max 2）？累计 2 次后第 3 次直接 terminated？
- [ ] 增补审批决议是否对 3 轮红队均可见（§5.5 例外）？
