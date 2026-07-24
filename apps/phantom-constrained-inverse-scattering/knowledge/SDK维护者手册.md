# COMSOL 正演管线 SDK — 维护者实战手册

> **这份文档是给"下一个 SDK 维护者"看的。**
>
> 它**不是** API 参考文档（那是 [SDK运行手册.md](COMSOL正演管线SDK运行手册.md) 的职责），
> 也**不是**使用说明书（那是 app 角色的 skill.md）。
>
> 它记录的是**探索新功能时的方法论 + 历史踩坑案例 + 工具链**——
> 当你需要给 SDK 加一个新能力（比如"支持高斯光束背景场"、"支持各向异性介质"、"加速网格重建"）时，
> 这份文档能让你**少走我们走过的所有弯路**。

---

## 0. 维护者必须先读的三份文档

按顺序读：

1. **[SDK运行手册.md](COMSOL正演管线SDK运行手册.md)** — 当前能力清单 + 接口契约
2. **本文件**（SDK维护者手册.md）— 探索方法论 + 历史案例
3. **[engine/sdk/forward_pipeline/matlab/simple_forward_solve.m](../../../../engine/sdk/forward_pipeline/matlab/simple_forward_solve.m)** — 当前已验证的核心代码

读完后你应该知道：
- SDK 现在能做什么、不能做什么
- COMSOL LiveLink 的 API 风格（与文档的差距）
- 哪些坑已经被填了，哪些还埋着

---

## 1. 探索新功能的标准方法论（核心章节）

### 1.1 黄金法则：先探查 API，再写代码

**永远不要直接写新功能代码。** COMSOL LiveLink 的 API 与官方文档严重不一致，每个属性、每个方法的真实签名都需要实测。

**正确的探索流程**（每加一个新功能必走）：

```
1. 文献/COMSOL GUI 调研 → 知道目标 API 大概长什么样
2. 写 API 探查脚本 → 列出所有可用属性/方法
3. 单点测试 → 在 MATLAB 命令行实测每个候选 API
4. 失败模式收集 → 记录每个错误形式（"未知属性"、"类型不符"等）
5. 找到唯一能 work 的 API → 才开始写功能代码
6. 对比验证 → 用两个明显不同的输入跑，证明功能真的生效
```

### 1.2 探查脚本的三个层次

每一层都是独立的小脚本，**不要在主功能脚本里探查**：

#### 层次 1：模型结构探查（"这个 .mph 里有什么？"）

```matlab
% 模板：探查 .mph 的内部结构
m = mphload('<mph_path>');

fprintf('Physics tags:\n'); disp(m.physics.tags);
fprintf('Study tags:\n');  disp(m.study.tags);
fprintf('Geom tags:\n');   disp(m.geom.tags);
fprintf('Mesh tags:\n');   disp(m.mesh.tags);
fprintf('Sol tags:\n');    disp(m.sol.tags);
fprintf('Func tags:\n');   disp(m.func.tags);

% 注意：java.lang.String[] 不能用 {} 索引，必须用 (i)
% 注意：disp 会打印完整内容，fprintf('%s', tags) 不行
```

**已知陷阱**：
- `m.physics.tags` 返回 `java.lang.String[]`，**不能用 `{}` 索引**，要用 `(i)` + `char()`
- `m.func.tags` 同上
- 想"遍历 tags 找特定名字"时：
  ```matlab
  tags = m.func.tags;
  for i = 1:length(tags)
      if strcmp(tags(i), 'int2')   % 不是 tags{i}
          ...
      end
  end
  ```

#### 层次 2：属性/方法清单探查（"这个对象有哪些属性/方法？"）

```matlab
% 模板：列出某个 model 对象的所有方法
obj = m.physics('emw').feature('wee1');
all_methods = methods(obj);   % 返回 cell array of char
for i = 1:length(all_methods)
    fprintf('%s\n', all_methods{i});
end

% 筛选 set/get/has 开头
for i = 1:length(all_methods)
    mn = all_methods{i};
    if startsWith(mn, 'set') || startsWith(mn, 'get') || startsWith(mn, 'has')
        fprintf('%s\n', mn);
    end
end
```

