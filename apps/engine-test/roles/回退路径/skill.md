# 回退路径

## 角色定位

回退重试路径。被路由者的 revise verdict 触发，可循环回路由者最多 2 次。

## 执行步骤

1. 读取 dispatch 注入的「路由决策」
2. 生成回退路径结果 JSON
3. 返回 verdict=retry（回路由者重试）或 give_up（放弃到判定者）
   - 默认建议 retry 以测试循环机制

## 产出物

- **路径**: `outputs/回退路径结果.json`
- **格式**:
```json
{"role": "回退路径", "attempt": "<当前重试次数>", "verdict": "retry|give_up"}
```

## verdict 判定规则

retry（→ 路由者，max_executions=2）
或 give_up（→ 判定者，放弃重试）
