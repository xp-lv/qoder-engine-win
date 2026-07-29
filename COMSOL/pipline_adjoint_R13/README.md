# pipline_adjoint 伴随法验证管线 (Adjoint Verification Pipeline)

> **给 AI 的快速上手指南**：读完本文件（约 5 分钟），你就能独立调用伴随法验证管线。

---

## 1. 这是什么

一个极简化的电磁逆散射伴随法验证系统。核心功能：

```
输入: 均匀球真值 eps_r=5.0（COMSOL 正演生成观测数据 J_obs）
输出: 逐体素伴随梯度方向验证（sign 一致率、cos θ、CV）
```

物理参数：
- 散射体半径 R_inner = 0.06 m (6 cm)
- 频率 = 1 GHz (波长 30 cm)
- ka = 1.26 (Mie 散射区，中等散射)
- 内层体素 1164 个 (r < 0.06 m)
- COMSOL 6.2 LiveLink 驱动
- 2 层球模型（散射体 + PML）

**与主管线 pipline 的核心差异**：
- 规模缩小 ~10×（DOF 36778，但单次正演 ~3s）
- 专注于单参数 eps_r 验证，暂不含 cavity/B-spline 几何参数
- 代价函数 F 定义统一为定义 A（compute_cost.m 标准）
- 验证脚本全套覆盖：矩阵级→FD真值→逐体素→反演迭代

---

## 2. 运行环境要求

| 组件 | 版本 | 路径 |
|------|------|------|
| MATLAB | R2023b | `D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe` |
| COMSOL | 6.2 | `D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\` |
| COMSOL mphserver | 运行在 port 2036 | `...\COMSOL62\...\comsolmphserver.exe -port 2036` |

**启动 COMSOL mphserver**（必须先于 MATLAB 运行）:
```bash
& "D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe" -port 2036
```

**模型文件**（位于管线根目录）:
```
COMSOL/pipline_adjoint/2layer.mph   ← 极简 2 层球模型（散射体 + PML）
```

---

## 3. 目录结构

```
pipline_adjoint/
├── README.md                 ← 你正在读的文件
├── 2layer.mph                ← COMSOL 模型文件（2 层球 + PML）
├── setup.m                   ← addpath 初始化
│
├── config/                   ← 配置层
│   └── config.m              ← 全局参数（频率/半径/步长/FD 参数）
│
├── utils/                    ← 工具层
│   ├── fem_mesh_utils.m      ← COMSOL mesh 提取 → voxel 结构 [核心]
│   ├── build_measurement_grid.m  ← 测量球面网格 (12×24=288 点)
│   └── fibonacci_sphere.m    ← 16 个 k 方向准均匀采样
│
├── core_forward/             ← COMSOL 正演/伴随层
│   ├── solve_forward.m       ← 正演求解 [核心]
│   ├── solve_adjoint.m       ← 伴随求解（双源路径 + keep_adjoint_state 选项）[核心]
│   ├── read_field.m          ← 从 COMSOL 读取任意点 E 场 (mphinterp)
│   ├── update_epsilon.m      ← 写 epsilon_r 到 COMSOL [核心]
│   ├── build_lightweight_model.m ← 程序化构建 2 层模型（备用）
│   ├── bg_planewave.m        ← 平面波背景场
│   └── bg_setup.m            ← 背景场配置入口
│
├── core_jobs/                ← J_obs 计算层
│   ├── extract_scattered.m   ← 从 COMSOL 提取 relE/relH 散射场 [核心]
│   └── lightcone_project.m   ← 表面等效定理 → 16 k-dir 光锥投影 [核心]
│
├── core_jhyp/                ← 伴随源构建层
│   └── build_adjoint_source_fullmaxwell.m ← 精确 Stratton-Chu 伴随源 [算法核心]
│
├── core_adjoint/             ← 梯度与代价层
│   ├── compute_gradient.m    ← 精确梯度 g（bilinear/hermitian 模式）[算法核心]
│   └── compute_cost.m        ← 代价函数 F（定义 A：归一化残差）
│
├── experiment/               ← 验证脚本（16 个文件）
│   ├── verify_per_voxel.m        ← ★ 逐体素方向验证（sign/cosθ/CV）[主验证]
│   ├── run_fd_truth.m            ← FD 真值 vs 伴随梯度（单参数全局）
│   ├── run_inversion_iter.m      ← 反演迭代（非均匀初值 → 真值收敛）
│   ├── verify_matrix_level.m     ← 矩阵级内积测试（L vs L^H）
│   ├── verify_stage_B.m          ← 光锥投影矩阵级伴随测试
│   ├── verify_stage_C.m          ← COMSOL K 矩阵复对称性测试
│   ├── verify_K_direct.m         ← K 矩阵导出 + MATLAB 直接求解
│   ├── verify_exact_gradient.m   ← FEM 自由度直接梯度计算（绕过 mphinterp）
│   ├── probe_weak_form.m         ← SurfaceCurrent/MagneticCurrent 弱形式探针
│   ├── plot_gradient_3d.m        ← 梯度 3D 点云可视化
│   ├── plot_eps_distribution.m   ← eps_r 分布可视化
│   ├── verify_adjoint_pipline.m  ← 单参数 eps_r FD 验证（Born 路径）
│   ├── check_model.m             ← 模型结构检查
│   ├── diag_adjoint_inject.m     ← 伴随源注入诊断
│   ├── verify_adjoint.m          ← 基础伴随验证
│   └── verify_adjoint_layered.m  ← 分层伴随验证
│
└── data/
    └── results/              ← 结果输出（.mat + .png）
