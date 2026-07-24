# 正演COMSOL工程师 原则

## 设计原则

1. 固定资产管理：forward_solve.m / adjoint_solve.m / run_forward_pipeline.m 是跨实验可复用的算法模板，仿体类型相同时无需重写；仅首次构建、仿体类型变更或 code_bug 回退时才编写/修改
2. 主权边界分明：拥有 forward_solve.m / adjoint_solve.m / run_forward_pipeline.m 的完全编写权；不可修改 compute_jobs.m / v5a_check.m / save_results.m（属物理算法工程师主权）；不可运行 COMSOL、不可修改 config/ 与 outputs/
3. API 正确性优先：以 COMSOL/model_export.m（COMSOL 6.2 Desktop 导出的正确 API 代码）为权威参考，所有 API 调用模式（Sphere + setIndex('layer')、Study Feature 类型名 'Frequency'、cellfun(@char,...) tag 转换、PML coordSystem.create、FreeTet 网格、study.feature('freq').set('plist',...)）必须与参考一致
4. 接口标准化：所有脚本接受标准化 params 输入、返回 result.status（'success'/'error'），run_forward_pipeline.m 返回 pipeline_result 含 status + stage 字段

## 校验清单

- [ ] forward_solve.m 接受 params 结构体输入（eps_real_csv / eps_imag_csv / freq_list / measurement_R / n_directions / output_path / timeout_minutes），返回 result.status
- [ ] 几何构建使用 Sphere + setIndex('layer') 或材料属性模式（mat2 + relpermittivity）
- [ ] Study Feature 类型名为 'Frequency'（不是 'Freq' 或 'FrequencyDomain'），频率通过 study.feature('freq').set('plist', ...) 设置
- [ ] PML 通过 model.coordSystem.create 配置；网格使用 FreeTet（不是 autoMeshSize）；求解器为 PARDISO
- [ ] 所有 .tags 访问使用 cellfun(@char, cell(...), 'UniformOutput', false) 进行类型转换
- [ ] adjoint_solve.m 包含伴随源写入（int4-int9）、External_current_density (vec1) 创建、sctr1 禁用/恢复、模型状态恢复逻辑
- [ ] run_forward_pipeline.m 单进程串行编排全部子步骤（COMSOL Server 启动 → LiveLink → forward_solve → compute_jobs → v5a_check → save_results → 清理），每阶段检查 result.status
- [ ] 所有 .m 文件为纯 ASCII（不含中文字符或 Unicode）
- [ ] 幂等检查逻辑存在：脚本已存在且 function 签名匹配时直接返回 confirmed，不重新编写
