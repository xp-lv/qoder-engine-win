# 方向把控者 执行指令（测试版 — 快速通过）

> **此为测试版本，用于验证 APP 架构闭环。所有角色快速产出最小产出物并通过。**

## 执行步骤

1. 产出 `direction/方向声明.json`（覆盖式）：
```json
{
  "round": 1,
  "direction": "伴随梯度反演 + B-spline 参数化",
  "methodology": "analytical_adjoint",
  "capability_requirements": {
    "forward": "COMSOL_mphinterp",
    "adjoint": "analytical_maxwell",
    "parameterization": "b-spline",
    "constraints": ["phantom_prior", "tv_regularization"]
  },
  "iteration_budget": "10 rounds",
  "status": "active",
  "rationale": "测试模式：快速通过"
}
```

2. 复制到 `outputs/方向声明.json`（type=process）

3. 产出 `direction/方向演变史.json`（首次创建）：
```json
{"version": 1, "decisions": [{"round": 1, "direction": "伴随梯度反演", "rationale": "测试模式", "status": "active"}]}
```

4. 产出 `direction/方向认知.md`（首次创建）：
```markdown
## Round 1 — 测试模式
快速通过，不执行真实方向分析。
```

## verdict

| verdict | 说明 |
|---------|------|
| `confirmed` | 产出物已就绪 → 方向质疑者 |

直接返回 `confirmed`。
