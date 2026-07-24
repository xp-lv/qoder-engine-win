# COMSOL 正演管线指南

## 目的

本文档为 PhantomConstrainedInverseScattering APP 提供 COMSOL Multiphysics 6.2 频域电磁正演求解的操作指南，涵盖 LiveLink for MATLAB 配置、int2/int3 插值函数写入 ε_r、mphinterp 提取散射场、PARDISO/MUMPS 求解器配置、伴随场求解。为正演数据生成者（R2）和反演执行者（R3/R4）提供工具操作支撑。

## 适用角色

- 正演数据生成者（R2）— 正演求解与 J_obs 生成
- 基线反演执行者（R3）— 每步迭代的正演与伴随求解
- 约束反演执行者（R4）— 同 R3

---

## 1. LiveLink for MATLAB 配置

### 1.1 连接建立

```matlab
% 启动 COMSOL LiveLink（端口 2036）
import com.comsol.model.*
import com.comsol.model.util.*
model = ModelUtil.create('Model');
mphstart(2036);  % 连接到已在运行的 COMSOL Server
```

### 1.2 模型初始化与重置

- 加载预构建的 COMSOL 模型文件（.mph），包含几何、网格、物理场设置
- 每次迭代前重置研究状态：`model.study('std1').feature('freq').set('plist', freq_list)`
- **关键陷阱**：COMSOL 频率缓存有 4 层嵌套 API 陷阱，必须使用 `study.feature('freq').set('plist', ...)` 而非其他方法

### 1.3 连接检查

使用 MCP 工具 `check_comsol` 验证：
- LiveLink 端口 2036 连接状态
- COMSOL 6.2 许可证有效性
- 可用内存 ≥ 32GB
- 若连接断开，执行重连流程

---

## 2. int2/int3 插值函数：写入 ε_r

### 2.1 插值函数概述

COMSOL 通过插值函数将外部数据（ε_r 分布）写入模型：
- `int2(x,y,z)`：ε_r 的实部（介电常数实部）
- `int3(x,y,z)`：ε_r 的虚部（介电常数虚部，损耗）

### 2.2 写入流程

1. 将 ε_r 分布导出为 CSV 表格（x, y, z, value 格式）
2. 通过 COMSOL API 创建/更新插值函数：
   ```matlab
   model.func().create('int2', 'Interpolation');
   model.func('int2').set('table', csv_data_real);
   model.func('int2').set('argname', {'x', 'y', 'z'});
   % 同理创建 int3（虚部）
   ```

### 2.3 B-spline 控制点 → COMSOL 网格映射

- B-spline 控制点 c ∈ ℂ^500（10×10×5）
- 通过 B_op (19268×500 稀疏矩阵) 插值到 19268 体素空间
- 体素空间 ε_r → CSV 表格 → int2/int3 插值函数
- B_op 为立方 B-spline 插值，每行约 64 个非零元素，行归一化保证 PoU（分区统一性）

### 2.4 关键设置

```matlab
% 必须设置 epsilonr_mat 为 'userdef'，否则 COMSOL 忽略 int2/int3
model.component('comp1').physics('emw').feature('wEE1').set('epsilonr_mat', 'userdef');
model.component('comp1').physics('emw').feature('wEE1').set('epsilonr', 'int2(x,y,z) + i*int3(x,y,z)');
```

> **关键**：若 `epsilonr_mat` 未设置为 `'userdef'`，COMSOL 会从材料节点读取默认值，忽略 int2/int3 插值函数。

### 2.5 ε_r 更新的 4 级回退策略

COMSOL ε_r 更新可能因版本/配置差异而失败，采用 4 级回退：

| 级别 | 策略 | 说明 |
|------|------|------|
| Level 1 | 扫描所有 EMW 特征中包含 'int2' 的属性 | 通用搜索 |
| Level 2 | 直接覆盖 wee1.epsilonr = int2(x,y,z) + i*int3(x,y,z) | 精确指定 |
| Level 3 | 材料节点属性修改 | 通过材料设置 |
| Level 4 | 暴力遍历所有已知特征名 | 兜底方案 |

---

## 3. 频域求解设置

### 3.1 背景场

- 平面波背景场（`bg_planewave`）：指定入射方向、极化、幅度
- 高斯束背景场（`bg_gaussian`）：指定束腰、方向
- 通过 `bg_setup(model, bg, p)` 写入 COMSOL

### 3.2 PML 吸收边界

完美匹配层（PML）包裹仿真域外层，吸收外向散射波，模拟开放空间。

### 3.3 频域散射场公式

COMSOL 频域电磁波（EW）模块，散射场公式：
- 总场 E_total = E_background + E_scattered
- 求解 E_scattered 满足频域 Maxwell 方程

### 3.4 频率扫描

