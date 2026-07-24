# MCP 工具使用指南

## 目的

本文档为 PhantomConstrainedInverseScattering APP 提供 MCP Server (matlab-comsol) 的工具调用指南，涵盖 run_experiment、run_matlab_batch、check_comsol、read_mat 四个工具的接口定义、参数说明、错误处理。为正演数据生成者（R2）、基线反演执行者（R3）、约束反演执行者（R4）调用 COMSOL 正演和 MATLAB 反演提供工具使用规范。

## 适用角色

- 正演数据生成者（R2）— check_comsol / run_experiment / read_mat
- 基线反演执行者（R3）— check_comsol / run_matlab_batch / run_experiment / read_mat
- 约束反演执行者（R4）— 同 R3

---

## 1. MCP Server 配置

### 1.1 启动方式

```powershell
python mcps/matlab-comsol/server.py --port <port_number>
```

### 1.2 环境配置

| 组件 | 路径/配置 |
|------|-----------|
| MCP Server | mcps/matlab-comsol/server.py |
| MATLAB R2023b | D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe |
| COMSOL 6.2 | D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64 |
| LiveLink 端口 | 2036 |
| OS | Windows + PowerShell 5.1（不支持 `&&`，使用 `;` 分隔） |

---

## 2. check_comsol 工具

### 2.1 功能

检查 COMSOL LiveLink 连接状态、许可证有效性、内存占用。

### 2.2 调用方式

```json
{
  "tool": "check_comsol",
  "parameters": {
    "port": 2036
  }
}
```

### 2.3 返回值

```json
{
  "connected": true,
  "license_valid": true,
  "comsol_version": "6.2",
  "available_memory_GB": 34.5,
  "livelink_port": 2036
}
```

### 2.4 使用时机

- 每次正演/反演操作前调用，确认环境就绪
- 若 `connected: false`，等待 10 秒后重试（最多 3 次）
- 若 `available_memory_GB < 32`，等待内存释放或报错

---

## 3. run_experiment 工具

### 3.1 功能

运行单次 COMSOL 正演实验：将 ε_r 配置写入模型，运行频域求解，返回散射场数据。

### 3.2 调用方式

```json
{
  "tool": "run_experiment",
  "parameters": {
    "model_path": "path/to/model.mph",
    "epsilon_r_config": {
      "real_csv": "path/to/eps_real.csv",
      "imag_csv": "path/to/eps_imag.csv"
    },
    "frequencies_GHz": [0.8, 1.0],
    "phantom_config": "path/to/phantom_config.json",
    "background_field": "plane_wave",
    "timeout_minutes": 30
  }
}
```

### 3.3 返回值

```json
{
  "status": "success",
  "scattered_field": {
    "E_s": [[re_x, im_x, re_y, im_y, re_z, im_z], ...],
    "H_s": [[...], ...]
  },
  "total_field": {
    "E_total": [[...], ...],
    "voxel_positions": [[x, y, z], ...]
  },
  "solve_time_seconds": 423,
  "frequencies_solved": [0.8e9, 1.0e9]
}
```

### 3.4 错误处理

- `status: "timeout"`：求解超时（>30 分钟），检查网格规模或频率设置
- `status: "memory_error"`：内存不足，减少并行任务或增加内存
- `status: "non_convergence"`：FEM 求解器未收敛，检查 PML/PARDISO 配置

---

## 4. run_matlab_batch 工具

### 4.1 功能

批量执行 MATLAB 脚本，主要用于反演迭代循环（9 步伴随梯度循环）。

### 4.2 调用方式

```json
{
  "tool": "run_matlab_batch",
  "parameters": {
    "script_path": "path/to/inversion_loop.m",
    "input_data": {
      "jobs_mat_path": "path/to/J_obs_data.mat",
      "phantom_config_path": "path/to/phantom_config.json",
      "config_path": "path/to/config.m"
    },
    "iteration_params": {
      "eps_tol": 1e-3,
      "max_iter": 30,
      "mu_init": 0.1,
      "mu_max": 1.0,
      "c_armijo": 0.1,
      "max_backtrack": 8,
      "n_random_init": 10
    },
    "constraint_mode": "hard",
    "checkpoint_dir": "path/to/checkpoints/"
  }
}
```

### 4.3 返回值

```json
{
  "status": "success",
  "results": {
    "epsilon_r_recon": [...],
    "convergence_history": [...],
    "n_iterations": 18,
    "converged": true,
    "multi_init_results": [...],
    "uniqueness_variance": 0.0023,
    "final_residual": 0.00087
  },
  "total_time_hours": 12.5,
  "comsol_solves_count": 720
}
```

