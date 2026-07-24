# 需求接收者 原则

本文件定义 producer 角色「需求接收者」产出物（需求文档 00-需求描述.md）的设计原则与校验清单，供校验角色（需求接收者（校验））在 Gate 校验时参照执行。

## 设计原则

1. **权威基准必须为 GitHub 最新克隆**：需求文档必须明确声明 Mac 源仓库从 GitHub 克隆到 mac-repo-clone/，并记录 commit hash；禁止使用当前工作区本地文件作为 Mac 侧差异分析的基准，避免基于过期代码进行同步。
2. **双仓库路径必须完整声明**：需求文档必须同时包含 Mac 源克隆路径（mac-repo-clone/）和 Win 目标克隆路径（win-repo-clone/），两个仓库地址（github.com:xp-lv/qoder-engine.git 与 github.com:xp-lv/qoder-engine-win.git）及各自的 commit hash 均须记录，确保下游迁移执行者能定位源与目标。
3. **同步范围与排除规则必须明确**：需求文档必须声明同步范围（engine/ 全部文件 + apps/ 全部应用 + .qoder/ 全部配置）和排除规则（.sh 文件不同步到 Win 版、.cmd 文件不被 Mac 版覆盖），避免迁移执行者因范围模糊而误删或遗漏文件。

## 校验清单

- [ ] 需求文档（00-需求描述.md）存在且非空
- [ ] 需求文档包含 Mac 源仓库地址 github.com:xp-lv/qoder-engine.git
- [ ] 需求文档包含 Win 目标仓库地址 github.com:xp-lv/qoder-engine-win.git
- [ ] 需求文档包含 Mac 源仓库的 commit hash（克隆后已记录）
- [ ] 需求文档包含 Win 目标仓库的 commit hash（克隆后已记录）
- [ ] 需求文档包含 Mac 源克隆路径（mac-repo-clone/）和 Win 目标克隆路径（win-repo-clone/）
- [ ] 需求文档包含同步范围（engine/ + apps/ + .qoder/）
- [ ] 需求文档包含排除规则（.sh 不同步、.cmd 不覆盖）
- [ ] 需求文档明确指出差异分析基准为 mac-repo-clone/（GitHub 最新版），非当前工作区本地文件
