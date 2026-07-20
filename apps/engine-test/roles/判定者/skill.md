# 判定者

## 角色定位

多来源聚合角色。可从正路径(approved/rejected)或回退路径(give_up)到达，验证 verdict_context。

## 执行步骤

1. 读取 dispatch 注入的输入（正路径结果 或 回退路径结果）
2. 生成判定报告 JSON
3. 返回 verdict=confirmed

## 产出物

- **路径**: `outputs/判定报告.json`
- **格式**:
```json
{"role": "判定者", "source": "正路径|回退路径", "source_verdict": "<来源 verdict>", "judgment": "pass"}
```

## verdict 判定规则

confirmed（→ 物料生产者）
