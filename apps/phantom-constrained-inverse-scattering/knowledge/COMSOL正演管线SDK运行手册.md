# COMSOL 正演管线 SDK — 运行手册

> **资产性质**：跨实验可复用的固定资产。本文档记录的是**已经端到端跑通验证**的能力，每一条都有实跑日志证据。
> **接入位置**：`apps/phantom-constrained-inverse-scattering/roles/正演执行者/`
> **最后验证日期**：2026-07-18

---

## 0. 一句话能力概括

**给定一个 .mph 模型 + 一份 eps_r CSV，跑出非零的散射场 J_obs。eps_r 可以任意变化，背景场方向也可以任意变化。**

---

## 0.5 快速入门（5 分钟跑出第一个正演结果）

> **本节专门回答："我有一个 eps_r，怎么得到正演结果？"**
> 不读其他章节也能跑通。

### 你需要准备什么

- **一份 eps_r CSV 文件** — 格式：`x, y, z, eps_r`（4 列，逗号分隔，无表头）
  - 散射体区域：填你想要的 eps_r（比如 5）
  - 背景区域：填 1.0
- **环境已就绪**：COMSOL 6.2 + MATLAB + LiveLink（路径见 §3.2）

### 完整三步示例

假设你要测试一个半径 0.1m、eps_r=3 的实心球散射体。

#### Step 1：生成 eps_r CSV

存为 `gen_eps.py`：

```python
import numpy as np
coord = np.arange(-0.20, 0.21, 0.02)
X, Y, Z = np.meshgrid(coord, coord, coord, indexing="ij")
R = np.sqrt(X**2 + Y**2 + Z**2)
eps = np.where(R <= 0.1, 3.0, 1.0)   # r<=0.1 为散射体 eps=3，其他为背景 1
np.savetxt('my_eps.csv',
           np.column_stack([X.flatten(), Y.flatten(), Z.flatten(), eps.flatten()]),
           delimiter=',', fmt='%.6f')
print(f'wrote {len(eps.flatten())} voxels')
```

跑：`python gen_eps.py` → 生成 `my_eps.csv`

#### Step 2：生成 MATLAB runner 脚本

存为 `run_my_forward.m`（**可直接复制粘贴**）：

```matlab
addpath('D:/LenovoSoftstore/Install/COMSOL62/Multiphysics/mli');
addpath('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/matlab');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

params = struct();
params.model_path   = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph';
params.eps_real_csv = 'my_eps.csv';
params.freq_list    = [1e9];
params.n_directions = 64;
params.measurement_R = 0.26;
params.output_path  = 'my_result.mat';
params.bg_E         = [0, 0, 1];   % +z 方向入射

csv_data = readmatrix(params.eps_real_csv);
params.voxel_positions = csv_data(:, 1:3);

result = simple_forward_solve(params);

fprintf('\n=== Result ===\n');
fprintf('status: %s\n', result.status);
if strcmp(result.status, 'success')
    Es = result.scattered_field.E_s;
    fprintf('||E_s|| = %.4e (散射场总范数)\n', sqrt(sum(abs(Es(:)).^2)));
    fprintf('E_s shape: [%d x 3 x %d]\n', size(Es, 1), size(Es, 3));
end
```

#### Step 3：用 livelink_runner 跑

```powershell
cd <你的工作目录>
python -X utf8 D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/scripts/livelink_runner.py run_my_forward.m
```

**预期输出**：
```
[simple] ||E_s|| = X.XXe+00, ||H_s|| = X.XXe-02
[simple] ||E_total_voxel|| = X.XXe+01
[simple] Saved: .../my_result.mat
=== Result ===
status: success
||E_s|| = X.XXe+00 (散射场总范数)
E_s shape: [64 x 3 x 1]
```

### 结果文件 `my_result.mat` 包含什么

用 Python 读取（注意是 v7.3 HDF5 格式，必须用 h5py）：

```python
import h5py
import numpy as np

with h5py.File('my_result.mat', 'r') as f:
    raw_E_s = f['E_s'][:]
    # h5py 读 MATLAB v7.3 复数：结构化 dtype
    if raw_E_s.dtype.names and 'real' in raw_E_s.dtype.names:
        E_s = raw_E_s['real'] + 1j * raw_E_s['imag']
    else:
        E_s = raw_E_s
    # 维度反转
    E_s = E_s.transpose()

print(f'E_s shape: {E_s.shape}')   # [64, 3, 1]
print(f'||E_s|| = {np.linalg.norm(E_s):.4e}')
```

