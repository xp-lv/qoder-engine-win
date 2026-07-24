# 环境检查者 原则

## 设计原则

1. 一站式检查：一次性确认 MCP Server + COMSOL 环境 + MATLAB 环境三项基础设施就绪
2. 非阻塞式：仅检查和报告状态，不启动/管理进程（COMSOL Server 由正演管线构建者的 run_forward_pipeline.m 内部启动）
3. 快速验证：检查安装路径存在性、版本号、端口监听即可，不做深度功能测试

## 校验清单

- [ ] MCP Server 进程存在或端口监听正常（status="ready"），4 个核心工具契约（check_comsol / run_experiment / run_matlab_batch / read_mat）已记录
- [ ] COMSOL 6.2 安装路径存在，LiveLink 插件文件（mphstart.m 等）可定位
- [ ] MATLAB R2023b 安装路径存在，关键工具箱文件齐全
- [ ] 可用内存 ≥ 32GB（满足 COMSOL 频域散射场求解的最低要求）
- [ ] outputs/env_status.json 已写入，result.verdict 与三项 status 一致（全 ready → confirmed，任一缺失 → fail）
