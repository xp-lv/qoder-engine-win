# 研究者 执行指令（测试版 — 快速通过）

## 执行步骤

1. 产出 `hypothesis_chain.json`（首次创建，追加式）：
```json
[
  {
    "hypothesis_id": "H001",
    "version": 1,
    "source": "initial",
    "statement": "B-spline K=60，预期 cos θ 提升",
    "verification_status": "PENDING",
    "pipeline_requirement": {
      "parameterization": "b-spline",
      "constraints": ["tv_regularization"]
    }
  }
]
```

2. 产出 `research/研究笔记.md`（首次创建）：
```markdown
## H001 — 测试模式
快速通过。
```

3. 产出 `research/已否决假设.json`（首次创建）：
```json
[]
```

## verdict

直接返回 `confirmed` → FORK 三方并行。
