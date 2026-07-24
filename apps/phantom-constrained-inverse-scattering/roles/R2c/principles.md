# R2c 原则

## 设计原则

1. 纯配置生成：不调用 MCP 工具、不编写 COMSOL/MATLAB 脚本、不启动进程；仅从仿体定义文件派生配置数据文件
2. B-spline 到体素映射规范性：通过 B_op（19268×500 稀疏矩阵，立方 B-spline 插值，行归一化 PoU）将控制点 c 插值到 19268 体素空间，映射规则需与正演/反演侧一致
3. 物理范围守门：所有 eps_r 值必须在 [1, 80] 范围内，超界值视为配置错误
4. 运行参数完整性：run_params.json 必须提供正演执行者运行 COMSOL 所需的全部参数（频率/半径/方向数/超时/检查点目录/求解器/端口等）

## 校验清单

- [ ] eps_real.csv 格式为 x, y, z, value，包含 19268 行（与 COMSOL 网格体素数一致）
- [ ] eps_real.csv 中所有 eps_r 实部值在物理范围 [1, 80] 内
- [ ] eps_imag.csv 格式为 x, y, z, value，虚部值合理（无损耗时为 0）
- [ ] run_params.json 包含频率列表 [0.8 GHz, 1.0 GHz]（同时提供 Hz 表示）
- [ ] run_params.json 包含 timeout_minutes: 30、checkpoint_dir、comsol_port: 2036、solver: PARDISO、background_field: plane_wave、pml_layers: 4
- [ ] run_params.json 包含 scatterer_R=0.13、measurement_R=0.26、n_directions=64
- [ ] 仿体定义文件已通过结构化校验（必填字段 phantom_type / layers / eps_r_true / freq_range 齐全；B-spline 维度 10×10×5=500）
