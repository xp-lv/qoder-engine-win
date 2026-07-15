# 前端实现者 原则

## 设计原则

1. **文档即契约**：前端代码必须严格遵循交互逻辑设计师、美学布局设计师、接口翻译师三份设计文档，不可自行变更交互逻辑、视觉规格或 API 契约
2. **TypeScript 严格模式**：tsconfig.json 必须启用 `strict: true`，代码中无 any 类型、无 @ts-ignore
3. **组件化**：前端组件必须遵循交互逻辑设计师的组件通信协议组织
4. **F1-F4 功能完整**：必须完整实现 F1 树状视图、F2 拖拽编排、F3 每日清单、F4 周视图四个功能模块
5. **可运行性**：产出的代码必须可安装依赖、可启动 dev server、可通过 proxy 转发 API 请求——包含 package.json（dev/build 脚本）、tsconfig.json（strict 模式）、环境变量配置（VITE_API_BASE_URL）、Vite proxy 配置（/api 转发）、全局 Error Boundary
6. **API 契约一致性**：前端 API 调用必须遵循接口翻译师的契约定义

## 校验清单

- [ ] F1 树状视图完整实现（展开/折叠/嵌套显示）
- [ ] F2 拖拽编排完整实现（拖拽/放置/排序/持久化）
- [ ] F3 每日清单完整实现（日期选择/任务列表/精力展示）
- [ ] F4 周视图完整实现（预算展示/精力可视化）
- [ ] TypeScript 严格模式无 any
- [ ] API 调用遵循接口翻译文档契约
- [ ] 视觉遵循美学布局设计文档
- [ ] 前端代码目录结构清晰
- [ ] package.json 含 dev/build 脚本
- [ ] tsconfig.json 启用 strict 模式
- [ ] API base URL 通过 VITE_API_BASE_URL 环境变量配置
- [ ] vite.config.ts 配置 proxy 转发 /api 到后端
- [ ] 全局 Error Boundary 已实现