**已知陷阱**：
- `methods(obj, 'name')` **不能用**——会报"请尝试使用保留关键字 try"
- `methods(obj)` 是唯一可用形式
- `propnames` **不存在**（虽然老 COMSOL 文档提到过）
- 用 `hasProperty('<name>')` 检查属性是否存在，比 `try/get/catch` 更可靠

#### 层次 3：API 调用变体批量测试（"哪种调用形式能 work？"）

```matlab
% 模板：对同一个操作测试多种 API 写法
% 例：删除 int2 函数（不知道用哪个 API）

fprintf('--- 1: m.func(''int2'').remove ---\n');
try, m.func('int2').remove; fprintf('OK\n'); catch ME, fprintf('FAIL: %s\n', ME.message); end

fprintf('--- 2: m.func.remove(''int2'') ---\n');
try, m.func.remove('int2'); fprintf('OK\n'); catch ME, fprintf('FAIL: %s\n', ME.message); end

fprintf('--- 3: m.func().remove(''int2'') ---\n');
try, m.func().remove('int2'); fprintf('OK\n'); catch ME, fprintf('FAIL: %s\n', ME.message); end

% 最后看哪种真的删了
disp(m.func.tags);
```

**关键**：每次测试后**必须验证副作用**（比如上例最后 `disp(m.func.tags)` 看 int2 真的消失了）。

### 1.3 失败模式分类（每个错误都对应一类 API 陷阱）

实测遇到的 LiveLink 错误信息按类别归档：

| 错误消息 | 类别 | 根因 | 修复 |
|---|---|---|---|
| `未找到与 'XXX' 类型的输入参数对应的函数 'mphstart'` | 缺 LiveLink path | MATLAB 没 addpath mli/ | `addpath('D:\...\mli')` |
| `未找到 ... 'mphstart' ... 'double'` | 同上 | 同上 | 同上 |
| `未找到与 'XXX' 类型的对象 ... 'remove'` | API 不存在 | `obj.remove` 写法错 | 改用 `container.remove('tag')` |
| `未知属性 argstr` | 属性名不存在 | LiveLink 与文档不同 | 用 `hasProperty` 筛查 |
| `属性值无效 ... 应为字符串数组` | 数据类型不符 | LiveLink 不接受数值矩阵 | 用 `importData(filepath)` |
| `An object with the given name already exists` | 对象已存在 | 没 remove 就 create | 先 remove 再 create |
| `Argument COORD has incorrect orientation or size` | mphinterp coord 维度 | 需 `[3×N]` 不是 `[N×3]` | 转置 `coord'` |
| `Wrong search point dimension in postinterp` | 同上 | 同上 | 同上 |
| `A problem occurred when building mesh feature X#扫掠 1` | 几何不支持扫掠 | 球+layer 用 autoMeshSize 触发扫掠 | 改用 `autoMeshSize(8)` 或显式 FreeTet |
| `Operation cannot be created in this context` | mesh feature 创建方式错 | 不能用 `m.mesh().create('ftr1', 'FreeTetrahedral')` | 用 `autoMeshSize` + `set('hmax', ...)` |
| `Connection refused` | COMSOL Server 不在 | client 退出后 Server 自杀 | 用 `livelink_runner.py` 管理 Server 生命周期 |
| `Vector parameter definitions are not allowed` | 参数不能是向量 | `m.param.set('k', '{0,0,1}')` 失败 | 改用变量定义：`m.variable.set(...)` 或 `Ebg` cell |

### 1.4 验证模板：证明功能真的生效

每个新功能加完后，**必须用"对比实验"证明它真的生效**（不是没报错就算成功）：

