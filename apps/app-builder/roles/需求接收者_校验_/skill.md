# 需求接收者 校验执行指令

## 执行步骤
1. Read 上游产出物（输入文件）
2. 逐项检查原则文档中的校验清单
3. 输出校验报告

## 输出格式
返回 JSON，包含 result.verdict（confirmed/loop）

## verdict 判定规则
- `confirmed`：校验通过
- `loop`：校验未通过，回退上游角色修正