### 常见问题

| 问题 | 原因 | 解决 |
|---|---|---|
| `Connection refused` | COMSOL Server 未启动 | livelink_runner 会自动启动；如手动调，参见 §6 |
| `mphstart 找不到函数` | LiveLink API path 未加 | 脚本里的 addpath 路径对吗？ |
| `int2 setup failed` | .mph 已有 int2 且 API 调用错 | 已在 simple_forward_solve.m 里自动处理 |
| `||E_s|| = 0` | 背景场和散射体几何不匹配（如 +x 入射但 PML 只在 z 方向） | 改 `params.bg_E` 试试 |

### 想改其他参数？

| 我想改... | 改哪里 |
|---|---|
| 散射体形状/大小/eps 值 | `gen_eps.py` 里的 `np.where(...)` |
| 入射波方向 | runner 脚本里的 `params.bg_E = [Ex, Ey, Ez]` |
| 频率 | `params.freq_list = [0.8e9, 1e9]` |
| 测量点密度 | `params.n_directions = 128` |
| 非均匀背景场 | `params.bg_csv = 'bg_field.csv'`（替代 bg_E，格式见 §3.1） |

### 还想了解更多？

- 完整接口字段说明 → §3.1
- 7 个已验证能力的完整清单 → §1
- LiveLink API 经验（出问题排查用） → §5
- 想扩展 SDK 加新功能 → 看 [SDK维护者手册.md](SDK维护者手册.md)

---

## 1. 已验证能力清单（每条都有实跑证据）

| # | 能力 | 验证证据 | 物理合理性 |
|---|---|---|---|
| 1 | 加载固定 .mph + COMSOL Server 求解 + mphinterp 提取场 | `diag_livelink_mph.py` 跑出 `Ez at (0,0,0) = 1.6455 V/m` | ✓ 背景场在原点 ~1 V/m |
| 2 | **从 CSV 注入任意 eps_r 分布** | `verify_eps_injection.py` A vs B 对比：均匀 eps=1 给 `\|\|E_s\|\|=0.016`，球壳 eps=5 给 `\|\|E_s\|\|=5.42` | ✓ 330 倍差异，散射体产生散射 |
| 3 | **均匀背景场参数化** `bg_E=[Ex,Ey,Ez]` | `verify_bg_field.py` 三方向对比：+z 和 +y 的 `\|\|E_s\|\|` 接近（球对称性验证） | ✓ 球对称误差 < 0.3% |
| 4 | **非均匀背景场** `bg_csv` | `verify_nonuniform_bg.py` 两步 DBIM 流程，6 个插值函数 + Ebg 绑定全部成功 | ✓ 工程跑通（残差~10% 来自数值噪声） |
| 5 | 多方向散射场提取（Fibonacci 球面 N=64） | 所有 run 都有 `E_s [64×3×N_freq]` | ✓ |
| 6 | 体素总场提取 `E_total_voxel [N_voxel×3×N_freq]` | 所有 run 都有，9261 体素非零 | ✓ |
| 7 | 保存标准 .mat（v7.3 HDF5 格式） | 所有 run 都有 `scatter_field.mat` ~400 KB | ✓ |

---

## 2. 资产清单

### 2.1 代码资产

| 文件 | 角色 | 状态 |
|---|---|---|
| [engine/sdk/forward_pipeline/matlab/simple_forward_solve.m](../../../../engine/sdk/forward_pipeline/matlab/simple_forward_solve.m) | **核心**：已验证可跑通的简化正演脚本 | ✓ 跑通 |
| [engine/sdk/forward_pipeline/scripts/livelink_runner.py](../../../../engine/sdk/forward_pipeline/scripts/livelink_runner.py) | COMSOL Server + MATLAB 子进程管理（自动启停） | ✓ 跑通 |
| [COMSOL/livelink_model.mph](../../../../COMSOL/livelink_model.mph) | 基准模型（含几何+网格+物理场+求解器） | ✓ 跑通 |