- 频率列表：[0.8 GHz, 1.0 GHz]
- 设置方法（避免嵌套 API 陷阱）：
  ```matlab
  model.study('std1').feature('freq').set('plist', '0.8e9 1.0e9');
  ```

---

## 4. 求解器选择

### 4.1 PARDISO 直接求解器（默认）

- 优势：精确求解，无需迭代收敛判断
- 内存需求：高（≥32GB）
- 适用：19268 体素的中等规模问题

### 4.2 MUMPS 求解器（备选）

- 优势：内存效率略优于 PARDISO
- 劣势：部分场景数值稳定性略差

### 4.3 内存预算

| 组件 | 内存需求 |
|------|----------|
| FEM 网格 | ~4 GB |
| 正演场存储 | ~8 GB |
| 伴随场存储 | ~8 GB |
| LU 分解因子 | ~12 GB |
| **总计** | **≥ 32 GB** |

---

## 5. mphinterp 散射场提取

### 5.1 在测量球面提取场

```matlab
% 在测量球面（R=0.26m）上定义评估点
eval_pos = fibonacci_sphere(64, 0.26);  % 64 个 Fibonacci 方向 × R=0.26m

% 提取散射电场 E^s
E_s = mphinterp(model, 'emw.relEx', 'emw.relEy', 'emw.relEz', ...
                'dataset', 'dset1', 'selection', eval_pos);

% 提取散射磁场 H^s
H_s = mphinterp(model, 'emw.relHx', 'emw.relHy', 'emw.relHz', ...
                'dataset', 'dset1', 'selection', eval_pos);
```

### 5.2 体素中心提取总场（反演用）

```matlab
% 在体素中心提取总场 E_total（用于 J_equi 计算）
E_total = mphinterp(model, 'emw.Ex', 'emw.Ey', 'emw.Ez', ...
                    'dataset', 'dset1', 'selection', voxel.pos);
```

---

## 6. J_obs 计算流程

完整的 J_obs 计算管线：
1. COMSOL 频域正演 → E^s, H^s（测量球面上）
2. 表面等效定理积分 → J(k̂) [64×3 复数]
3. 横向投影 → J_obs_perp [64×3]
4. 对每个频率重复 → 合计 [64×3×2] = 384 复观测值

---

## 7. COMSOL 超时与容错

### 7.1 单次求解超时

- 单次 COMSOL 求解超时设置：30 分钟
- 超时自动终止并报错，触发重试或检查点恢复

### 7.2 检查点保存

- 每次迭代步保存 ε_r 快照（.mat 文件）
- 记录迭代步号 + ε_r 状态
- COMSOL 崩溃后从最近检查点恢复续算

### 7.3 续算策略

```matlab
% 从检查点加载
load('checkpoint_iter_N.mat', 'epsilon_r', 'iter_count');
% 从第 N+1 步继续迭代
```

---

## 8. 伴随场求解

### 8.1 伴随求解模式设置

1. 通过 6 个插值函数将伴随源 f_adj 的实虚部写入 COMSOL：
   - int4, int5, int6 → f_adj_x 的实部、虚部、辅助
   - int7, int8, int9 → f_adj_y, f_adj_z 的分量
2. 创建 `External_current_density` (vec1) 加载伴随源
3. 禁用散射场背景 (sctr1) — 伴随问题无背景场

### 8.2 伴随求解

```matlab
% 复用正演的 LU 分解因子（节省计算时间）
model.study('std1').run();  % 伴随场求解
lambda = mphinterp(model, 'emw.Ex', ..., 'selection', voxel.pos);
```

### 8.3 模型状态恢复

伴随求解后恢复模型到正演状态（重新启用 sctr1，移除 vec1），为下一步迭代做准备。

---

## 9. 调用时序规范

R2/R3/R4 的标准 COMSOL 调用时序：

```
check_comsol()                    → 确认连接
↓
update_epsilon(model, ε_r)        → int2/int3 写入
↓
run_experiment(model)             → COMSOL 正演求解
↓
read_field(model, eval_pos)       → mphinterp 提取 E_total
↓
[计算 J_equi, J_hyp, ΔJ, 梯度]
↓
solve_adjoint(model, f_adj)       → COMSOL 伴随求解
↓
read_field(model, voxel.pos)      → 提取伴随场 λ
```

### 并发限制

同一时间仅允许一个 COMSOL 求解（LiveLink 单连接）。R3 和 R4 并行执行时，COMSOL 调用必须串行化（通过互斥锁或队列调度）。

---

## 检查清单

- [ ] LiveLink 端口 2036 连接正常？
- [ ] epsilonr_mat 设置为 'userdef'？
- [ ] 频率通过 study.feature('freq').set('plist', ...) 设置？
- [ ] 可用内存 ≥ 32GB？
- [ ] 单次求解超时 30 分钟？
- [ ] 每步迭代保存检查点？
- [ ] R3/R4 并行时 COMSOL 调用已串行化？
