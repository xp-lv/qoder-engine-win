# pipline 接口映射

> 注入目标：实验执行者（M3）、管线优化者（M6）、算法实现者（M2）
> 用途：将 skill.md 中的抽象文件名映射到 COMSOL/pipline 的实际文件，声明路径，提供参数对照

## 目的

本文档解决 skill.md 引用的文件名与 COMSOL/pipline 实际文件名不一致的问题，同时声明 pipline 的绝对路径和 L1 四目录的完整文件清单，使角色执行时能精确定位管线代码。

## 核心准则

### 1. pipline 根路径（权威声明）

```
pipline 根路径:  d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline\
COMSOL 模型:     d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph
MATLAB 可执行:   D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe
COMSOL mphserver: localhost:2036（须独立终端长期运行）
```

所有角色执行时，pipline 根路径以此为绝对基准。skill.md 中的相对路径（如 `core_forward/`）均相对于此根路径解析。

### 2. 文件名映射表（skill.md 引用 → pipline 实际文件）

| skill.md 中的引用名 | pipline 实际文件名 | 所在目录 | 用途 |
|---------------------|-------------------|----------|------|
| `forward_solve.m` | **`solve_forward.m`** | `core_forward/` | 正演求解（update_eps → COMSOL solve → read_field） |
| `compute_jobs.m` | `compute_jobs.m` | `core_jobs/` | J_obs 流水线调度 |
| `compute_cost.m` | `compute_cost.m` | `core_adjoint/` | 代价函数 F = ‖ΔJ‖² / ‖J_obs‖² |
| `compute_gradient.m` | `compute_gradient.m` | `core_adjoint/` | 精确梯度 g = gd + gi |
| `linesearch.m` | `linesearch.m` | `core_adjoint/` | Armijo 回溯线搜索 |
| `bspline_param.m` | **`exp07a_bspline_param.m`** | `algorithm/` | B-spline 3D cubic 参数化算子 |
| `tv_regularization.m` | **`exp07a_tv_reg.m`** | `algorithm/` | TV L1 各向同性正则化 |
| `inversion_loop.m` | `inversion_loop.m` | `core_inversion/` | 7 步伴随法反演主循环 |
| （M4 引用）`compute_three_piece.m` | **不存在**（逻辑在 `experiment/verify_forward_pipeline.m` + `algorithm/A12_postprocess.m`） | — | cos θ / F_cheb / PASS 计算 |
| （M4 引用）`sanity_check.m` | **不存在**（需新建） | — | 输出健全性校验 |

> **关键差异**（粗体标注）：skill.md 写 `forward_solve.m`，实际是 `solve_forward.m`；写 `bspline_param.m`，实际是 `exp07a_bspline_param.m`；写 `tv_regularization.m`，实际是 `exp07a_tv_reg.m`。

### 3. pipline 算法目录完整文件清单（M2 改 / M6 全部可维护）

#### core_jhyp/（J_hyp 计算层，5 文件，M2 可改算法 / M6 可维护）
| 文件 | 职责 | 优化关注点 |
|------|------|-----------|
| `compute_jhyp.m` | J_hyp 流水线调度 | 调度效率 |
| `equivalent_source.m` | Born 等效源 J_equi = -iωε₀(ε_r-1)E | 向量化 |
| `lightcone_hyp.m` | Born 傅里叶变换 → J_hyp | FFT 效率 |
| `compute_jhyp_comsol.m` | COMSOL 全波 J_hyp（非 Born，备选路径） | COMSOL 调用开销 |
| `build_adjoint_source_fullmaxwell.m` | Full Maxwell 伴随源 | — |

#### core_adjoint/（梯度与优化层，5 文件，M2 可改算法 / M6 可维护）
| 文件 | 职责 | 优化关注点 |
|------|------|-----------|
| `build_adjoint_source.m` | Born 伴随源 k 空间残差回投 | — |
| `compute_gradient.m` | 精确梯度 g = gd + gi（4-pt Gauss 积分） | Gauss 积分效率 |
| `compute_cost.m` | 代价函数 F = ‖ΔJ‖² / ‖J_obs‖² | — |
| `check_convergence.m` | 收敛判断 residual < eps_tol | — |
| `linesearch.m` | Armijo 回溯线搜索 | 步长策略 |

