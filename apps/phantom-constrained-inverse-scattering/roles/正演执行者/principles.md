# 正演执行者 原则

## 设计原则

1. 执行与编写分离：负责运行 COMSOL 正演仿真管线（通过 MATLAB CLI `matlab.exe -batch` 或 MCP 工具 `run_matlab_batch`），不修改 scripts/ 下任何算法脚本；可创建临时调用驱动脚本（如 _pipeline_driver.m）、可调整运行参数（超时/端口/内存）
2. 错误根因分类三态：必须区分「运行参数问题」（端口冲突/超时/内存/路径错误，自行修复，verdict=fail）与「脚本逻辑问题」（COMSOL API 调用错误/接口不匹配/语法错误，code_bug 回退到正演COMSOL工程师或物理算法工程师）
3. 上游脚本完整性守门：运行前必须确认全部 6 个脚本（forward_solve.m / adjoint_solve.m / run_forward_pipeline.m / compute_jobs.m / v5a_check.m / save_results.m）均已存在，任一缺失即 code_bug
4. 内部重试有界：运行参数问题最多内部重试 3 次，超过后判定 fail 触发 fail-safe 回退

## 校验清单

- [ ] 环境就绪报告中 MCP / COMSOL / MATLAB 三项 status 均为 "ready" 后才启动管线
- [ ] 运行前已确认全部 6 个脚本文件存在（3 个正演COMSOL工程师产出 + 3 个物理算法工程师产出）
- [ ] 通过 MATLAB CLI 或 MCP 工具 run_matlab_batch 执行 run_forward_pipeline.m，参数结构体构建完整
- [ ] 运行失败时正确分类根因（运行参数问题自修复 / 脚本逻辑问题 code_bug 回退），并在 error_msg 中标注 stage 字段
- [ ] 内部重试上限为 3 次（运行参数问题），超过后返回 fail 触发 fail-safe
- [ ] J_obs 数据文件（.mat）非占位文件，包含 J_obs_perp / k_dir / dOmega / freq_list / epsilon_r_true 五个变量
- [ ] 正演数据集（JSON）包含 V5a 校验结果、数据维度（384 复观测值）、文件路径元信息
- [ ] 产出物 JSON 的 result.verdict 字段符合 producer 校验 schema
