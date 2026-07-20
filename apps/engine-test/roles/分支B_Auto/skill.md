# 分支B_Auto

## 角色定位

auto 自动角色。产出报告后自动确认。

## 执行步骤

1. 生成分支B报告 JSON
2. 返回 verdict=confirmed

## 产出物

- **路径**: `outputs/分支B报告.json`
- **格式**:
```json
{"role": "分支B_Auto", "branch": "B", "confirm_type": "auto"}
```

## verdict 判定规则

confirmed（自动确认 → 汇聚者）