#### core_inversion/（反演循环，1 文件，M2 可改算法 / M6 可维护）
| 文件 | 职责 | 优化关注点 |
|------|------|-----------|
| `inversion_loop.m` | 7 步循环（227 行）：正演→J_hyp→收敛→伴随源→伴随求解→梯度→线搜索 | 迭代收敛速度、内存预分配 |

#### algorithm/（改进算法，10 文件，M2 可改算法 / M6 可维护）

> **M6 管线优化者额外可维护的目录**（M2 不得改动这些目录）：
> - config/（全局参数）、utils/（工具函数）、core_forward/（正演层）、core_jobs/（J_obs 计算层）、viz/（可视化）、experiment/（验证脚本）
| 文件 | 职责 | 优化关注点 |
|------|------|-----------|
| `exp07a_bspline_param.m` | B-spline 降维算子 [N_v × N_c] sparse | 稀疏矩阵构建效率 |
| `exp07a_tv_reg.m` | TV L1 正则化梯度 | 差分效率 |
| `A12_inversion_loop.m` | A12 改进版主循环（B-spline + TV） | — |
| `A12_linesearch.m` | A12 simple descent 线搜索 | — |
| `A12_multi_freq_inversion.m` | A12 实验编排入口（Full Maxwell 多频） | — |
| `A12_postprocess.m` | A12 后处理（判据 CSV + 图 + 收敛曲线） | — |
| `C01_inversion_loop.m` | C01 复数反演循环 | — |
| `C01_linesearch.m` | C01 复数线搜索 | — |
| `C01_uniform_complex_inversion.m` | C01 实验编排入口 | — |
| `C01_postprocess.m` | C01 后处理 | — |

### 4. config_snapshot.json ↔ config.m 参数映射表

M3 写 config_snapshot.json 时，物理参数七字段从 pipline 的 `config/config.m` 读取：

| config_snapshot.json 字段 | config.m 字段 | 默认值 | 说明 |
|---------------------------|---------------|--------|------|
| `physics_params.r` | `p.a_scatter` | 0.13 | 散射体球半径 (m) |
| `physics_params.R` | `p.R_sphere` | 0.26 | 测量球面半径 (m) |
| `physics_params.f` | `p.freq` | 1e9 | 频率 (Hz) |
| `physics_params.lambda` | `p.lambda` | 0.3 | 波长 (m) |
| `physics_params.ka` | `p.k0 * p.a_scatter` | 2.72 | 波数×半径（无量纲） |
| `physics_params.n_dirs` | `p.N_k` | 64 | Fibonacci 方向采样数 |
| `physics_params.n_voxels` | FEM mesh 提取后 `length(voxel.epsilon_r)` | 19268 | 总体素数（673 内层） |

> **注意**：`ka` 在 config.m 中不直接存在，需用 `p.k0 * p.a_scatter` 计算。`n_voxels` 在 config.m 中不存在，需从 `fem_mesh_utils(model, p, p.a_scatter)` 返回的 voxel 结构获取。

### 5. 性能基线（M6 优化基准）

| 指标 | 当前值 | 来源 |
|------|--------|------|
| 单次正演（solve_forward）耗时 | ~3-5 秒 | COMSOL LU 分解 |
| 单次伴随求解（solve_adjoint）耗时 | ~2-3 秒（复用 LU） | — |
| 单次反演迭代（inversion_loop 一步） | ~8-12 秒 | 正演+伴随+梯度+线搜索 |
| 完整反演（10 次迭代） | ~2-5 分钟 | — |
| MATLAB 端内存 | ~50 MB（673×3 数组 + B-spline sparse 5-19 MB） | — |
| COMSOL FEM 内存 | ~2-4 GB（LU 分解） | 瓶颈所在 |
| 完整验证脚本（verify_forward_pipeline） | ~30 秒 | 10 步检查 |

## 判别清单

- [ ] skill.md 中引用的文件名是否已通过本映射表对齐到 pipline 实际文件？
- [ ] pipline 根路径是否已声明为绝对路径？
- [ ] config_snapshot.json 的七字段是否从 config.m 正确映射？
- [ ] L1 四目录的优化目标文件是否在本清单中定位？

## 反模式

- ❌ skill.md 写 `forward_solve.m` 但 pipline 实际是 `solve_forward.m`（role-executor 找不到文件）
- ❌ 在 config_snapshot.json 中手写物理参数而不从 config.m 读取（参数漂移）
- ❌ M6 优化时不知道 L1 目录里有哪些文件（盲目猜测优化目标）
- ❌ 硬编码相对路径而不声明 pipline 根路径（role-executor 无法定位管线）