### 2.2 验证脚本（都有实跑日志）

| 脚本 | 验证内容 |
|---|---|
| [scripts/diag_livelink_mph.py](../../../../engine/sdk/forward_pipeline/scripts/diag_livelink_mph.py) | .mph 模型本身可加载、可求解、场值非零 |
| [scripts/verify_eps_injection.py](../../../../engine/sdk/forward_pipeline/scripts/verify_eps_injection.py) | 任意 eps_r CSV 注入：A=均匀 vs B=球壳，330 倍差异 |
| [scripts/verify_bg_field.py](../../../../engine/sdk/forward_pipeline/scripts/verify_bg_field.py) | 均匀背景场参数化：+z vs +x vs +y |
| [scripts/verify_nonuniform_bg.py](../../../../engine/sdk/forward_pipeline/scripts/verify_nonuniform_bg.py) | 非均匀背景场（DBIM 两步流程） |
| [scripts/probe_emw_structure.py](../../../../engine/sdk/forward_pipeline/scripts/probe_emw_structure.py) | .mph 内部结构探查（func/feature/material） |
| [scripts/api_probe.py](../../../../engine/sdk/forward_pipeline/scripts/api_probe.py) | LiveLink API 调用方式探查 |

---

## 3. 核心接口契约

### 3.1 MATLAB 入口：`simple_forward_solve(params)`

**位置**：`engine/sdk/forward_pipeline/matlab/simple_forward_solve.m`

**输入参数（params 结构体）**：

| 字段 | 类型 | 必填 | 含义 |
|---|---|---|---|
| `model_path` | char | ✓ | .mph 模型文件路径 |
| `eps_real_csv` | char | ✓ | 散射体 eps_r 分布 CSV（格式：`x,y,z,eps_r`） |
| `freq_list` | double array | ✓ | 频率列表 [Hz]，如 `[1e9]` 或 `[0.8e9, 1e9]` |
| `n_directions` | int | | Fibonacci 方向数，默认 64 |
| `measurement_R` | double | | 测量球面半径 [m]，默认 0.26 |
| `output_path` | char | ✓ | 输出 .mat 路径 |
| `voxel_positions` | double [N×3] | | 体素中心坐标（用于提取 E_total） |
| `bg_E` | double [1×3] | | **均匀背景场** [Ex, Ey, Ez] V/m，覆盖 .mph 默认值 |
| `bg_csv` | char | | **非均匀背景场** CSV（格式：`x,y,z,Ex_re,Ey_re,Ez_re,[Ex_im,Ey_im,Ez_im]`），覆盖 `bg_E` |

**优先级**：`bg_csv` > `bg_E` > `.mph 原始配置`

**输出（result 结构体）**：

| 字段 | 含义 |
|---|---|
| `result.status` | `'success'` / `'error'` |
| `result.error_msg` | 错误详情 |
| `result.scattered_field.E_s` | 散射电场 `[N_dir×3×N_freq]` 复数 |
| `result.scattered_field.H_s` | 散射磁场 `[N_dir×3×N_freq]` 复数 |
| `result.scattered_field.eval_pos` | 测量点坐标 `[N_dir×3]` |
| `result.total_field.E_total` | 体素总场 `[N_voxel×3×N_freq]` 复数 |
| `result.total_field.voxel_pos` | 体素坐标 `[N_voxel×3]` |

**输出文件**：`output_path` 指定的 .mat（v7.3 HDF5 格式）

### 3.2 Python 编排：`livelink_runner.py`

**位置**：`engine/sdk/forward_pipeline/scripts/livelink_runner.py`

**职责**：
- 自动启动/停止 COMSOL Server（避免 client 断开导致 Server 自杀）
- 调用 `matlab.exe -batch run('<script>.m')`
- 实时打印 MATLAB 输出

**用法**：
```bash
python livelink_runner.py <script.m> [cwd]
```

**环境要求**：
- COMSOL Server：`D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe`
- MATLAB：`D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe`
- LiveLink API：`D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli`
- 端口：2036

---

## 4. 标准调用模板（供 app 角色直接消费）

### 4.1 MATLAB 调用方模板

