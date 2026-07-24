# APP 包结构规范

> 注入目标：结构生成师（M2）、编译预检师（M5）
> 用途：定义目标 APP 包 4 个结构文件的格式约束与编译校验标准

## 目的
本规范定义一个合法 APP 包必须包含的 4 个结构骨架文件格式，以及 compiler.py 的编译期校验规则。M2 据此生成骨架，M5 据此执行编译级预检。

## 核心准则

### 1. 四个结构文件
| 文件 | 角色 | 格式 | 核心内容 |
|------|------|------|----------|
| `app.yaml` | 编排权威源 | YAML | app_name / knowledge / roles / edges 四段 |
| `manifest.json` | 产出物清单 | JSON | schema_version / paths / workspace_template |
| `ROUTER.json` | 路由配置（编译产物） | JSON | schema_version / entry / steps[].transitions |
| `registry.json` | 角色注册表（编译产物） | JSON | 角色数组（role_name/skill_path/blocking_mode/outputs/inputs/gate_rules/input_groups/verdicts） |

### 2. app.yaml 四段结构
- **app_name**：APP 名称（与目录名一致）
- **knowledge**：公共知识文档声明（`- 名称: 路径` + `inject_to: [角色]`）
- **roles**：角色定义（每角色 confirm/inputs/outputs）
- **edges**：编排拓扑（支持 `A → B` / `A → [B,C]` / `[A,B] → C` / `when:` / `max_executions:`）

### 3. 合法字段
角色仅允许以下字段：`confirm` / `inputs` / `outputs` / `fail_max_executions`。
- `type` 字段已废弃（静默忽略）
- `verdicts` / `loop` / `gate` 字段已废弃（编译报错）

### 4. edges 语法
- `A → B`：无条件边（默认 verdict = confirmed）
- `A → [B, C]`：FORK 扇出
- `[A, B, C] → D`：JOIN 同步汇入
- `A → B when: result.verdict == "xxx"`：条件路由
- `A → B max_executions: N`：循环上限
- verdict 以 `fail_` 开头 → 编译器识别为 backward 回退边
- `fail` 是系统保留词（Gate 专属），不写入 schema enum

### 5. 编译校验规则（compiler.py --check）
- E1 死链：transition target 不存在
- E2 不可达节点：从 entry 无法到达
- E3 终态不可达：节点无法到达任何终态
- E4 死循环：forward 环无退出
- E5 跨分支泄漏：fork 后多分支无合法 JOIN 汇聚
- E7 条件路由无 verdict：有非 confirmed 的 normal 出边但 schema 缺 result.verdict

## 判别清单

M5 编译预检时逐项核对：
- [ ] app.yaml 四段齐全（app_name/knowledge/roles/edges）？
- [ ] 有至少一个 confirm: manual 的入口角色？
- [ ] edges 覆盖所有角色（无死角色）？
- [ ] 有边指向"完成"（终态可达）？
- [ ] 所有 FORK 扇出 ≤ 3？
- [ ] `compiler.py --check` 返回 0 错误？

## 反模式
- ❌ 手动编辑 ROUTER.json/registry.json（应由 compiler 从 app.yaml 编译生成）
- ❌ 在角色定义中使用已废弃的 type/verdicts/loop/gate 字段
- ❌ 回退边 verdict 不用 fail_ 前缀（会导致编译器误判为 normal 前进边）
