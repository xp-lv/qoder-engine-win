# 实验执行者 执行指令（测试版 — 快速通过）

## 执行步骤

1. 生成 exp_id（如 `H001_20260723_120000`）
2. 创建 `experiments/{exp_id}/` 目录
3. 执行命令（`echo` 模拟）
4. 产出实验数据：
   - `experiments/{exp_id}/meta.json`：
   ```json
   {"exp_id": "H001_20260723_120000", "hypothesis_id": "H001", "pipeline_generation": "gen1_comsol", "plugin": "plugin_a12", "duration_min": 1}
   ```
   - `experiments/{exp_id}/stdout.log`：
   ```
   测试模式：模拟实验执行
   cos theta (mean): 0.9935
   F_cheb: 0.082
   Converged: 1, Iterations: 7
   ```
   - `experiments/{exp_id}/三件套指标.json`：
   ```json
   {"cos_theta": 0.9935, "f_cheb": 0.082, "converged": true, "iteration": 7, "residual": 0.082}
   ```

5. 产出/更新 `experiments_index.json`：
```json
{"experiments": [{"exp_id": "H001_20260723_120000", "hypothesis_id": "H001", "pipeline_gen": "gen1_comsol", "plugin": "plugin_a12", "cos_theta": 0.9935, "f_cheb": 0.082, "converged": true, "timestamp": "2026-07-23T12:00:00"}]}
```

## verdict

直接返回 `confirmed` → 基线评估者。
