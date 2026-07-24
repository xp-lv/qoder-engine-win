# skill 编写指南

> 注入目标：Skill填充师（M3）
> 用途：指导 M3 为目标 APP 每个角色产出 skill.md + schema.json

## 目的
本指南定义 skill.md 与 schema.json 的标准结构、verdict 设计原则与长度限流规则，确保填充产出的角色文件可被引擎调度且校验通过。

## 核心准则

### 1. skill.md 五段结构（强制）
每个 skill.md 必须包含以下五段：
- `## 角色定位`：独特能力声明 + 核心职责（1-2 段）
- `## 执行步骤`：编号步骤，每步含具体动作（读什么、做什么、写什么）
- `## 产出物`：路径 + 格式描述（含 JSON 结构示例）
- `## verdict 判定规则`：表格（verdict / 触发条件 / 路由目标）
- `## 自检项`：产出前逐项自查清单（checkbox）

### 2. 长度限流（蓝图 §6.3）
- 每个 skill.md ≤ 200 行
- 超出时将详述下沉到 knowledge 文档，skill 中仅引用 knowledge 路径
- 原因：单文件过长会触发角色执行时上下文超限

### 3. schema.json 结构
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "result": {
      "type": "object",
      "required": ["verdict", "summary"],
      "properties": {
        "verdict": { "type": "string", "enum": ["confirmed", "..."] },
        "summary": { "type": "string" },
        "findings": { "type": "array" }
      }
    }
  },
  "required": ["result"],
  "_required_files": [
    { "name": "产出物名", "path": "产出物路径" }
  ]
}
```

### 4. verdict 设计时序原则
- 角色的 verdict 值来源：edges 中 `when: result.verdict == "xxx"` 的 xxx
- 无条件出边（`A → B` 无 when）的默认 verdict 为 `confirmed`
- `fail` 是系统保留词（Gate 专属），不写入 schema enum
- 回退类 verdict 用 `fail_` 前缀（如 fail_compile / fail_consistency）
- 三方（skill / schema / ROUTER）的 verdict 值必须完全一致

### 5. _required_files 对齐
- schema.json 的 _required_files 必须与 app.yaml 中该角色的 outputs 完全对齐
- 每项含 name + path
- compiler 会保留手写的 contract 字段（深度校验规则）

## 判别清单

M3 填充时逐项核对：
- [ ] skill.md 五段齐全（角色定位/执行步骤/产出物/verdict/自检项）？
- [ ] skill.md ≤ 200 行？
- [ ] schema.json 的 result.verdict.enum 与 ROUTER.json transitions 一致？
- [ ] schema.json 的 _required_files 覆盖 app.yaml outputs？
- [ ] verdict 描述在 skill.md 中有对应文字（满足 ROUTE_SKILL_UNDOCUMENTED 检查）？

## 反模式
- ❌ skill.md 缺少 verdict 判定规则段（会触发 ROUTE_SKILL_UNDOCUMENTED 警告）
- ❌ schema.json 的 verdict enum 与 ROUTER.json 不一致（会触发 VERDICT_MISMATCH 警告）
- ❌ 把所有领域知识塞进 skill.md（应下沉到 knowledge 文档）
- ❌ 使用已废弃的 type 字段区分 producer/standard
