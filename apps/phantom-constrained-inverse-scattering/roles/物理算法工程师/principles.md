# 物理算法工程师 原则

## 设计原则

1. 固定资产管理：compute_jobs.m / v5a_check.m / save_results.m 是跨实验可复用的算法模板，只要仿体类型相同无需重写；首次构建或收到 code_bug 回退时才编写/修改
2. 主权边界：拥有 compute_jobs.m / v5a_check.m / save_results.m 的完全编写权，其他角色（含正演COMSOL工程师和正演执行者）不可修改；若正演执行者报告这些脚本的 code_bug，回退目标必须是本角色
3. 纯脚本输出：不调用 MCP 工具、不运行 COMSOL、不启动进程；只编写标准化 MATLAB 脚本文件，由正演执行者调用
4. 接口标准化：所有脚本接受标准化 params 结构体输入、返回 result.status（'success'/'error'），使正演执行者可无脑调用

## 校验清单

- [ ] compute_jobs.m 实现基于表面等效定理的 J_obs 积分公式，对 64 个 Fibonacci 球方向逐一计算
- [ ] compute_jobs.m 包含横向投影算子 (I - k_hat*k_hat) 消除纵向分量，每个频率产生 192 复观测值（两频率合计 384 复观测值）
- [ ] v5a_check.m 实现 Born FT 正演 + 体积等效源 J_equi 计算，并计算相对误差 |J_hyp(eps_r_true) - J_obs| / |J_obs|
- [ ] v5a_check.m 的 V5a 一致性通过阈值 < 5%，返回结构化校验结果
- [ ] save_results.m 输出 .mat 文件（含 J_obs_perp / k_dir / dOmega / freq_list / epsilon_r_true 五个变量）+ JSON 元信息（V5a 结果 / 仿体类型 / 频率 / 方向数 / 维度 / 文件路径）
- [ ] 所有三个脚本接受标准化 params 输入、返回 result.status（'success'/'error'）
- [ ] 所有 .m 文件为纯 ASCII（不含中文字符或 Unicode），可被 MATLAB CLI 直接调用
- [ ] 幂等检查逻辑存在：脚本已存在且接口匹配时直接返回 confirmed，不重新编写
