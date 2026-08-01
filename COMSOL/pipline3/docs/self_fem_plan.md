# 不走 COMSOL 的伴随法 FEM 方案

## 核心思路

用 MATLAB 自实现频域矢量 FEM（Nédélec 棱边元），完全控制 K 矩阵的组装、求解和伴随计算。

## 计算量评估

| 组件 | 规模 | 难度 | 说明 |
|------|------|------|------|
| 网格 | 球内四面体 ~5000 单元 | 低 | 可用 COMSOL 导出网格（仅顶点+连接），或用 MATLAB distmesh |
| K 组装 | ~30000×30000 稀疏 | 中 | Nédélec 一阶棱边元的刚度矩阵 |
| K^T 求解 | sparse \ | 低 | MATLAB backslash 直接用 K^T |
| 伴随源 | 体积电流注入 | 低 | 直接加到 RHS 向量 |
| 场提取 | DOF → 体素中心 | 低 | Nédélec 形函数插值 |

**计算不困难**——核心就是一个 FEM 刚度矩阵组装 + sparse solve。

## 架构设计

```
输入: 网格(顶点+四面体连接) + ε_r分布 + 频率 + 背景场源

Step 1: 组装 K = S - k₀²M
  S_ij = ∫(∇×W_i)·μ_r⁻¹·(∇×W_j) dV    （旋度项，对称）
  M_ij = ∫ W_i·ε_r·W_j dV               （质量项，对称）
  → K = K^T 精确对称（无 PML 复坐标变换）

Step 2: 组装 RHS b_fwd（背景场源）
  b_i = -jωμ₀ ∫ W_i·J_background dV

Step 3: 正演 E = K \ b_fwd
  K 是稀疏复对称，MATLAB \ 自动选 LU

Step 4: 伴随 RHS b_adj（体积等效源）
  b_adj = f_adj（直接构造，无 ExternalCurrentDensity API）

Step 5: 伴随求解 λ = K^T \ b_adj = K \ b_adj（K=K^T!）
  ★ 这就是不用 COMSOL 的核心优势：K 对称 → K^T = K → 伴随=正演

Step 6: 梯度
  g_direct = +2ωε₀·dV·Im[E*S]/F_obs
  g_indirect = -k₀²·dV·Re[λ*·E]
  ★ Hermitian 内积，不需要 conj(λ)

Step 7: 吸收边界
  用 PEC + 大空气域，或 Silver-Müller 辐射条件的简单一阶近似
  边界项加到 K 中，仍保持对称
```

## Nédélec 棱边元的关键公式

一阶四面体棱边元，6 条棱 → 6 个 DOF per tet：

```
棱编号: e_k = (node_i, node_j), k=1..6
形函数: W_k = λ_i ∇λ_j - λ_j ∇λ_i  （λ = 重心坐标）

旋度: ∇×W_k = 2 ∇λ_i × ∇λ_j
```

单元刚度矩阵（3×3 旋度积分 + 质量矩阵）：

```
S_ij^e = ∫_e (∇×W_i)·(∇×W_j) dV = (2∇λ_a × ∇λ_b)·(2∇λ_c × ∇λ_d) × V_e
M_ij^e = ∫_e W_i·W_j dV ≈ V_e/20 · (f_i·f_j + g/gross terms)
```

（一阶 Nédélec 元的质量矩阵有解析公式，精度足够。）

## 实现规模估算

```matlab
% 伪代码
N_tet = 5000;          % 四面体数
N_edge = ~15000;       % 棱数 ≈ DOF 数
K = sparse(N_edge, N_edge);  % 稀疏矩阵

% 组装（~0.5s）
for e = 1:N_tet
    [Ke, Me] = nedelec_tet_stiffness(nodes, conn(e,:), eps_r(e));
    K(edge_dofs, edge_dofs) += Ke - k0^2 * Me;
end

% 正演（~0.5s）
E = K \ b_fwd;

% 伴随（~0.5s，复用 LU）
lambda = K \ b_adj;  % K^T = K!

% 梯度（~0.01s）
g = compute_gradient(E, lambda, S_field, voxel);
```

**总计算时间 ~2s/次正演+伴随**（比 COMSOL runAll 的 ~3s 更快，因为无 API 开销）。

## 网格来源（两个方案）

### 方案 A：从 COMSOL 导出网格（推荐）
```matlab
mesh = model.mesh('mesh1');
verts = mesh.getVertex()';        % [N_vert × 3]
tet_conn = mesh.getElem('tet')'+1; % [N_tet × 4]
save('mesh_data.mat', 'verts', 'tet_conn');
% 之后不再需要 COMSOL
```

### 方案 B：用 MATLAB distmesh 生成
```matlab
% distmesh 是开源的 3D 网格生成工具
[p, t] = distmesh3d(fd, fh, h0, box, ...);
% fd = 距离函数（球内）
% 然后自己提取棱编号
```

## 吸收边界方案

不用 PML，用 **Silver-Müller 一阶辐射条件**的外边界：

```
n̂ × (∇×E) ≈ jk₀ (n̂ × E) × n̂    （边界积分项）
```

加到 K 的边界项中：
```
K_boundary_ij = jk₀ ∫_∂V (n̂×W_i)·(n̂×W_j) dS
```

这个边界项是对称的（$K_{ij}^{bd} = K_{ji}^{bd}$），**不破坏 K=K^T**。

吸收效果比 PML 差，但增大空气层（R_air=0.2m，离散射体 3λ/5）可以补偿。

## 与当前 COMSOL 管线的对比

| | COMSOL 管线（当前） | 自实现 FEM |
|---|---|---|
| K 对称性 | ❌ PML:4.4, SBC:0.31 | ✅ 精确对称 |
| 伴随求解 | K\b（不精确） | K^T\b = K\b（精确） |
| conj(λ) | 需要（bilinear 桥接） | **不需要**（Hermitian 统一） |
| 量纲 | ❌ mphmatrix 不自洽 | ✅ 完全自洽 |
| API 限制 | ❌ setU/mphinterp 失败 | ✅ 无限制 |
| ratio | ≈4.3（需标定） | **应趋于 1** |
| 速度 | ~3s/次 | ~2s/次 |
| 实现难度 | 已完成 | 需 ~500 行 MATLAB |

## 实现计划

1. **Phase 1**：从 COMSOL 导出网格数据（一次性）
2. **Phase 2**：实现 Nédélec 棱边元 K 组装（~200 行）
3. **Phase 3**：实现正演 + 伴随 + 梯度（~200 行）
4. **Phase 4**：FD 验证 ratio→1（~100 行）

总计 ~500 行 MATLAB 代码，预计 2-3 天实现。
