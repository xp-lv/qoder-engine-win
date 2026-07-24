# 管线重构者 执行指令（测试版 — 快速通过）

> 测试模式中不会触发此角色（汇聚裁决者直接返回 all_pass）。
> 如果被触发，快速产出最小报告即可。

## 执行步骤

1. 产出 `outputs/管线重构报告.json`：
```json
{
  "trigger": "测试模式",
  "rebuild_mode": "same_gen_fork",
  "new_pipeline_path": "d:\\ZJU\\PROJECT\\2026-07-02-qoder-engine\\COMSOL\\pipline",
  "deliverables_checklist": {
    "pipeline_code_created": true,
    "pipeline_json_written": true,
    "plugin_guide_written": true,
    "registry_updated": true,
    "at_least_one_plugin": true,
    "command_runnable": true
  },
  "verdict": "confirmed",
  "summary": "测试模式：快速通过"
}
```

2. pipeline_registry.json 保持不变（测试模式不创建新管线）

## verdict

直接返回 `confirmed` → 研究者。