### 4.4 错误处理

- `status: "script_error"`：MATLAB 脚本异常，检查脚本日志
- `status: "livelink_disconnect"`：LiveLink 断连，从检查点恢复
- `status: "max_iter_exceeded"`：超过 30 次迭代未收敛，标记 converged=false
- `status: "checkpoint_recovered"`：从检查点恢复续算

---

## 5. read_mat 工具

### 5.1 功能

读取 MATLAB .mat 文件中的数据。

### 5.2 调用方式

```json
{
  "tool": "read_mat",
  "parameters": {
    "file_path": "path/to/J_obs_data.mat",
    "variable_names": ["J_obs_perp", "k_dir", "dOmega", "freq_list", "epsilon_r_true"]
  }
}
```

### 5.3 返回值

```json
{
  "status": "success",
  "data": {
    "J_obs_perp": {"shape": [64, 3, 2], "dtype": "complex128", "values": [...]},
    "k_dir": {"shape": [64, 3], "dtype": "float64", "values": [...]},
    "dOmega": {"shape": [64, 1], "dtype": "float64", "values": [...]},
    "freq_list": {"shape": [2, 1], "dtype": "float64", "values": [8e8, 1e9]},
    "epsilon_r_true": {"shape": [19268, 1], "dtype": "complex128", "values": [...]}
  }
}
```

### 5.4 使用场景

- R3/R4 读取 R2 产出的 J_obs_data.mat
- R5 读取真值 ε_r_true 用于误差计算
- 读取检查点文件用于续算

---

## 6. 调用时序规范

### 6.1 正演数据生成（R2）

```
1. check_comsol(port=2036)          → 确认连接
2. run_experiment(ε_r_true, freq)   → COMSOL 正演
3. read_mat(result_path)            → 读取散射场
4. [MATLAB 计算 J_obs + V5a 校验]
5. 写入 J_obs_data.mat
```

### 6.2 反演迭代（R3/R4）

```
1. check_comsol(port=2036)                    → 确认连接
2. read_mat(J_obs_data.mat)                   → 加载观测数据
3. run_matlab_batch(inversion_loop.m, params) → 执行反演循环
   循环内每步：
   a. run_experiment(ε_r_current)             → COMSOL 正演
   b. read_mat(forward_result)                → 提取 E_total
   c. [MATLAB 计算 J_hyp, ΔJ, 梯度]
   d. run_experiment(adjoint_source)           → COMSOL 伴随求解
   e. read_mat(adjoint_result)                → 提取 λ
   f. [MATLAB 线搜索更新 ε_r]
4. 读取反演结果
```

### 6.3 串行化要求

LiveLink 为单连接，同一时间仅允许一个 COMSOL 求解。R3 和 R4 并行执行时：
- COMSOL 调用通过队列/互斥锁串行化
- MATLAB 计算（J_hyp、梯度等）可以并行
- 建议：R3 和 R4 交替使用 COMSOL（R3 正演 → R4 正演 → R3 伴随 → R4 伴随 ...）

---

## 7. 错误处理策略

### 7.1 COMSOL 求解失败

| 错误类型 | 处理策略 |
|----------|----------|
| 非收敛 | 检查 PML/PARDISO 配置，重试 1 次 |
| 内存不足 | 等待 60 秒释放内存，重试 1 次 |
| 许可证失效 | 报错，需人工干预 |
| 超时 | 终止当前求解，从检查点恢复 |

### 7.2 MATLAB 脚本异常

| 错误类型 | 处理策略 |
|----------|----------|
| 脚本语法错误 | 报错，需修正脚本 |
| 数值溢出（NaN/Inf） | 检查 ε_r 物理范围约束，回退到上一步 |
| LiveLink 断连 | 从检查点恢复续算 |

### 7.3 LiveLink 断连重试

```
断连检测 → 等待 10 秒 → 重连（mphstart(2036)）→ 重试（最多 3 次）→ 报错
```

---

## 8. 并发限制

- COMSOL LiveLink：**单连接**，同一时间仅一个求解
- MATLAB：可多实例并行（但共享 LiveLink 时需串行化 COMSOL 调用）
- 建议 R3/R4 的反演循环在独立的 MATLAB 实例中运行，COMSOL 调用通过共享队列串行化

---

## 检查清单

- [ ] 每次操作前调用 check_comsol 确认连接？
- [ ] run_experiment 超时设置 30 分钟？
- [ ] run_matlab_batch 检查点目录已配置？
- [ ] read_mat 读取的变量名与 .mat 文件一致？
- [ ] R3/R4 并行时 COMSOL 调用已串行化？
- [ ] LiveLink 断连重试策略已配置？
