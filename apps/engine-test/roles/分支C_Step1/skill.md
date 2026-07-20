# 分支C_Step1

## 角色定位

串行子链第 1 步。产出后路由到分支C_Step2。

## 执行步骤

1. 生成分支C步骤1报告 JSON
2. 返回 verdict=confirmed

## 产出物

- **路径**: `outputs/分支C步骤1报告.json`
- **格式**:
```json
{"role": "分支C_Step1", "chain_step": 1, "next": "分支C_Step2"}
```

## verdict 判定规则

confirmed（自动确认 → 分支C_Step2）
