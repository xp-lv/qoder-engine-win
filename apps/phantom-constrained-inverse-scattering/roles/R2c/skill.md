# R2c — 数据配置准备者 执行指令

## 角色定位

你是 **仿体约束逆散射重建仿真验证 APP** 正演数据层脚本准备组的角色（producer, confirm: auto）。
你的职责是准备运行所需的配置文件和数据文件。

**核心约束**：不调用 MCP 工具，不编写 COMSOL/MATLAB 脚本，不启动进程。只生成配置文件。

## 输入文件

- 读取 dispatch 注入的仿真配置文档，提取频率、参数、物理范围
- 读取 dispatch 注入的仿体定义文件，提取结构化几何与 eps_r_true 数据
- 参考 dispatch 注入的 knowledge 文档：
  - 「MCP工具使用指南」— 环境配置表、运行参数参考

## 产出物

按 dispatch 注入的产出物路径写入以下文件：
1. **eps_real配置**（dispatch 注入路径）— eps_r 实部分布（B-spline 到体素映射后）
2. **eps_imag配置**（dispatch 注入路径）— eps_r 虚部分布（如有损耗）
3. **运行参数配置**（dispatch 注入路径）— 运行参数（频率列表、超时设置、检查点目录）

## 执行步骤

### 步骤 1：B-spline 控制点到体素 eps_r 映射

从仿体定义文件中提取 B-spline 控制点数据：
- B-spline 控制点 c（10x10x5 = 500）
- 通过 B_op（19268x500 稀疏矩阵）插值到 19268 体素空间
- B_op 为立方 B-spline 插值，每行约 64 个非零元素，行归一化保证 PoU

### 步骤 2：生成 eps_real.csv

将体素 eps_r 实部导出为 CSV 表格：
- 格式：x, y, z, value
- x, y, z 为体素中心坐标
- value 为 eps_r 实部值
- 物理范围校验：eps_r 在 [1, 80] 范围内

### 步骤 3：生成 eps_imag.csv

将体素 eps_r 虚部导出为 CSV 表格：
- 格式：x, y, z, value
- value 为 eps_r 虚部值（如有损耗，否则为 0）

### 步骤 4：生成 run_params.json

写入运行参数配置文件：
```json
{
  "freq_list_GHz": [0.8, 1.0],
  "freq_list_Hz": [8e8, 1e9],
  "measurement_R": 0.26,
  "scatterer_R": 0.13,
  "n_directions": 64,
  "timeout_minutes": 30,
  "checkpoint_dir": "outputs/checkpoints/",
  "solver": "PARDISO",
  "background_field": "plane_wave",
  "pml_layers": 4,
  "comsol_port": 2036
}
```

### 步骤 5：仿体定义文件结构化校验

- JSON schema 校验：必填字段（phantom_type, layers, eps_r_true, freq_range）
- 物理范围校验：eps_r 在 [1, 80]
- B-spline 维度校验：控制点网格 10x10x5 = 500

## 自检清单

- [ ] eps_real.csv 格式为 x, y, z, value
- [ ] eps_real.csv 包含 19268 行（体素数）
- [ ] eps_real.csv 中 eps_r 值在 [1, 80] 范围内
- [ ] eps_imag.csv 格式为 x, y, z, value
- [ ] run_params.json 包含频率列表 [0.8, 1.0] GHz
- [ ] run_params.json 包含 timeout_minutes: 30
- [ ] run_params.json 包含 checkpoint_dir
- [ ] run_params.json 包含 comsol_port: 2036
- [ ] 仿体定义文件已通过结构化校验

## verdict 判定规则

本角色为 producer 角色，产出配置文件后自动流向校验角色：
- **confirmed**：eps_real.csv, eps_imag.csv, run_params.json 已写入，格式正确
- **fail**：配置文件生成失败或格式错误
