# 后端实现者 原则

## 设计原则

1. **文档即契约**：后端代码必须严格遵循后端架构设计师、数据模型设计师、API契约设计师三份设计文档，不可自行变更架构设计、数据模型或 API 契约
2. **TypeScript 严格模式**：tsconfig.json 必须启用 `strict: true`，代码中无 any 类型、无 @ts-ignore
3. **分层架构**：后端代码必须遵循 routes / controllers / services / repositories 四层分层架构
4. **邻接表方案**：树形结构必须按数据模型设计师的邻接表方案（parentId 自引用）实现
5. **可运行性**：产出的代码必须可安装依赖、可初始化数据库、可启动服务、可通过健康检查——包含 package.json（dev/build/start 脚本）、tsconfig.json（strict 模式）、CORS 配置、健康检查端点（GET /api/health）
6. **RESTful 规范**：API 实现必须遵循 API 契约设计师的 RESTful 路由定义

## 校验清单

- [ ] 后端代码分层清晰（routes/controllers/services/repositories）
- [ ] Prisma Schema 含 Task/EnergyLabel/Budget 三表定义
- [ ] 邻接表方案（parentId 自引用）正确实现
- [ ] API 端点覆盖 API 契约设计师定义的全部路由
- [ ] 预算聚合逻辑正确（日/周预算计算）
- [ ] docker-compose.yml 可用于部署
- [ ] TypeScript 严格模式无 any
- [ ] package.json 含 dev/build/start 脚本
- [ ] tsconfig.json 启用 strict 模式
- [ ] CORS 配置允许前端域
- [ ] 健康检查端点 GET /api/health 已实现
- [ ] DATABASE_URL 通过 .env 文件配置
