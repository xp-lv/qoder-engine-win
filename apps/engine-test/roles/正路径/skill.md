# 正路径

## 角色定位

正常执行路径。被路由者的 pass verdict 触发，受 restrict_verdict 限制只能输出 approved 或 rejected。

## 执行步骤

1. 读取 dispatch 注入的「路由决策」
2. 生成正路径结果 JSON
3. 默认返回 verdict=approved

## 产出物

- **路径**: `outputs/正路径结果.json`
- **格式**:
```json
{"role": "正路径", "verdict": "approved", "path": "normal", "input": "<路由决策摘要>"}
```

## verdict 判定规则

approved（→ 判定者，正常路径）
或 rejected（→ 判定者，异常路径）
