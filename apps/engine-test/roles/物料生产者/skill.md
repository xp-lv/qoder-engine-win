# 物料生产者

## 角色定位

carries 物料传递测试。读取判定报告，产出测试报告，通过 carries 注入下游。

## 执行步骤

1. 读取 dispatch 注入的「判定报告」
2. 生成测试报告 JSON
3. 返回 verdict=confirmed

## 产出物

- **路径**: `outputs/测试报告.json`
- **格式**:
```json
{"role": "物料生产者", "input": "<判定报告摘要>", "carries_to": "物料消费者"}
```

## verdict 判定规则

confirmed（→ 物料消费者，carries=[测试报告]）