| 功能类型 | 验证模板 |
|---|---|
| 加新参数 | 同一输入跑两次，只改这个参数，输出应该不同 |
| 加新接口 | 同一物理场景，新接口和旧接口输出应该一致 |
| 加新物理能力（如多频、各向异性） | 用解析解对比，或用物理对称性对比 |

**实例**（已验证过的对比实验）：

| 实验 | A 输入 | B 输入 | 期望结果 |
|---|---|---|---|
| eps_r 注入 | 全 1 | 球壳 eps=5 | `\|\|E_s\|\|` 差 330 倍 |
| 背景场方向 | +z `[0,0,1]` | +y `[0,1,0]` | 球对称 → `\|\|E_s\|\|` 接近 |
| 非均匀背景场 | step1 均匀场 | step2 用 step1 当背景 | `\|\|E_s\|\|` 应→0（实际 ~10%，精度有限） |

---

## 2. 历史案例：从 29 轮失败到端到端跑通

### 2.1 时间线（每一步对应一次实跑）

```
T0   起点：SDK 沉淀的 forward_solve.m（Z_workspace 版）
     ↓
T1   直接用 SDK solve_forward → 失败 (mphinterp selection/coord 错)
     ↓
T2   写 build_hollow_sphere_model.m → 失败 (扫掠网格、Parametric 缺失)
     ↓
T3   改用 model_export.m → 失败 (vector parameter not allowed)
     ↓
T4   用户提供 livelink_model.mph → ✓ 模型本身工作（Ez=1.6 V/m at origin）
     ↓
T5   写 simple_forward_solve.m (绕过 SDK 沉淀版)
     - coord 维度修对
     - ||E_s||=5.16, ||E_total||=102  ← 首次跑通
     ↓
T6   int2 注入 eps_r → 失败 (An object with given name already exists)
     - 探查 API：发现 m.func('int2').remove 不存在
     - 正确 API：m.func.remove('int2')
     ↓
T7   int2 importData → ✓ 跑通，eps_r 注入验证（330 倍差异）
     ↓
T8   背景场参数化 bg_E → ✓ 跑通（球对称性验证）
     ↓
T9   非均匀背景场 bg_csv → ✓ 工程跑通（DBIM 残差 10%）
```

### 2.2 三个最深的坑

#### 坑 1：mphinterp coord 维度（坑了 29 轮）

**症状**：SDK 沉淀的 forward_solve.m 第 725-819 行用 `'selection', eval_pos'`——
   - 实际上 LiveLink 的 `'selection'` 参数只接受域编号或域标签字符串，不接受坐标
   - 正确参数名是 `'coord'`，且**必须是 `[3×N]`**

**为什么坑了 29 轮**：
- COMSOL 不报错，静默返回 0
- ||E_s||=0 让人以为模型本身有问题，反复改模型/网格
- 真正的 bug 在数据提取层

**修复**：所有 mphinterp 调用改用 `'coord', coord_3xN`。

**给维护者的教训**：**COMSOL 静默返回 0 比报错更危险**。每个 mphinterp 调用后必须检查结果非零。

#### 坑 2：LiveLink Interpolation Function 的 importData API

**症状**：想把 CSV 数据写入 int2 插值函数，5 种写法全部失败：
- `set('table', numeric_matrix)` → "属性值应为字符串数组"
- `set('table', cell_of_strings)` → 同上
- `set('argstr', 'x y z')` → "未知属性 argstr"
- `set('source', 'file') + set('filename', ...)` → 同上
- `set('tablename', ...)` → 同上

**为什么这么坑**：LiveLink API 与 GUI 完全脱节，文档也跟不上。

**最终解法**：
```matlab
m.func.create('int2', 'Interpolation');
m.func('int2').importData('<txt_path>');   % txt 必须空格分隔
m.func('int2').set('funcname', 'int2');
```

`importData` 方法**不在任何 set 属性里**，是 FeatureClient 的独立方法。

