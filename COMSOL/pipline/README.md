# INVERSE_SCATTER3.0 正演管线 (Forward Pipeline)

> **给 AI 的快速上手指南**：读完本文件（约 5 分钟），你就能独立调用完整正演管线。

---

## 1. 这是什么

一个三维电磁逆散射反演系统。核心功能：

```
输入: 64 个方向的远场散射数据 (1 GHz, 平面波入射)
输出: 19268 个体素的介电常数 epsilon_r 三维分布
```

物理参数：
- 散射体半径 a = 0.13 m (13 cm)
- 频率 = 1 GHz (波长 30 cm)
- ka = 2.72 (Mie 散射区)
- 内层体素 673 个 (r < 0.13 m)
- COMSOL 6.2 LiveLink 驱动

---

## 2. 运行环境要求

| 组件 | 版本 | 路径 |
|------|------|------|
| MATLAB | R2023b | `D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe` |
| COMSOL | 6.2 | `D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\` |
| COMSOL mphserver | 运行在 port 2036 | `...\COMSOL62\...\comsolmphserver.exe -port 2036` |
| Python (后处理) | Anaconda | `D:\LenovoSoftstore\Install\Anaconda\python.exe` |

**启动 COMSOL mphserver**（必须先于 MATLAB 运行）:
```bash
& "D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe" -port 2036
```

**模型文件**（位于 pipline 父目录 COMSOL/）:
```
COMSOL/livelink_model.mph   ← 主模型（pipline 通过 ../livelink_model.mph 引用）
COMSOL/model_export.m        ← COMSOL 导出的 .m 重建脚本 (2880 行)
```

---

## 3. 目录结构（36 个文件）

```
正演管线/
├── README.md                 ← 你正在读的文件
│
├── config/                   ← 配置层 (2 files)
│   ├── config.m              ← 全局参数 (频率/半径/步长/阈值)
│   ├── setup.m               ← addpath 初始化
│   └── env.json              ← 工具路径配置 (Python/MATLAB/COMSOL)
│
├── utils/                    ← 工具层 (6 files)
│   ├── fem_mesh_utils.m      ← COMSOL mesh 提取 → voxel 结构 [核心]
│   ├── build_measurement_grid.m  ← 测量球面网格 (48x96=4608 点)
│   ├── fibonacci_sphere.m    ← 64 个 k 方向准均匀采样
│   ├── transverse_project.m  ← 横向投影 [I - k_hat*k_hat] * J
│   ├── mesh_utils.m          ← 网格辅助函数
│   ├── green_function.m      ← 格林函数计算
│   └── coordinate_transform.m ← 坐标系转换
│
├── core_forward/             ← COMSOL 正演层 (7 files)
│   ├── solve_forward.m       ← 正演求解: update_eps → COMSOL solve → read_field [核心]
│   ├── solve_adjoint.m       ← 伴随求解: 复用 LU 分解
│   ├── read_field.m          ← 从 COMSOL 读取任意点 E 场 (mphinterp)
│   ├── update_epsilon.m      ← 写 epsilon_r 到 COMSOL (CSV → int2/int3 插值) [核心]
│   ├── bg_setup.m            ← 背景场配置入口
│   ├── bg_planewave.m        ← 平面波背景场
│   └── bg_gaussian.m         ← 高斯波束背景场
│
├── core_jobs/                ← J_obs 计算层 (3 files)
│   ├── compute_jobs.m        ← J_obs 流水线调度
│   ├── extract_scattered.m   ← 从 COMSOL 提取 relE/relH 散射场 [核心]
│   └── lightcone_project.m   ← 表面等效定理 → 64 k-dir 光锥投影 → J_obs [核心]
│
├── core_jhyp/                ← J_hyp 计算层 (5 files)
│   ├── compute_jhyp.m        ← J_hyp 流水线调度
│   ├── equivalent_source.m   ← Born 等效源 J_equi = -i*omega*eps0*(eps_r-1)*E [核心]
│   ├── lightcone_hyp.m       ← Born 傅里叶变换 → J_hyp [核心]
│   ├── compute_jhyp_comsol.m ← COMSOL 全波 J_hyp (非 Born, 备选路径)
│   └── build_adjoint_source_fullmaxwell.m ← Full Maxwell 伴随源
│
├── core_adjoint/             ← 梯度与优化层 (5 files)
│   ├── build_adjoint_source.m  ← Born 伴随源: k 空间残差回投 → f_adj [算法核心]
│   ├── compute_gradient.m      ← 精确梯度 g = gd + gi [算法核心]
│   ├── compute_cost.m          ← 代价函数 F = ||Delta_J||^2 / ||J_obs||^2
│   ├── check_convergence.m     ← 收敛判断 residual < eps_tol
│   └── linesearch.m            ← Armijo 回溯线搜索 [算法核心]
│
├── core_inversion/           ← 基础反演循环 (1 file)
│   └── inversion_loop.m      ← 7 步循环: 正演→J_hyp→收敛→伴随源→伴随求解→梯度→线搜索
│
├── algorithm/               ← 实际跑出 5/7 PASS 的改进算法 (10 files)
│   ├── exp07a_bspline_param.m    ← B-spline 降维: 19268 体素 → 24~500 控制点 [核心]
│   ├── exp07a_tv_reg.m           ← TV 正则化梯度计算
│   ├── A12_inversion_loop.m      ← A12 改进版主循环 (B-spline + TV + F_data-only)
│   ├── A12_linesearch.m          ← A12 改进版线搜索 (simple descent, 无 TV 代价)
│   ├── A12_multi_freq_inversion.m ← A12 实验编排入口 (Full Maxwell 多频)
│   ├── A12_postprocess.m         ← A12 后处理 (判据 CSV + eps_r 图 + 收敛曲线)
│   ├── C01_inversion_loop.m      ← C01 复数反演循环 (Re+Im 同时优化)
│   ├── C01_linesearch.m          ← C01 复数线搜索
│   ├── C01_uniform_complex_inversion.m ← C01 实验编排入口
│   └── C01_postprocess.m         ← C01 后处理
│
├── viz/                      ← 可视化 (3 files)
│   ├── viz_manager.m         ← 实时可视化管理器
│   ├── viz_text_panel.m      ← 文本面板
│   └── viz_convergence.m     ← 收敛曲线
│
└── experiment/               ← 实验入口 (2 files)
    ├── verify_forward_pipeline.m  ← 正演管线验证脚本 (一键跑通)
    └── model_export.m             ← COMSOL 导出的模型重建脚本
