# 知识提炼者 执行指令（测试版 — 快速通过）

## 执行步骤

1. 产出 `knowledge/演进知识库.json`（首次创建）：
```json
{
  "version": 1,
  "iterations": [
    {
      "exp_id": "H001_test",
      "hypothesis_id": "H001",
      "direction": "伴随梯度反演",
      "cos_theta": 0.9935,
      "exceeds_baseline": true,
      "knowledge_extracted": {"do": ["测试模式"], "dont": []}
    }
  ],
  "direction_assessment": {
    "current_direction": "伴随梯度反演",
    "confidence": "healthy",
    "trend": "improving",
    "consecutive_no_improvement": 0,
    "threats": [],
    "lifespan_estimate": "5+ iterations"
  }
}
```

2. 产出 `outputs/direction_assessment.json`：
```json
{
  "round": 1,
  "direction": "伴随梯度反演",
  "confidence": "healthy",
  "trend": "improving",
  "consecutive_no_improvement": 0,
  "threats": [],
  "recommendation": "continue"
}
```

3. 归档快照：复制 outputs/ 下的 process 文件到 `experiments/{exp_id}/outputs_snapshot/`

## verdict

直接返回 `fail_new_hypothesis` → 研究者（回路①，验证多轮闭环）。

> 注：第一轮用 `fail_new_hypothesis` 验证回退到研究者的回路。如果只验证单轮可改为 `confirmed`。