**给维护者的教训**：当 `set('xxx', ...)` 全部失败时，**用 `methods(obj)` 列出所有方法，找动词命名的方法**（importData、exportData、discardData、refresh 等）。

#### 坑 3：COMSOL Server 单客户端自杀

**症状**：每次 MATLAB client 退出（即使不调 disconnect），COMSOL Server 也跟着退出。下一次连接就 `Connection refused`。

**根因**：`comsolmphserver.exe` 默认是"单客户端模式"——client 断开 Server 就退出。

**修复**：在 Python 进程内管理 Server 生命周期，见 [livelink_runner.py](../../../../engine/sdk/forward_pipeline/scripts/livelink_runner.py)。

**给维护者的教训**：跨进程集成的状态管理不能假设——COMSOL Server 不是守护进程，每次都要自己管。

---

## 3. 工具链（每次探索必备）

### 3.1 自管理 Server + MATLAB 的 runner

[livelink_runner.py](../../../../engine/sdk/forward_pipeline/scripts/livelink_runner.py) 已经封装好：
- 启动 COMSOL Server（带 `-tmpdir` 参数）
- 等端口就绪
- 调 matlab.exe -batch
- MATLAB 退出后停 Server

**用法**：
```bash
python -X utf8 livelink_runner.py <your_script.m> [cwd]
```

**永远不要直接 `matlab.exe -batch`**——Server 会自杀。

### 3.2 PowerShell + UTF-8 环境

每次跑 MATLAB 之前必须设：
```powershell
$env:PYTHONIOENCODING = "utf-8"
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```

**为什么**：MATLAB 的中文错误消息在 GBK 控制台下变成乱码，看不出 root cause。

### 3.3 .mat 文件读取（v7.3 HDF5）

SDK 的 .mat 输出是 v7.3（HDF5）。**scipy.io.loadmat 不能读**，必须用 h5py：

```python
import h5py
import numpy as np

with h5py.File('scatter.mat', 'r') as f:
    raw = f['E_total_voxel'][:]

# 复数存储为结构化 dtype：[('real','<f8'), ('imag','<f8')]
if raw.dtype.names is not None and 'real' in raw.dtype.names:
    E = raw['real'] + 1j * raw['imag']
else:
    E = raw

# MATLAB 是列主序，h5py 读出来的维度是反的
# MATLAB 里 [N_voxel x 3 x N_freq] → h5py 读出 [N_freq x 3 x N_voxel]
E = E.transpose()
```

**坑**：维度反转 + 复数 dtype 是两个独立的陷阱。

### 3.4 MATLAB 脚本生成（避免 Python f-string 陷阱）

当用 Python 生成 MATLAB 脚本时，**不要用 f-string**——`\n` 会被 Python 解释成换行，破坏 MATLAB 字符串字面量。

**正确做法**：用普通 `r'''...'''` 模板 + `.replace("<<PLACEHOLDER>>", value)`：

```python
TEMPLATE = r'''
fprintf('[main] Loading: <<MPH>>\n');
m = mphload('<<MPH>>');
'''

script = TEMPLATE.replace("<<MPH>>", mph_path.replace("\\", "/"))
```

**已知具体陷阱**：
- `fprintf('...%s...\n', val)` 里的 `\n` 会被 f-string 字面化
- 字符串字面量里的 `''`（MATLAB 转义单引号）和 Python 的 `'` 混淆
- 中文注释经过 Python + MATLAB 双重编码后可能损坏

---

## 4. 当前 SDK 的 7 个未解决问题（给下一个维护者的礼物）

按优先级排序，每个都标了"探索起点"：

### 4.1 [+x 方向入射场得到 0]

**症状**：bg_E = [1,0,0]（+x 入射）时 ||E_s||=0；bg_E = [0,0,1] 和 [0,1,0] 都正常。

**怀疑原因**：livelink_model.mph 的 PML 配置可能只在 z 方向（或 yz 平面）有 PML，+x 方向的波打到非 PML 边界反射抵消。

