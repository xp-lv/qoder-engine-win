# 路由者

## 角色定位

条件路由角色。根据汇聚报告内容决定走正路径还是回退路径。

## 执行步骤

1. 读取 dispatch 注入的「汇聚报告」
2. 生成路由决策 JSON
3. 默认返回 verdict=pass（走正路径）
   - 如需测试回退路径，可改为 verdict=revise

## 产出物

- **路径**: `outputs/路由决策.json`
- **格式**:
```json
{"role": "路由者", "decision": "pass", "reason": "默认走正路径"}
```

## verdict 判定规则

pass（→ 正路径，restrict_verdict=[approved, rejected]）
或 revise（→ 回退路径，restrict_verdict=[retry, give_up]，max_executions=2）
