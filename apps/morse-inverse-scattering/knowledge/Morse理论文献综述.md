# Morse 理论文献综述

> 本文档是 morse-inverse-scattering App 的文献基座文档，为文献调研者提供 Morse 理论在逆散射与拓扑数据分析领域的已有工作索引、关键引文清单与研究空白地图。

---

## 一、目的

本文档解决以下问题：
- Morse 理论在拓扑数据分析（TDA）中有哪些经典工作与应用？
- Morse 理论在逆问题/逆散射中有哪些已有研究？
- 当前研究空白在哪里——哪些关键理论证明尚缺？

---

## 二、适用角色

| 角色 | 使用方式 |
|------|----------|
| 文献调研者 | 系统性文献综述的引文基座与研究空白地图（主要执行依据） |

---

## 三、核心内容

### 3.1 经典 Morse 理论

**奠基性工作：**
- **Milnor, J.** *Morse Theory* (Princeton University Press, 1963) —— Morse 理论的标准教科书，定义光滑流形上 Morse 函数的临界点与拓扑的关系。
- **Milnor, J.** *Lectures on the h-cobordism Theorem* (Princeton, 1965) —— Morse 理论在微分拓扑中的应用。
- **Bott, R.** "Morse Theory Indomitable" (*Publications Mathématiques de l'IHÉS*, 1988) —— Morse 理论的历史回顾与现代发展综述。

**核心定理：**
- Morse 引理：临界点附近 Morse 函数可表示为标准二次型。
- Morse 不等式：临界点数与 Betti 数的拓扑约束关系。
- Morse-Smale 复形：稳定/不稳定流形的横截相交条件。

### 3.2 离散 Morse 理论

- **Forman, R.** "Morse Theory for Cell Complexes" (*Advances in Mathematics*, 1998) —— 将 Morse 理论推广到离散组合结构。
- **Forman, R.** "A User's Guide to Discrete Morse Theory" (*Sém. Lothar. Combin.*, 2002) —— 离散 Morse 理论的实践指南。

**意义：** 离散 Morse 理论为数值化的 ε_r 网格数据上的拓扑分析提供了直接工具，是连续 Morse 理论在数值实现中的理论桥梁。

### 3.3 Morse 理论在拓扑数据分析（TDA）中的应用

- **Carlsson, G.** "Topology and Data" (*Bull. Amer. Math. Soc.*, 2009) —— TDA 综述，Morse 理论作为持续同调的理论基础。
- **Edelsbrunner, H., Harer, J.** *Computational Topology: An Introduction* (AMS, 2010) —— 计算拓扑教科书，涵盖 Morse-Smale 复形的算法实现。
- **Gunther, D., et al.** "Efficient Computation of Persistent Homology of Cubical Data" (*Topology-based Methods in Visualization*, 2012) —— 网格数据上 Morse 理论的算法实现。

### 3.4 Morse 理论在逆问题中的应用

**已有工作（有限但存在）：**
- **Haber, E., Oldenburg, D.** "Aspects of uncertainty estimation in geophysical inverse problems" (*Inverse Problems*, 1998) —— 逆问题的适定性分析框架（非 Morse 专用，但提供数学工具）。
- **Borcea, L., et al.** "Inverse scattering in a discrete setting" (*SIAM J. Sci. Comput.*, 2007) —— 离散逆散射，与离散 Morse 理论有交叉潜力。
- **Kress, R.** *Linear Integral Equations* (Springer, 2014) —— 积分方程理论，Lippmann-Schwinger 方程的数学基础。

### 3.5 逆散射不适定性分析

- **Colton, D., Kress, R.** *Inverse Acoustic and Electromagnetic Scattering Theory* (Springer, 2013) —— 逆散射适定性理论的标准参考。
- **Isakov, V.** *Inverse Problems for Partial Differential Equations* (Springer, 2017) —— PDE 逆问题的适定性判据。

### 3.6 研究空白地图

| 空白领域 | 现状 | 预期贡献 |
|----------|------|----------|
| Morse 降阶反演适定性证明 | 无直接证明——参数空间降维后 Hadamard 三条件的满足性从未被系统证明 | 提供降阶反问题适定性的严格数学证明 |
| 临界点拓扑与逆散射耦合 | Morse 理论在 TDA 中成熟，在逆散射中几乎空白 | 建立 ε_r 临界点参数化与逆散射观测的数学桥梁 |
| 临界点参数化完备性 | 未证明临界点参数能否完整表征 ε_r 分布的拓扑信息 | 证明或给出完备性条件 |
| 从临界点到全域场的重建理论 | RBF 插值在工程中广泛使用，但重建映射的存在性/稳定性缺乏理论分析 | 论证重建映射的数学可行性与误差界 |

---

## 四、关键引文清单

| 编号 | 作者 | 年份 | 标题 | 核心贡献 |
|------|------|------|------|----------|
| [M1] | Milnor | 1963 | Morse Theory | Morse 理论标准教材 |
| [F1] | Forman | 1998 | Morse Theory for Cell Complexes | 离散 Morse 理论 |
| [C1] | Carlsson | 2009 | Topology and Data | TDA 综述 |
| [EH1] | Edelsbrunner, Harer | 2010 | Computational Topology | 计算拓扑教材 |
| [CK1] | Colton, Kress | 2013 | Inverse Acoustic and EM Scattering Theory | 逆散射适定性 |
| [I1] | Isakov | 2017 | Inverse Problems for PDEs | PDE 逆问题适定性 |
| [HO1] | Haber, Oldenburg | 1998 | Aspects of uncertainty in geophysical inverse problems | 逆问题适定性分析 |
| [B1] | Borcea et al. | 2007 | Inverse scattering in a discrete setting | 离散逆散射 |

---

## 五、检查清单

### 文献调研者自检
- [ ] 是否覆盖经典 Morse 理论（Milnor）与离散 Morse 理论（Forman）？
- [ ] 是否覆盖 TDA 应用（Carlsson, Edelsbrunner）？
- [ ] 是否覆盖逆散射适定性理论（Colton-Kress, Isakov）？
- [ ] 是否识别了研究空白（降阶适定性、临界点完备性等）？
- [ ] 引文清单是否完整可追溯？
