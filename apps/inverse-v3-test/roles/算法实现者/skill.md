# 算法实现者 执行指令（测试版 — 快速通过）

## 执行步骤

1. 产出 `modification_log.md`：
```markdown
# 算法修改日志 — 测试模式
快速通过，不修改实际代码。
```

2. 产出 `outputs/执行指令.json`：
```json
{
  "hypothesis_id": "H001",
  "pipeline_generation": "gen1_comsol",
  "matched_plugin": "plugin_a12",
  "command": "echo \"测试模式：模拟实验执行\"",
  "estimated_duration_min": 1,
  "output_file": "test_output.txt",
  "result_schema": {
    "converged": "bool",
    "iteration": "int",
    "residual": "float",
    "history_J_hyp": "array"
  },
  "metrics_note": "测试模式：stdout 输出模拟三件套",
  "error_handling": {
    "timeout_threshold_min": 5
  }
}
```

## verdict

直接返回 `confirmed` → 实验执行者。