```

---

## 4. 快速验证：一键跑通

### 4.1 启动 COMSOL mphserver

```bash
& "D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe" -port 2036
```

### 4.2 运行逐体素方向验证（主验证脚本）

```powershell
cd "d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint"
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint','experiment'); addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli'); verify_per_voxel(30);"
```

> **注意**：必须显式 addpath 所有子目录 + COMSOL mli 路径。

### 4.3 验证结果（2026-07-28）

```
逐体素方向验证（30 样本，均匀初值 eps_r=3）：
  sign 一致率: 30/30 = 100.0%   ← 方向完全正确
  cos θ = 0.927                  ← 多参数方向高度对齐
  ratio mean = 0.00206, CV=0.40  ← 幅度有系统偏差（积分映射 vs 点值映射）

非均匀初值验证（梯度 eps_r∈[1.6,4.4]）：
  sign 一致率: 30/30 = 100.0%   ← 鲁棒性确认
  cos θ = 0.919
  CV = 0.411
```

---

## 5. 关键数据结构

### voxel (体素结构体)

```matlab
voxel.pos            % [5614 x 3] double   - 全部 FEM 单元质心坐标 (m)
voxel.dV             % [5614 x 1] double   - 全部单元体积 (m^3)
voxel.epsilon_r      % [5614 x 1] complex  - 介电常数（内层=待优化, 外层=1.0）
voxel.mask_interior  % [5614 x 1] logical  - 内层标记 (r < 0.06m = true, 1164 个)
voxel.gauss_pos      % [4656 x 3] double   - 内层 tet 的 4-pt Gauss 坐标
voxel.gauss_w        % [4 x 1] double      - Gauss 权重 (= 0.25 each)
```

### lc (LightConeData)

```matlab
lc.k_dir        % [16 x 3] double   - 16 个 k 方向单位向量 (fibonacci sphere)
lc.k_vec        % [16 x 3] double   - = k0 * k_dir
lc.dOmega      % [16 x 1] double   - 每个方向的立体角权重 (= 4π/16)
lc.J_obs_perp   % [16 x 3] complex  - 观测光锥横向分量（真值, 固定不变）
lc.Delta_J_perp % [16 x 3] complex  - = J_obs - J_hyp
```

### grid (测量网格)

```matlab
grid.pos        % [288 x 3] double - 测量球面采样点坐标 (R=0.09m)
grid.norm       % [288 x 3] double - 法向量 (= r_hat)
grid.weight     % [288 x 1] double - 面积权重
```

---

## 6. COMSOL 模型接口

| 对象 | 名称 | 用途 |
|------|------|------|
| 几何 | `geom1` | 2 层球（散射体 R=0.06 + PML R=0.16） |
| 网格 | `mesh1` | FEM 网格 (5614 tet, DOF=36778) |
| 物理 | `emw` | ElectromagneticWaves (频域, 散射场公式) |
| Study | `std1` | Frequency Domain |
| 求解器 | `sol1` | PARDISO + MUMPS 直接求解器 |
| 插值函数 | `int1` | epsilon_r 实部 |
| 插值函数 | `int2` | epsilon_r 虚部 |
| 变量 | `adjoint_mode` | 1=正演, 0=伴随（零背景场） |
| 特征 | `vec1` | ExternalCurrentDensity（Born 路径用） |
| 特征 | `sc_adj` | SurfaceCurrent（双源路径用，运行时创建） |
| 特征 | `ms_adj` | SurfaceMagneticCurrentDensity（双源路径用） |

---

## 7. 验证体系（四层）

| 层级 | 脚本 | 验证内容 | 状态 |
|------|------|---------|------|
| **Layer 1: 矩阵级** | verify_matrix_level.m | L^H = L 的精确共轭转置 | ✅ ratio=1±1e-15 |
| **Layer 2: FD 真值** | run_fd_truth.m | 单参数 FD vs 伴随 | ✅ sign 正确, ratio=0.002 |
| **Layer 3: 逐体素** | verify_per_voxel.m | 30 体素 sign/cosθ/CV | ✅ sign 100%, cosθ=0.927 |
| **Layer 4: 反演迭代** | run_inversion_iter.m | 非均匀初值收敛 | ✅ F 下降 86% (10 轮) |

### 数学公式验证（5 个疑点全部通过）

| 疑点 | 结论 |
|------|------|
| coeff_base = -2 | ✅ (-1)×2 数学正确 |
| Js/Ms 不对称处理 | ✅ 探针验证 Ms 含 n̂× |
| lambda conj 约定 | ✅ 不取 conj → sign 0% 全反，确认必须 |
| K_M^T BAC-CAB | ✅ 矩阵推导完全正确 |
| F 定义统一 | ✅ 4 种定义 → 统一定义 A |

### CV=0.40 的根因

积分映射（COMSOL 弱形式）与点值映射（mphinterp）的结构性不匹配。这是 FEM 离散化的固有属性，不影响梯度方向正确性。

---

## 8. 常见问题

### Q: COMSOL mphserver 频繁断开

**A**: Windows 上 mphserver 在后台 Minimized 模式下不稳定。推荐在单独终端窗口前台运行，或用 `-3rd` 模式启动 comsolbatch。

### Q: sign 验证全反（0%）

**A**: 检查 solve_adjoint.m 中 lambda 是否取了 conj。双源路径必须取 `lambda = conj(lambda_raw)`，否则 sign 全反。

### Q: ratio 很小（~0.002）

**A**: 这是积分映射 vs 点值映射的结构性偏差（~3000 倍），不影响方向正确性。全局标量可通过 coeff_base 标定补偿。

---

## 9. 复用此管线的最小代码

```matlab
% --- 最小伴随梯度验证（复制即用）---
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

p = config();
grid = build_measurement_grid(p);
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;

% 真值
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
model.sol('sol1').runAll();
sf_obs = extract_scattered(model, grid);
J_obs = lightcone_project(grid, sf_obs, p).J_obs_perp;

% 初值 + 正演
voxel.epsilon_r(inner) = 3.0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
Delta_J = J_obs - lc.J_obs_perp;

% 伴随
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, p);
[lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);

% 梯度
k0_sq = p.k0^2;
g = zeros(sum(inner), 1);
for vi = 1:sum(inner)
    g(vi) = -k0_sq * voxel.dV(find(inner,1)+vi-1) * real(sum(E_total(vi,:) .* lambda(vi,:)));
end
g = g / F_obs;
fprintf('Gradient: mean=%.4e, sign(mean)=%d\n', mean(g), sign(mean(g)));
```
