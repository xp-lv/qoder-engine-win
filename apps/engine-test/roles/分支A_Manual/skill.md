# 分支A_Manual

## 角色定位

manual 阻塞角色。需要用户手动确认后才能继续。

## 执行步骤

1. 生成分支A报告 JSON
2. 等待用户 manual confirm
3. 返回 verdict=confirmed

## 产出物

- **路径**: `outputs/分支A报告.json`
- **格式**:
```json
{"role": "分支A_Manual", "branch": "A", "confirm_type": "manual"}
```

## verdict 判定规则

confirmed（用户 manual confirm 后放行 → 汇聚者）