**探索起点**：
```matlab
% 探查 PML 配置
pml_sel = m.coordSystem('pml1').selection.defined;
disp(pml_sel);   % 看 PML 域编号
% 然后查这些域对应几何的哪些部分
```

**修复方向**：要么改 .mph 让 PML 全方向包围（推荐），要么在 simple_forward_solve.m 里加个警告。

### 4.2 [DBIM 闭环残差 10%]

**症状**：把 step1 的 E_total 作为 step2 的非均匀背景场，无散射体时 ||E_s|| 应该是 0，实际得到 ~10。

**怀疑原因**：
1. 数值场不是麦克斯韦严格解（网格离散误差）
2. 体素网格 round-trip 插值误差
3. 背景场公式可能要求解析表达式

**探索起点**：
- 用**解析平面波** `E_bg = exp(-ikz)` 生成 bg_csv（不依赖 step1 数值解），看 ||E_s|| 是否→0
- 如果解析场也残差大，说明是公式约束；如果解析场残差小，说明是数值噪声

### 4.3 [SDK 沉淀的 forward_solve.m 与 simple_forward_solve.m 未合并]

**症状**：目前两套脚本并存，simple 是已验证版，沉淀版有 selection/coord bug。

**探索方向**：把 simple 的 importData + bg_csv 修复 merge 到沉淀版，然后跑 SDK Python API 的 test_smoke.py。

### 4.4 [多频率扫描未实测]

**症状**：脚本支持 freq_list=[0.8e9, 1e9]，但只实测过单频 [1e9]。

**探索起点**：直接跑 freq_list=[0.8e9, 1e9]，检查 E_s 第三维 size 是否=2。

### 4.5 [伴随场求解未实测]

**症状**：SDK 有 adjoint_solve.m（沉淀自 Z_workspace），但伴随管线 run_adjoint_pipeline.m 没跑过。

**探索起点**：先用 simple_forward_solve 跑出 E_total，构造一个测试伴随源 f_adj，调 adjoint_solve。

### 4.6 [SDK Python API（ForwardPipeline 类）未对接 simple_forward_solve]

**症状**：当前 SDK 的 [api.py](../../../../engine/sdk/forward_pipeline/api.py) 调的是沉淀版 forward_solve.m，不是 simple_forward_solve.m。

**探索方向**：api.py 加一个 `use_simple=True` 参数，或者直接切到 simple。

### 4.7 [livelink_model.mph 的 sctr1 selection 与当前几何不匹配]

**症状**：model_export.m 第 51-52 行的 sctr1 selection.set([5 6 7 8 24 25 35 46]) 是当时几何的编号，几何变了的 .mph 可能编号不同。

**探索起点**：探查 .mph 里 sctr1 的当前 selection，对照当前几何域编号。如果匹配，没问题；如果不匹配，背景场散射公式可能错。

---

## 5. 写新功能时的代码风格规范

### 5.1 simple_forward_solve.m 风格

参考 [simple_forward_solve.m](../../../../engine/sdk/forward_pipeline/matlab/simple_forward_solve.m)：

- **每个新参数独立 if 块**：`if isfield(params, 'xxx') && ~isempty(params.xxx)`
- **每个外部调用 try-catch**：失败时打印 `[simple][WARN] xxx failed: ...` 但不阻塞主流程
- **每个 stage 打印 marker**：`fprintf('[simple] Stage X: ...\n')`
- **结果验证**：在 return 前打印 `||E_s||` / `||E_total||` 范数

### 5.2 探查脚本风格

- 每个测试变体独立的 try-catch 块
- 失败时打印 `[test] xxx FAIL: <message>`
- 成功时打印 `[test] xxx: OK`
- 最后**必须**有副作用验证（比如 `disp(m.func.tags)`）

### 5.3 错误处理优先级

