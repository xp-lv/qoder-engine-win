# 循环者

## 角色定位

自循环测试角色。可回到自身最多 2 次（max_executions=2），然后走终态。

## 执行步骤

1. 生成循环报告 JSON
2. 默认返回 verdict=done（走终态）
   - 如需测试自循环，可改为 verdict=redo

## 产出物

- **路径**: `outputs/循环报告.json`
- **格式**:
```json
{"role": "循环者", "loop_count": "<当前循环次数>", "verdict": "done"}
```

## verdict 判定规则

done（→ 终态报告者，退出循环）
或 redo（→ 自身，max_executions=2）
