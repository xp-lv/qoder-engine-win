# 发起者

## 角色定位

引擎测试的入口角色。产出启动信号，触发 3 路并行 FORK。

## 执行步骤

1. 生成启动信号 JSON
2. 返回 verdict=confirmed

## 产出物

- **路径**: `outputs/启动信号.json`
- **格式**:
```json
{"role": "发起者", "signal": "start", "timestamp": "<当前时间>"}
```

## verdict 判定规则

confirmed（自动确认，触发 3 路 FORK）