```matlab
% 1. 准备工作
addpath('D:/LenovoSoftstore/Install/COMSOL62/Multiphysics/mli');   % LiveLink API
addpath('<SDK路径>/engine/sdk/forward_pipeline/matlab');             % simple_forward_solve.m

% 2. 连接 COMSOL Server
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

% 3. 构造参数
params = struct();
params.model_path      = '<SDK路径>/COMSOL/livelink_model.mph';
params.eps_real_csv    = '<工作区>/config/eps_real.csv';   % 散射体 eps_r 分布
params.freq_list       = [1e9];                            % 1 GHz
params.n_directions    = 64;
params.measurement_R   = 0.26;
params.output_path     = '<工作区>/outputs/scatter_field.mat';
params.bg_E            = [0, 0, 1];                        % +z 方向均匀背景场
% params.bg_csv         = '<工作区>/config/bg_field.csv';  % （可选）非均匀背景场

% 4. 加载体素位置（从 eps CSV 前 3 列）
csv_data = readmatrix(params.eps_real_csv);
params.voxel_positions = csv_data(:, 1:3);

% 5. 调用 SDK
result = simple_forward_solve(params);

% 6. 检查结果
if strcmp(result.status, 'success')
    Es = result.scattered_field.E_s;
    fprintf('||E_s|| = %.4e\n', sqrt(sum(abs(Es(:)).^2)));
end
```

### 4.2 Python 调用方模板（用 livelink_runner）

```python
# 1. 生成 eps CSV（Python 端）
import numpy as np
coord = np.arange(-0.20, 0.21, 0.02)
X, Y, Z = np.meshgrid(coord, coord, coord, indexing="ij")
R = np.sqrt(X**2 + Y**2 + Z**2)
eps = np.where((R >= 0.05) & (R <= 0.12), 5.0, 1.0)   # 空心球壳 eps=5
np.savetxt('eps_real.csv', np.column_stack([X.flatten(), Y.flatten(), Z.flatten(), eps.flatten()]),
           delimiter=',', fmt='%.6f')

# 2. 生成 MATLAB runner 脚本（用上文模板）

# 3. 用 livelink_runner 跑
import subprocess
subprocess.run([
    'python', '-X', 'utf8',
    '<SDK路径>/engine/sdk/forward_pipeline/scripts/livelink_runner.py',
    '<工作区>/run_forward.m',
    '<工作区>',
], env={**os.environ, 'PYTHONIOENCODING': 'utf-8'})
```

---

## 5. 关键 API 经验（COMSOL LiveLink 6.2 实测）

### 5.1 Interpolation Function（插值函数，用于 eps_r 和非均匀背景场）

| 操作 | 正确 API | ❌ 错误 API |
|---|---|---|
| 删除 | `m.func.remove('int2')` | `m.func('int2').remove`（不存在） |
| 创建 | `m.func.create('int2', 'Interpolation')` | — |
| **加载数据** | `m.func('int2').importData('<txt_path>')` ✓ | `m.func('int2').set('table', matrix)` ✗（不接受数值） |
| 设置函数名 | `m.func('int2').set('funcname', 'int2')` | — |
| ~~设 argstr~~ | **不存在该属性** | `set('argstr', 'x y z')` ✗（"未知属性"） |

**.txt 文件格式**：空格分隔，每行 `x y z value`。

### 5.2 Physics Feature（物理场特征）

| 操作 | 正确 API |
|---|---|
| 取 feature | `m.physics('emw').feature('wee1')` |
| feature 类型 | `m.physics('emw').feature('wee1').getType()`（返回 `'WaveEquationElectric'`） |
| 设 epsilonr | `m.physics('emw').feature('wee1').set('epsilonr_mat', 'userdef')` + `set('epsilonr', 'int2(x,y,z)')` |

### 5.3 Background Field（背景场）

| 操作 | API |
|---|---|
| 取 prop | `m.physics('emw').prop('BackgroundField')` |
| 设均匀场 | `.set('Ebg', {'0' '0' '1[V/m]'})` — cell of strings |
| 设非均匀场 | `.set('Ebg', {'int_bg_x(x,y,z)' 'int_bg_y(x,y,z)' 'int_bg_z(x,y,z)'})` |

### 5.4 mphinterp（场提取）