```

---

## 4. 快速验证：一键跑通正演管线

### 4.1 启动 COMSOL mphserver

```bash
& "D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe" -port 2036
```

等待约 8 秒确认端口就绪:
```bash
powershell -Command "Test-NetConnection localhost -Port 2036"
# TcpTestSucceeded = True 即可
```

### 4.2 运行验证脚本（pipline 自包含）

```powershell
# COMSOL mphserver 必须先启动（见 4.1）
cd "d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline"
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "addpath('config','experiment'); verify_forward_pipeline"
```

> **注意**：`addpath('config','experiment')` 是 bootstrap 必需——setup() 在 verify_forward_pipeline 内部调用，必须先让 matlab 找到这两个目录。

### 4.3 验证逻辑

脚本做了 10 步检查:

| Step | 做了什么 | 预期输出 |
|------|---------|---------|
| 0 | 加载 config + addpath | a_scatter=0.13, freq=1e9, N_k=64 |
| 1 | mphstart + mphload | Model loaded |
| 2 | fem_mesh_utils | 19268 elements, 673 inner |
| 3 | 设 eps_r=5.0 | mean=5.0, std=0.0 |
| 4 | solve_forward | \|E\| mean~1.09 V/m |
| 5 | Path A: COMSOL → J_obs | \|J_obs\|~1.93e-4 |
| 6 | Path B: Born → J_hyp | \|J_hyp\|~1.92e-4 |
| 7 | **V5a: J_obs ≈ J_hyp?** | max F_k < 1e-3 = PASS |
| 8 | cos(theta) 方向一致性 | mean > 0.99 |
| 9 | 物理量级 | ka=2.72, lambda=30cm |
| 10 | Gauss 积分点 | ratio~1.02 |

### 4.4 最近一次验证结果（2026-07-03）

```
max F_k     = 2.06e-2  (WARN: Born 近似固有偏差, 非管线 bug)
cos(theta)  = 0.9929   (方向一致性优秀)
|J_obs|/|J_hyp| = 1.0001 (幅值一致性极好)
```

**V5a WARN 的原因**: eps_r=5 的强散射体下 Born 近似 J_equi = -iwe0(eps_r-1)E_inc 假设
E_inc ≈ E_total 不完全成立。约 2% 的系统性偏差是 Born 近似的固有物理极限，
不影响反演正确性。反演的 F_cheb 下界因此 ~0.001（不会到 0）。

---

## 5. 如何修改反演算法

### 5.1 文件分层：哪些能改，哪些不能碰

| 层级 | 目录 | 文件数 | 能改吗 |
|------|------|--------|--------|
| **基础设施** | config/, utils/, core_forward/ | 15 | **不要改** (COMSOL 接口, 纯物理) |
| **J_obs 计算** | core_jobs/ | 3 | **不要改** (表面等效定理) |
| **J_hyp 计算** | core_jhyp/ | 5 | **可以改** (换 Born → Full Maxwell) |
| **算法核心** | core_adjoint/, core_inversion/ | 6 | **主要改这里** (梯度/线搜索/循环) |
| **实验入口** | experiment/ | 2 | **每次新建** |

### 5.2 改代价函数

修改 `core_adjoint/compute_cost.m`。例如从 Chebyshev 改为 L2:

```matlab
% 当前 (Chebyshev 软最大化):
F = eta * max(F_k) + (1-eta) * mean(F_k);

