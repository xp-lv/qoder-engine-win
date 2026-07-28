# 反演算法插件化架构

> 本文档说明 pipline 的反演算法插件化机制。每个反演算法作为独立插件，通过统一入口接入管线，支持随插随用。

## 架构概览

```
                  共享基础设施（不变）
        ┌──────────────────────────────────┐
        │ config/  utils/  core_forward/     │
        │ core_jobs/  core_jhyp/  core_adjoint/ │
        └──────────┬───────────────────────┘
                   │ 标准接口
                   ▼
        ┌──────────────────────────────────┐
        │       experiment/run_experiment.m   │
        │  (公共流程：setup→mphstart→        │
        │   fem_mesh→solve_forward→J_obs→    │
        │   加载插件→run_inversion→三件套)    │
        └──────────┬───────────────────────┘
                   │ addpath + 调用
                   ▼
        ┌──────────────────────────────────┐
        │     algorithm/plugin_xxx/           │
        │  └── run_inversion.m               │
        │      (统一签名，自包含反演逻辑)      │
        └──────────────────────────────────┘
```

## 核心组件

### 1. run_experiment.m（统一调度入口）

位置：`experiment/run_experiment.m`

负责所有公共流程，插件只负责反演算法逻辑：

```
run_experiment 做的事：
  ① setup() + config()
  ② mphstart + mphload
  ③ fem_mesh_utils → voxel
  ④ 设真值 eps_r = 5.0
  ⑤ solve_forward → E_total
  ⑥ extract_scattered + lightcone_project → J_obs
  ⑦ fibonacci_sphere → 光锥方向
  ⑧ addpath(plugin_dir) → 加载插件
  ⑨ state = run_inversion(model, voxel, lc, grid, p)  ← 插件入口
  ⑩ 输出三件套（cos θ / F_cheb / 收敛信息）
```

调用方式：
```matlab
% 方式一：使用 config.m 中的默认插件
run_experiment()

% 方式二：指定插件名
run_experiment('plugin_a12')
run_experiment('plugin_basic')
run_experiment('plugin_c01')
run_experiment('plugin_my_new')
```

### 2. 插件统一接口

每个插件目录下必须有一个 `run_inversion.m`，签名固定：

```matlab
function state = run_inversion(model, voxel, lc, grid, p)
% 输入:
%     model   COMSOL 模型对象（须已 mphload + solve_forward）
%     voxel   体素结构（含 pos, dV, epsilon_r, mask_interior, gauss_pos, gauss_w）
%     lc      LightConeData（含 k_dir, k_vec, dOmega, J_obs_perp）
%     grid    测量网格（含 pos, norm, theta_hat, phi_hat, weight）
%     p       config 结构体
% 输出:
%     state   反演状态，至少含以下字段:
%             .converged        (logical)
%             .iteration        (int, 完成的迭代数)
%             .residual         (double, 最终残差)
%             .epsilon_r        ([N_v×1], 最终介电常数)
%             .history_residual ([max_iter×1], 残差历史)
%             .history_J_hyp    ([N_k×3×max_iter], J_hyp 历史，用于三件套计算)
```

### 3. 当前可用插件

| 插件目录 | 算法 | 说明 |
|---------|------|------|
| `algorithm/plugin_basic/` | 基础伴随梯度法 | 调用 core_inversion/inversion_loop，使用 Born 近似 J_hyp |
| `algorithm/plugin_a12/` | A12 B-spline + TV 多频反演 | B-spline 参数化 + TV 正则化 + 3 频率（1/2/3 GHz）+ F_data-only Armijo |
| `algorithm/plugin_c01/` | C01 复数均匀球反演 | 复数 eps_r 反演（Re+Im 同时优化），单频 1 GHz |

## 如何切换算法

在 `config/config.m` 中修改一行：

```matlab
p.inversion_plugin = 'plugin_a12';   % 改为 'plugin_basic' / 'plugin_c01' / 'plugin_my_new'
```

或在调用时传参覆盖：

```matlab
run_experiment('plugin_basic');  % 临时用 basic 插件，不改 config
```

## 如何新建插件

### 步骤

1. 在 `algorithm/` 下创建插件目录：`mkdir algorithm/plugin_my_new`
2. 创建入口函数 `algorithm/plugin_my_new/run_inversion.m`，实现统一签名
3. 在 `run_inversion.m` 内实现你的反演算法逻辑
4. 调用 `run_experiment('plugin_my_new')` 执行

### 最小模板

```matlab
function state = run_inversion(model, voxel, lc, grid, p)
%PLUGIN_MY_NEW 我的自定义反演算法

fprintf('========== [plugin_my_new] 反演启动 ==========\n');

% 你的算法专属参数
p.my_param = 42;

% 初始化状态
N_v = length(voxel.epsilon_r);
state.converged = false;
state.iteration = 0;
state.residual = 1.0;
state.epsilon_r = voxel.epsilon_r;
state.history_residual = zeros(p.max_iter, 1);
state.history_J_hyp = zeros(size(lc.J_obs_perp, 1), 3, p.max_iter);

% === 你的反演主循环 ===
for iter = 1:p.max_iter
    % ① 正演
    [E_total, ~, ~] = solve_forward(model, voxel, p);

    % ② 计算 J_hyp（你的方法）
    % J_hyp = my_jhyp_method(...);

    % ③ 计算残差
    % residual = compute_cost(...);

    % ④ 计算梯度
    % g = my_gradient(...);

    % ⑤ 更新 eps_r
    % voxel.epsilon_r = update(...);

    % 记录历史
    state.history_residual(iter) = residual;
    state.history_J_hyp(:, :, iter) = J_hyp;

    if residual < p.eps_tol
        state.converged = true;
        state.iteration = iter;
        break;
    end
end

state.residual = residual;
state.epsilon_r = voxel.epsilon_r;

fprintf('========== [plugin_my_new] 反演完成 ==========\n');
fprintf('  最终残差: %.6e, 收敛: %d\n', state.residual, state.converged);

end
```

