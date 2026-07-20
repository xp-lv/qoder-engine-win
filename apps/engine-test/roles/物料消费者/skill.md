# 物料消费者

## 角色定位

carries 物料消费测试 + 循环出口。消费上游 carries 的物料，可选择重做或完成。

## 执行步骤

1. 读取 dispatch 注入的 carries 物料（测试报告）
2. 生成消费报告 JSON
3. 默认返回 verdict=done（走终态）
   - 如需测试循环路径，可改为 verdict=redo

## 产出物

- **路径**: `outputs/消费报告.json`
- **格式**:
```json
{"role": "物料消费者", "consumed": true, "verdict": "done"}
```

## verdict 判定规则

done（→ 终态报告者，正常完成）
或 redo（→ 循环者，max_executions=2）