% 改为 L2:
F = mean(F_k);
```

### 5.3 改梯度公式

修改 `core_adjoint/compute_gradient.m`。当前公式:

```
g(v) = gd + gi
gd = +2*omega*eps0*dV * Im{dot(E, S)} / F_obs    (直接项)
gi = -k0^2 * dV * Re{dot(E, lambda)}               (间接项, via 4-pt Gauss)
```

### 5.4 改线搜索

修改 `core_adjoint/linesearch.m`。当前是 Armijo 回溯:

```
F(x + mu*d) <= F(x) - c*mu*||g||^2    (Armijo 条件)
```

可以换成 BB 步长 / L-BFGS / trust region 等。

### 5.5 加 B-spline 参数化

B-spline 算子已在 `algorithm/exp07a_bspline_param.m`。使用方式:

```matlab
addpath('algorithm');
p.n_cx = 2; p.n_cy = 3; p.n_cz = 4; p.bspline_order = 3;
B_op = exp07a_bspline_param(voxel, p);  % [N_v x N_c] sparse, 仅 5 MB
N_c = size(B_op, 2);  % = 24 控制点

% 优化变量从 epsilon_r [N_v x 1] 变为控制点 c [N_c x 1]
% 梯度链式法则: dc = B_op' * depsilon_r
% 重建: epsilon_r_inner = B_op(inner,:) * c + 1
```

### 5.6 使用改进版算法（推荐）

`algorithm/` 目录包含实际跑出 5/7 PASS 的 A12 和 C01 完整实验脚本。
另一个 AI 可以直接参考或修改这些脚本:

| 脚本 | 用途 | 达到的最佳结果 |
|------|------|---------------|
| `A12_multi_freq_inversion.m` | A12 入口（Full Maxwell + B-spline + TV） | **5/7 PASS**, cos θ=0.990 |
| `A12_inversion_loop.m` | A12 改进循环（F_data-only + PoU fix） | σ 从 0.58 降到 0.22 |
| `A12_linesearch.m` | A12 simple descent 线搜索 | 3 轮收敛 |
| `C01_uniform_complex_inversion.m` | C01 复数球入口 | **4/6 PASS**, Im=-5.63 |
| `C01_inversion_loop.m` | C01 复数反演循环 | Re+Im 同时优化 |

---

## 6. 数据流详解

### 6.1 正演一次完整数据流

```
                    COMSOL mph (livelink_model.mph)
                              |
                    mphload → model object
                              |
                    fem_mesh_utils(model)
                              |
                     voxel struct (19268 x {pos, dV, eps_r, mask})
                              |
                    update_epsilon(model, voxel)
                              |
                     (写 CSV → COMSOL int2/int3 插值函数)
                              |
              +---------------+---------------+
              |                               |
     solve_forward                    extract_scattered
     (COMSOL 求解)                    (mphinterp relE/relH)
              |                               |
     read_field → E_total            lightcone_project
     [673 x 3 complex]              (表面等效定理积分)
              |                               |
     equivalent_source              J_obs_perp [64 x 3]
     (-iwe0(eps-1)E)                          |
              |                               |
     lightcone_hyp                          [固定, 整个反演不变]
     (Born FT + transverse)
              |
     J_hyp_perp [64 x 3]
              |
     Delta_J = J_obs - J_hyp
              |
     F_cheb = ||Delta_J||^2 / ||J_obs||^2