## 插件可调用的公共函数

插件内部可以调用 pipline 的全部公共函数：

| 函数 | 目录 | 用途 |
|------|------|------|
| `solve_forward(model, voxel, p)` | core_forward/ | COMSOL 正演求解 |
| `solve_adjoint(model, voxel, p, f_adj)` | core_forward/ | COMSOL 伴随求解 |
| `extract_scattered(model, grid)` | core_jobs/ | 提取散射场 |
| `lightcone_project(grid, sf, p)` | core_jobs/ | 光锥投影 → J_obs |
| `equivalent_source(voxel, E_total, p)` | core_jhyp/ | Born 等效源 |
| `lightcone_hyp(voxel, J_equi, lc, p)` | core_jhyp/ | Born 傅里叶变换 → J_hyp |
| `compute_jhyp_comsol(model, lc, p)` | core_jhyp/ | COMSOL 全波 J_hyp |
| `compute_cost(lc, p)` | core_adjoint/ | 代价函数 F |
| `compute_gradient(...)` | core_adjoint/ | 精确梯度 g |
| `build_adjoint_source(...)` | core_adjoint/ | Born 伴随源 |
| `check_convergence(lc, p)` | core_adjoint/ | 收敛判断 |
| `exp07a_bspline_param(voxel, p)` | algorithm/ | B-spline 降维算子 |
| `exp07a_tv_reg(voxel, p)` | algorithm/ | TV 正则化梯度 |

## 基线性能参考

| 指标 | 值 | 来源 |
|------|-----|------|
| 单次正演（solve_forward） | ~3-5 秒 | COMSOL LU 分解 |
| 单次反演迭代 | ~8-12 秒 | 正演+伴随+梯度+线搜索 |
| A12 完整反演（10 iter × 3 freq） | ~5-10 分钟 | 30 次正演 |
| cos θ 基线 | 0.9929 | A12 5/7 PASS |
| F_cheb 基线 | 0.091 | A12 5/7 PASS |

## 常见问题

### Q: 插件内需要设专属参数怎么办？

在 `run_inversion.m` 开头用 `if ~isfield(p, 'xxx')` 设默认值：

```matlab
if ~isfield(p, 'my_lambda'), p.my_lambda = 0.001; end
if ~isfield(p, 'my_max_iter'), p.my_max_iter = 20; end
```

这样既可以在 config.m 中覆盖，也可以用插件默认值。

### Q: 插件内需要创建输出目录怎么办？

```matlab
if ~isfield(p, 'dir_result_my')
    p.dir_result_my = fullfile(p.dir_result, 'my_algo');
    if ~exist(p.dir_result_my, 'dir'), mkdir(p.dir_result_my); end
end
```

### Q: 如何在命令行运行？

```powershell
cd "d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline"
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "addpath('config','experiment'); run_experiment('plugin_a12')"
```

注意：`addpath('config','experiment')` 是必需的——setup() 在这两个目录中。

## MATLAB 向量维度鲁棒性检查清单

> **背景**：H022 + H024 累计两起同类维度崩溃 bug，共同根因是 MATLAB 向量索引的「源方向继承」语义——`A(I)` 与 `A` 同方向（而非与索引 `I` 同方向），导致 `horzcat(A(I), (c:d))` 在 `A` 为列向量时崩溃。本检查清单供算法实现者/管线维护者在代码审查时使用。

### 检查项

当出现以下模式时，**必须**显式归一化向量方向：

| 模式 | 风险 | 修复 |
|------|------|------|
| `[A(idx), B(idx), (c:d)]` | `A(idx)` 继承 `A` 的方向；若 `A` 为列向量则 horzcat 崩溃 | `A(:).'` 或 `normalize_vec(A, 'row')` |
| `[A(idx); (c:d).']` | vertcat 方向不一致 | `A(:)` 或 `normalize_vec(A, 'col')` |
| `pos_inner - hole_pos.'` | `hole_pos` 为 `[1×3]` 时 `.'` 不变；为 `[3×1]` 时转置后维度匹配 | 统一用 `hole_pos(:).'` |
| `sort(...)` 结果参与拼接 | `sort` 保留输入方向 | 排序后立即 `(:).'` 或 `(:)` |

### 工具函数

`utils/normalize_vec.m` 提供语义化的方向归一化：

```matlab
% horzcat 前统一为行向量
idx_row = normalize_vec(sort_idx, 'row');
result  = [idx_row(1:k), idx_row(k+1:end), (a:b)];

% vertcat 前统一为列向量
col_vec = normalize_vec(data, 'col');
```

### 历史记录

| Bug | 位置 | 根因 | 修复 |
|-----|------|------|------|
| H022 | `C01_cavity_inversion_loop.m` line 204 | `hole_true.'` 未归一化（`[1×3]` 侥幸通过，`[3×1]` 崩溃）| `hole_true(:).'` |
| H024 | `C01_cavity_inversion_loop.m` line 594 | `d_sort_idx`（列）与 `(a:b)`（行）horzcat 崩溃 | `d_sort_idx(:).'` |