| 参数 | 正确用法 |
|---|---|
| `'coord'` | **必须是 `[3×N]`**（不是 N×3） |
| `'dataset'` | `'dset1'` |
| `'solnum'` | 频率索引（1-based） |
| 散射场变量 | `emw.relEx` / `emw.relEy` / `emw.relEz` |
| 总场变量 | `emw.Ex` / `emw.Ey` / `emw.Ez` |

### 5.5 求解

| 操作 | API |
|---|---|
| Study 跑 | `m.study('std1').run` ✓ |
| Solver 全跑 | `m.sol('sol1').runAll` ✓ |
| ~~`m.sol.run`~~ | 不带参数无效 |

---

## 6. COMSOL Server 关键约束

| 约束 | 含义 | 解决 |
|---|---|---|
| **默认单客户端模式会自杀** | MATLAB client 退出 → COMSOL Server 也退出 | 用 [livelink_runner.py](../../../../engine/sdk/forward_pipeline/scripts/livelink_runner.py) 在 Python 进程内管理 Server 生命周期 |
| 启动参数 | `-port 2036 -tmpdir C:\Temp\comsol` | — |
| 端口检测 | `Get-NetTCPConnection -LocalPort 2036` | — |

---

## 7. 推荐给 app 角色的工作流

### 当前 app 的 [正演执行者](roles/正演执行者/skill.md) 工作流（旧）

```
正演COMSOL工程师 → 写 forward_solve.m
物理算法工程师 → 写 compute_jobs.m / v5a_check.m / save_results.m
正演执行者 → 调 matlab.exe 跑 run_forward_pipeline.m
            ↓ （失败 29 轮）
        J_obs_data.mat
```

**问题**：6 个脚本每次都要由上游角色重新生成，正演执行者只是被动调用，没有 SDK 缓冲。

### 推荐的新工作流（SDK 接入后）

```
正演执行者（新职责）：
  1. 读取 config/eps_real.csv（由仿真配置者产出）
  2. 直接调 simple_forward_solve（params）
  3. 输出 scatter_field.mat → 后续 compute_jobs + v5a_check（这些仍是上游角色资产）
```

**改动点**：
- **正演执行者的 skill.md 需要重写**——把"调用 run_forward_pipeline.m"改成"调用 simple_forward_solve"
- **正演执行者的 inputs 需要加 .mph 路径**（新增 `COMSOL/livelink_model.mph`）
- **正演COMSOL工程师 和 物理算法工程师** 角色可以**降级或合并**——因为 simple_forward_solve 已经包含了 forward_solve 的全部功能

### 推荐 verdict 映射

| SDK result.status | 角色 verdict | 含义 |
|---|---|---|
| `success` | `confirmed` | J_obs 生成成功 |
| `error` (stage=forward) | `code_bug` → 仍然回退（但目标是 SDK 维护者，不是上游角色） | SDK 代码 bug |
| `error` (stage=param_check) | `fail` | 调用方参数错（CSV 缺失等） |

---

## 8. 待办（精度提升方向）

| 项目 | 当前状态 | 优先级 |
|---|---|---|
| DBIM 闭环精度（数值场→背景场残差 ~10%） | 工程跑通，物理精度有限 | 中 |
| 多频率扫描验证（freq_list=[0.8e9, 1e9]） | 脚本支持，未实测 | 低 |
| 把 simple_forward_solve.m 的修复 merge 回 SDK 沉淀的 forward_solve.m | 待做 | 中 |
| 把 SDK Python API（ForwardPipeline 类）改成调 simple_forward_solve | 待做 | 高 |

---

## 9. 历史背景（为什么有这个 SDK）

参考项目记忆：
- 上次 default 工作区跑了 29 轮 R2a→R2d 循环，最终卡在 ||E_s||=0
- 根因：SDK 沉淀的 forward_solve.m 有 `'selection', eval_pos'` bug（mphinterp 应该用 `'coord'`）
- 本 SDK（simple_forward_solve.m）是**绕过沉淀版**重写的简化实现，已端到端跑通

---

**文档维护者**：SDK 维护者（不是 app 角色）
**修改本文件前必须**：跑通所有验证脚本（scripts/verify_*.py）并附日志证据