```
1. 显式验证（hasProperty / isfield / exist）  ← 优先
2. try-catch ME + fprintf warning              ← 兜底
3. silent skip                                  ← 绝对避免
```

**绝对不要 silent skip**——这是 29 轮失败的根因之一。

---

## 6. 跑通验证的标准回归集

每次改 SDK 后必须跑这 4 个脚本（按顺序）：

```bash
cd <project_root>

# 1. .mph 本身能加载求解
python -X utf8 engine/sdk/forward_pipeline/scripts/diag_livelink_mph.py

# 2. 任意 eps_r 注入
python -X utf8 engine/sdk/forward_pipeline/scripts/verify_eps_injection.py
# 期望：B/A 的 ||E_s|| 比值 > 100

# 3. 均匀背景场参数化
python -X utf8 engine/sdk/forward_pipeline/scripts/verify_bg_field.py
# 期望：+z 和 +y 的 ||E_s|| 相差 < 1%（球对称）

# 4. 非均匀背景场（可选，慢）
python -X utf8 engine/sdk/forward_pipeline/scripts/verify_nonuniform_bg.py
# 期望：step2 跑通（||E_s|| 残差 < 50% 即可）
```

**任何一个失败 → 不能 commit**。

---

## 7. 资产地图（一键跳转）

### 7.1 代码

```
engine/sdk/forward_pipeline/
├── matlab/
│   ├── simple_forward_solve.m          ← 核心，已验证
│   ├── launcher.m                       ← SDK Python API 用的（未对接 simple）
│   ├── run_forward_pipeline.m           ← 沉淀版（有 selection bug）
│   ├── adjoint_solve.m                  ← 未实测
│   ├── compute_jobs.m / v5a_check.m / save_results.m  ← 已沉淀
│   └── build_hollow_sphere_model.m      ← 自建模型（已弃用，用 livelink_model.mph）
├── scripts/
│   ├── livelink_runner.py               ← Server + MATLAB 生命周期管理（必用）
│   ├── diag_livelink_mph.py             ← 回归测试 1
│   ├── verify_eps_injection.py          ← 回归测试 2
│   ├── verify_bg_field.py               ← 回归测试 3
│   ├── verify_nonuniform_bg.py          ← 回归测试 4
│   ├── probe_emw_structure.py           ← API 探查工具
│   ├── api_probe.py                     ← API 探查工具
│   └── list_int2_props.py / test_import_data2.py  ← API 探查历史
└── .e2e_runs/hollow_sphere/             ← 所有跑过的日志和 .mat（历史证据）
```

### 7.2 模型

```
COMSOL/
├── livelink_model.mph                   ← 基准模型（用户提供，已验证）
└── model_export.m                       ← COMSOL 导出的 .m（损坏，仅参考）
```

### 7.3 文档

```
apps/phantom-constrained-inverse-scattering/knowledge/
├── COMSOL正演管线SDK运行手册.md          ← API 参考 + 能力清单（给 app 角色）
└── SDK维护者手册.md                      ← 本文件（给 SDK 维护者）
```

---

## 8. 给下一个维护者的三句话

1. **永远先 `methods(obj)` 再写代码**——LiveLink API 比你想的奇怪得多
2. **永远用对比实验验证新功能**——"没报错"不等于"功能生效"
3. **永远用 livelink_runner.py**——直接 matlab.exe 会让 Server 自杀

---

## 9. 联系历史

- 本 SDK 是在排查"29 轮 R2a→R2d 角色循环失败"时建立的
- 29 轮失败的根因是 SDK 沉淀版 forward_solve.m 的 `'selection', eval_pos'` bug
- simple_forward_solve.m 是绕过沉淀版的简化重写，已端到端验证

详见 [SDK运行手册.md §9 历史背景](COMSOL正演管线SDK运行手册.md)。

---

**最后修改**：2026-07-18
**修改本文件前必须**：跑通 §6 的 4 个回归脚本