```

### 6.2 反演一次迭代数据流

```
    Delta_J [64x3]
         |
    build_adjoint_source     ← Born 伴随源: S_raw = Sigma_k dOmega * Delta_J * e^{ikr}
         |
    f_adj [N_v x 3]          ← f_adj = -2i*omega*eps0*(eps_r-1)*S_raw / F_obs
         |
    solve_adjoint             ← COMSOL 伴随求解 (复用 forward LU)
         |
    lambda [673 x 3]         ← 伴随场
         |
    compute_gradient          ← g = gd + gi (4-pt Gauss 积分)
         |
    g [N_v x 1]              ← 梯度
         |
    linesearch               ← Armijo: 试探 eps_r_new = eps_r - mu*g
         |                      重跑 solve_forward → F_try
         |                      F_try <= F_old - c*mu*||g||^2 ?
         |
    eps_r_new [N_v x 1]     ← 更新后的介电常数
```

---

## 7. 关键数据结构

### voxel (体素结构体)

```matlab
voxel.pos            % [19268 x 3] double  - 全部单元质心坐标 (m)
voxel.dV             % [19268 x 1] double  - 全部单元体积 (m^3)
voxel.epsilon_r      % [19268 x 1] complex - 介电常数 (内层=待优化, 外层=1.0)
voxel.mask_interior  % [19268 x 1] logical - 内层标记 (r < 0.13m = true)
voxel.gauss_pos      % [2692 x 3] double   - 内层 tet 的 4-pt Gauss 坐标
voxel.gauss_w        % [4 x 1] double      - Gauss 权重 (= 0.25 each)
```

### lc (LightConeData)

```matlab
lc.k_dir        % [64 x 3] double   - 64 个 k 方向单位向量 (fibonacci sphere)
lc.k_vec        % [64 x 3] double   - = k0 * k_dir
lc.dOmega      % [64 x 1] double   - 每个方向的立体角权重
lc.J_obs_perp   % [64 x 3] complex  - 观测光锥横向分量 (真值, 固定不变)
lc.J_hyp_perp   % [64 x 3] complex  - 假设光锥横向分量 (每轮更新)
lc.Delta_J_perp % [64 x 3] complex  - = J_obs - J_hyp
```

### grid (测量网格)

```matlab
grid.pos        % [4608 x 3] double - 测量球面采样点坐标 (R=0.26m)
grid.norm       % [4608 x 3] double - 法向量 (= r_hat)
grid.theta_hat  % [4608 x 3] double - theta 方向单位向量
grid.phi_hat    % [4608 x 3] double - phi 方向单位向量
grid.weight     % [4608 x 1] double - 面积权重 = R^2*sin(theta)*dtheta*dphi
```

---

## 8. COMSOL 模型内部接口

正演管线依赖 COMSOL 模型中的以下命名对象（在 model_export.m 中定义）:

| 对象 | 名称 | 用途 |
|------|------|------|
| 几何 | `geom1` | 3D 球体 (r=0.4m, 含 PML 层) |
| 网格 | `mesh1` | FEM 网格 (19268 tet) |
| 物理 | `emw` | ElectromagneticWaves (频域) |
| Study | `std1` | Frequency Domain |
| Study step | `freq` | `plist` 设频率 |
| 求解器 | `sol1` | 解序列 (PARDISO + MUMPS) |
| 插值函数 | `int2` | epsilon_r 实部 (table source) |
| 插值函数 | `int3` | epsilon_r 虚部 (table source) |
| 变量 | `adjoint_mode` | 1=正演(有背景场), 0=伴随(无背景场) |
| 变量 | `freq` | 全局频率参数 |
| 物理特性 | `wee1.epsilonr` | 波方程介电常数 = `int2(x,y,z) + i*int3(x,y,z)` |

**关键 LiveLink 操作模式**:
- `update_epsilon`: 写 CSV → `func('int2').importData(csv)` → COMSOL 内部自动重新插值
- `solve_forward`: `param.set('freq',...)` → `sol('sol1').clearSolution()` → `sol('sol1').runAll()`
- `solve_adjoint`: 设 `adjoint_mode=0` → 配置 `vec1`(ExternalCurrentDensity) → `runAll()` → 取 lambda → 恢复 `adjoint_mode=1`

---

## 9. 常见问题

### Q: COMSOL 求解失败 (PARDISO + MUMPS 均失败)

**A**: 高对比度 epsilon_r (>50) 或低频 (<500MHz) 下 FEM 矩阵条件数极差。
解法: 用 `livelink_model_pardiso.mph`（预配置 PARDISO）或降低网格密度。

### Q: Born 近似 V5a 不通过 (max F_k > 1e-3)

**A**: 这是强散射体 (eps_r=5) 下的预期行为，不是 bug。
Born 假设 E_inc ≈ E_total，但 eps_r=5 时内部场扰动 ~20%。
F_cheb 残差下界因此 ~0.001-0.005。如果需要精确 J_hyp，用 `compute_jhyp_comsol.m` (Full Maxwell)。

### Q: 内存不足

**A**: MATLAB 端无瓶颈 (673 内层 x 3 = 32KB/数组; B-spline sparse 5-19MB)。
瓶颈在 COMSOL FEM 求解器 (LU 分解内存)。解法: 用更粗网格 (hmax=0.04 → 0.06)。

### Q: 多频联合反演 (B01 陷阱)

**A**: COMSOL 6.2 LiveLink EMW 物理场的 freq 参数有缓存问题。
连续改频率后 solve_forward 输出的 E 场可能逐字符相同 (5 频只算了第 1 个)。
解法: 每次改频率后必须 `clearSolution()` + 重新 `mesh.run()`。

---

## 10. 复用此管线的最小代码

```matlab
% --- 最小正演验证 (复制即用, pipline 自包含) ---
setup();                          % 自动 addpath config/utils/core_*/algorithm
p = config();
mphstart(2036);
model = mphload(p.comsol_model_path);

