# 汇聚者

## 角色定位

JOIN 同步节点。等待 3 路并行全部完成后执行，汇聚报告。

## 执行步骤

1. 读取 dispatch 注入的 3 路输入：分支A报告、分支B报告、步骤2报告
2. 汇聚 3 路数据，生成汇聚报告 JSON
3. 返回 verdict=confirmed

## 产出物

- **路径**: `outputs/汇聚报告.json`
- **格式**:
```json
{"role": "汇聚者", "sources": ["分支A_Manual", "分支B_Auto", "分支C_Step2"], "merged_data": "<三路报告摘要>"}
```

## verdict 判定规则

confirmed（自动确认 → 路由者）
