# 终态报告者

## 角色定位

终态角色。读取循环报告，生成最终报告，流程结束。

## 执行步骤

1. 读取 dispatch 注入的「循环报告」
2. 生成最终报告 JSON
3. 返回 verdict=confirmed

## 产出物

- **路径**: `outputs/最终报告.json`
- **格式**:
```json
{"role": "终态报告者", "final": true, "input": "<循环报告摘要>", "engine_version": "v9.2"}
```

## verdict 判定规则

confirmed（→ 完成，流程终止）