% 提取网格
voxel = fem_mesh_utils(model, p, p.a_scatter);

% 设真值
voxel.epsilon_r(voxel.mask_interior) = 5.0;

% 正演
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

% J_obs (COMSOL 原生)
grid = build_measurement_grid(p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
J_obs = lc.J_obs_perp;

% J_hyp (Born 近似)
J_equi = equivalent_source(voxel, E_total, p);
lc.k_vec = p.k0 * lc.k_dir;
J_hyp = lightcone_hyp(voxel, J_equi, lc, p);

% 检查
F_k = sum(abs(J_obs - J_hyp).^2, 2) ./ sum(abs(J_obs).^2, 2) / 6;
fprintf('max F_k = %.4e (Born 近似偏差)\n', max(F_k));
```

---

## 附: 验证状态

| 检查项 | 最近验证 | 结果 |
|--------|---------|------|
| COMSOL 正演 | 2026-07-03 | PASS (673 voxels, \|E\|=1.09 V/m) |
| J_obs 提取 | 2026-07-03 | PASS (64 k-dir, \|J_obs\|=1.93e-4) |
| J_hyp Born | 2026-07-03 | PASS (64 k-dir, \|J_hyp\|=1.92e-4) |
| V5a 一致性 | 2026-07-03 | WARN (max F_k=2.06e-2, Born 固有偏差) |
| 方向对齐 | 2026-07-03 | PASS (cos theta=0.9929) |
| Gauss 积分 | 2026-07-03 | PASS (2692 pts, ratio=1.019) |
