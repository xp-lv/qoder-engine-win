# pipline4 极简近场伴随法诊断管线 (Near-field Adjoint Diagnostic)

> **目标**：在最小模型上验证复数 ε_r 伴随梯度的数学正确性，隔离 COMSOL 求解与梯度组装两层，定位管线3的问题根源。

---

## 1. 这是什么

管线3的伴随法验证失败了。管线3有四层耦合（远场光锥 → Born反投影 → COMSOL双源伴随 → 复数梯度组装），任何一层出错都会导致 sign/ratio 异常，但无法隔离。

管线4通过**砍掉前两层**（远场映射 + Born反投影），将问题缩小到：
- **L3**: COMSOL 伴随求解（mphmatrix + LU 回代）
- **L4**: 复数梯度组装（bilinear/hermitian 内积）

如果这两层在单体素尺度下验证通过，问题就在管线3被砍掉的那两层。

```
管线3: E_truth → [L1:光锥] → [L2:Born反投影] → [L3:COMSOL伴随] → [L4:复数梯度] → g
                                                    ↑ 可能出错         ↑ 可能出错
管线4: E_truth → [近场探针] → [L2:L2残差伴随源] → [L3:COMSOL伴随] → [L4:复数梯度] → g
                                       解析可推导       ↑ 隔离          ↑ 隔离
```

---

## 2. 核心简化

| 管线3 | 管线4 | 简化效果 |
|-------|-------|---------|
| Stratton-Chu 光锥投影 (64行) | **删除** | 无远场映射干扰 |
| Born FT 反投影 P† (74行) | L2 残差直接伴随源 (53行) | 解析可推导，无共轭相位 |
| 双源路径 solve_adjoint (415行) | 极简体积路径 (185行) | 无 SurfaceCurrent/MagneticCurrent |
| compute_cost 光锥归一化 (25行) | 标量 L2 (27行) | F = Σ\|E-E*\|²/Σ\|E*\|² |
| compute_gradient 多体素 (182行) | 单体素 (73行) | 无空间循环，无 Gauss |
| **总计核心 ~800行** | **~350行** | **减少 56%** |

---

## 3. 数学公式

### 代价函数

```
F(ε_r) = Σ_p w_p |E(r_p; ε_r) - E*(r_p)|²  /  Σ_p w_p |E*(r_p)|²
```

### 伴随源（Wirtinger 导数）

```
∂F/∂E(r_p) = 2·conj(E(r_p) - E*(r_p)) / F_norm

COMSOL 注入: Je = 2·conj(r_p) / (iωμ₀·F_norm)  （探针点处）
```

### 复数梯度（bilinear 内积，COMSOL 复对称 K）

```
dF/dε'  = +2·k₀²·Re(∫_Ω E·λ dV)
dF/dε'' = -2·k₀²·Im(∫_Ω E·λ dV)
```

因子 2 来自 Wirtinger 微积分: dF = -2·Re(λᵀ·dK·u)

---

## 4. 运行方式

### 前提条件

- COMSOL mphserver 运行在 port 2036
- 管线3的 `2layer.mph` 模型文件存在

### 启动 COMSOL mphserver

```powershell
& "D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe" -port 2036
```

### 运行主验证

```powershell
cd "d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline4"
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "setup(); verify_fd_complex();"
```

### 运行 λ 残差诊断（当 sign 失败时）

```powershell
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "setup(); verify_lambda_residual();"
```

---

## 5. 验证标准

| 指标 | 通过标准 | 意义 |
|------|---------|------|
| ε' sign 一致率 | 100% | 实部梯度方向正确 |
| ε'' sign 一致率 | 100% | 虚部梯度方向正确 |
| ε' ratio | \|ratio-1\| < 0.15 | 实部梯度幅度正确 |
| ε'' ratio | \|ratio-1\| < 0.15 | 虚部梯度幅度正确 |
| K·λ 残差 | < 1e-8 | COMSOL 求解精确 |

### 预期结果

单体素尺度下，FD 是数学精确的（无多体素叠加离散化误差），**ratio 应接近 1.0**。

如果 ratio ≈ 1.0 且 sign 全对 → 伴随法数学正确，管线3的问题在远场映射层。

---

## 6. 故障隔离决策树

```
verify_fd_complex 结果:
│
├─ sign 全对, ratio ≈ 1.0
│   → ★ 伴随法正确！管线3问题在 L1/L2 远场层
│
├─ sign 全对, ratio ≠ 1.0
│   → 系数标定问题
│   → 检查 build_adjoint_source_nearfield 的 coeff 因子
│
├─ ε' sign 对, ε'' sign 错
│   → bilinear/hermitian 内积约定 bug
│   → 切换 config.m 中 gradient_dot: 'bilinear' ↔ 'hermitian'
│
├─ 两个 sign 都错
│   → 运行 verify_lambda_residual
│   ├─ K·λ 残差大 → COMSOL 求解错
│   │   → 检查 mphmatrix symmetry 设置
│   │   → 检查插值函数写入
│   └─ K·λ 残差小 → 梯度组装错
│       → 检查 compute_gradient 的内积约定
│       → 检查 ∫E·λ dV 积分方式
```

---

## 7. 目录结构

```
pipline4/
├── README.md                          ← 本文件
├── setup.m                            ← 路径初始化
│
├── config/
│   └── config.m                       ← 极简配置（探针/ε_r/FD参数）
│
├── utils/
│   ├── fem_mesh_utils.m               ← COMSOL 网格提取（复用管线3）
│   └── build_probes.m                 ← 探针点生成 [新]
│
├── core_forward/                      ← COMSOL 正演/伴随层
│   ├── solve_forward.m                ← 正演求解（复用管线3）
│   ├── solve_adjoint.m                ← 极简伴随求解 [新, 185行]
│   ├── read_field.m                   ← 场值提取（复用管线3）
│   └── update_epsilon.m               ← ε_r 更新（复用管线3）
│
├── core_probe/                        ← 近场伴随源层 [新]
│   └── build_adjoint_source_nearfield.m ← L2 残差伴随源 [新, 53行]
│
├── core_adjoint/                      ← 梯度与代价层
│   ├── compute_cost.m                 ← 标量 L2 代价 [新, 27行]
│   └── compute_gradient.m             ← 单体素复数梯度 [新, 73行]
│
├── experiment/                        ← 验证脚本
│   ├── verify_fd_complex.m            ← ★ 主验证：FD sign+ratio [新]
│   └── verify_lambda_residual.m       ← K·λ 残差诊断 [新]
│
└── data/
    └── results/                       ← 结果输出
```

---

## 8. 与管线3的迁移路径

管线4验证通过后，逐步恢复管线3的复杂度：

1. **方案 A 通过**（单体素 sign+ratio 正确）→ COMSOL求解+梯度组装确认正确
2. **方案 B**：扩展到多体素，验证空间梯度方向（仍用近场探针）
3. **方案 C**：恢复远场测量（先单方向 k̂，再完整光锥），定位 L1/L2 是否出错

每步都用 FD 验证监控，一旦 sign/ratio 异常就能精确定位到刚加入的那层。
