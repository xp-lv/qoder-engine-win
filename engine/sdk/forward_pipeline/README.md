# COMSOL Forward Pipeline SDK

跨 app 共享的 COMSOL 频域电磁正演/伴随管线 SDK。

把"建一次、反复用"的 COMSOL LiveLink 管线从 app 内的角色任务上移为 engine 层的固定资产 SDK，提供稳定的 Python API。逆散射 app 后续只调 API，不再背负"构建管线"职责。

## 资产属性声明

> **跨实验可复用的固定资产。修改本目录下任何文件需附验证证据。**

这一声明与项目记忆 [COMSOL 正演管线脚本的固定资产属性](../../../Z_workspace/phantom-constrained-inverse-scattering/scripts) 对齐。SDK 维护者必须在修改前：
1. 先验证现有产出的接口完整性；
2. 修改后跑通 `tests/` 下全部单元测试；
3. 在 commit message 中记录 SHA-256 变化。

## 目录结构

```
engine/sdk/forward_pipeline/
├── __init__.py                    # 包导出
├── api.py                         # ForwardPipeline 主 API
├── cache.py                       # SHA-256 输入哈希缓存
├── matlab_runner.py               # MATLAB 子进程封装
├── matlab/                        # MATLAB 固定资产层
│   ├── forward_solve.m            # 沉淀自 Z_workspace（原样复制）
│   ├── adjoint_solve.m            # 沉淀自 Z_workspace（原样复制）
│   ├── compute_jobs.m             # 沉淀自 Z_workspace（原样复制）
│   ├── v5a_check.m                # 沉淀自 Z_workspace（原样复制）
│   ├── save_results.m             # 沉淀自 Z_workspace（原样复制）
│   ├── run_forward_pipeline.m     # 沉淀自 default + 字段适配
│   ├── run_adjoint_pipeline.m     # 新写（仿 forward 编排）
│   └── launcher.m                 # 通用 CLI 入口
├── tests/
│   ├── test_cache.py              # 哈希一致性 + lookup/store/clear
│   ├── test_matlab_runner.py      # subprocess 封装（mock）
│   ├── test_api.py                # API 参数校验 + 缓存命中（mock）
│   └── test_smoke.py              # 端到端冒烟（@slow，需真实 COMSOL）
└── README.md                      # 本文件
```

## Python API

### ForwardPipeline 类

```python
from engine.sdk.forward_pipeline import ForwardPipeline, ForwardResult, AdjointResult

pipe = ForwardPipeline(
    comsol_server_path=r"C:\Program Files\COMSOL\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe",
    mli_path=r"C:\Program Files\COMSOL\COMSOL62\Multiphysics\mli",
    matlab_exe=r"D:\LenovoSoftstore\Install\MATLAB\R2023b\bin\matlab.exe",
    comsol_port=2036,
    startup_timeout=240,
    run_timeout=1800,
    # cache_root 默认 engine/sdk/forward_pipeline/.cache
)
```

### solve_forward

```python
result: ForwardResult = pipe.solve_forward(
    eps_real_csv=r"C:\path\to\eps_real.csv",     # 必填
    eps_imag_csv=r"C:\path\to\eps_imag.csv",     # 可空字符串
    freq_list=[0.8e9, 1.0e9],                    # [Hz]
    model_path=r"C:\path\to\model.mph",          # 必填
    output_dir=r"C:\path\to\outputs",            # 必填
    n_directions=64,
    measurement_R=0.26,
    run_v5a=True,                                 # False 跳过 V5a
    tol=0.05,
    phantom_type="single_layer",
    use_cache=True,
)
```

返回的 `ForwardResult` 字段：

| 字段 | 类型 | 含义 |
|---|---|---|
| `status` | str | `'success'` / `'error'` / `'cached'` |
| `stage` | str | 失败阶段 tag（仅 error 时有意义） |
| `error_msg` | str | 错误详情 |
| `mat_path` | str | `J_obs_data.mat` 绝对路径（缓存命中时指向缓存目录） |
| `json_path` | str | `forward_dataset.json` 绝对路径 |
| `v5a_verdict` | str | `'pass'` / `'fail'` / `'skipped'` / `''` |
| `v5a_rel_error` | float | V5a 相对误差 |
| `cache_hit` | bool | 是否命中缓存 |
| `duration_sec` | float | 本次调用总耗时 |
| `metadata` | dict | 含 `key_hash`, `work_dir`, `log_path` |

### solve_adjoint

```python
result: AdjointResult = pipe.solve_adjoint(
    forward_mat_path=r"C:\...\J_obs_data.mat",    # 正演产出
    f_adj_mat_path=r"C:\...\f_adj.mat",           # 伴随源（含变量 f_adj [n_voxel×3]）
    voxel_positions_mat_path=r"C:\...\voxel.mat", # 含 r_voxel 或 voxel_positions
    freq_list=[0.8e9, 1.0e9],
    model_path=r"C:\path\to\model.mph",
    output_dir=r"C:\path\to\outputs",
    use_cache=True,
)
```

返回的 `AdjointResult` 字段：`status` / `stage` / `error_msg` / `adjoint_mat_path` / `cache_hit` / `duration_sec` / `metadata`。

### 缓存管理

```python
pipe.clear_cache()                              # 清全部
pipe.clear_cache(older_than_days=7)             # 只清 7 天前的
stats = pipe.cache_stats()                      # {'entries': N, 'total_bytes': B}
```

## 缓存策略

**幂等保证**：相同输入直接返回 cached 结果，不重跑 COMSOL。

**哈希输入项**（任一变化 → 缓存失效）：
- `eps_real_csv` 文件内容 SHA-256（**不是路径**）
- `eps_imag_csv` 文件内容 SHA-256
- `model_path` (.mph) 文件内容 SHA-256
- `freq_list` 序列化（顺序敏感）
- `n_directions`、`measurement_R`
- `SDK_VERSION`（强制版本失效）
- 伴随缓存额外含 `f_adj_mat_path` / `forward_mat_path` 内容哈希

**缓存目录布局**：

```
.cache/
└── <sha256[:16]>/
    ├── input.json              # 输入参数快照
    ├── forward/
    │   ├── J_obs_data.mat
    │   ├── forward_dataset.json
    │   └── v5a_result.json
    └── adjoint/
        └── adjoint_field.mat
```

**原子写入**：所有 store 操作先写 `.tmp/` 再 rename，避免并发或中断产生半成品缓存。

## 与 MATLAB 的契约

### 启动方式

```bash
matlab.exe -batch "addpath('<sdk_matlab_dir>'); launcher('run_forward_pipeline', '<params.json>');"
```

### launcher.m 职责

1. 读 ASCII-only `params.json`
2. 转为 MATLAB `struct`
3. `feval(entry_function, params)`
4. 写 `work_dir/exit.flag`（0=success，非 0=failure）
5. `exit.flag` 是**权威退出信号**，覆盖 MATLAB 进程返回码

### 中文路径安全

`params.json` 由 Python 端用 `ensure_ascii=True` 写入，所有中文字符串已转义为 `\uXXXX`。如 MATLAB 端需要中文字符串（如 diary 日志文件名），必须用 `char([code_points])` 构造，保持源码 ASCII。

## 环境要求

| 组件 | 版本 | 用途 |
|---|---|---|
| MATLAB | R2023b | 主计算平台 |
| COMSOL Multiphysics | 6.2 | 正演/伴随求解 |
| LiveLink for MATLAB | 匹配 6.2 | MATLAB ↔ COMSOL 通信 |
| Python | 3.10+ | API 层 |
| pytest | 7.0+ | 单元测试 |
| 物理内存 | ≥ 32 GB | 支撑 19268 体素 PARDISO/MUMPS 求解 |

`comsolmphserver.exe` 路径和 `mli/` 路径通过 `ForwardPipeline.__init__` 显式传入，SDK 不做路径猜测。

## 与现有代码的关系

| 现有资产 | 关系 |
|---|---|
| [Z_workspace/phantom-constrained-inverse-scattering/scripts/](../../../Z_workspace/phantom-constrained-inverse-scattering/scripts) | **沉淀源**，5 个 .m 脚本 SHA-256 已验证一致 |
| [z-workspace/default/scripts/run_forward_pipeline.m](../../../z-workspace/default/scripts/run_forward_pipeline.m) | **编排参考**，SDK 版基于此适配 |
| [engine/sdk/sdk.py](../sdk.py) | **格式契约 SDK**（管 ROUTER.json 格式），与业务资产 SDK 职责正交 |
| [apps/phantom-constrained-inverse-scattering/](../../../apps/phantom-constrained-inverse-scattering) | 完全不动，后续重构时改为调用本 SDK |

## 单元测试

```bash
# 项目根目录
set PYTHONPATH=.
python -m pytest engine/sdk/forward_pipeline/tests/ -v
```

测试矩阵（无需真实 COMSOL/MATLAB）：

| 文件 | 覆盖范围 |
|---|---|
| `test_cache.py` | 哈希一致性、缓存命中/失效、原子写入、clear |
| `test_matlab_runner.py` | params.json 序列化、exit.flag 读取、超时清理、日志写入 |
| `test_api.py` | 参数校验、缓存命中分支、失败路径、伴随完整流程 |

`test_smoke.py` 标记为 `@pytest.mark.slow`，需真实 COMSOL 环境，默认不在 CI 中跑。

## 接入示例（未来 phantom-constrained-inverse-scattering 重构方向）

```python
from engine.sdk.forward_pipeline import ForwardPipeline

# 在 R2a/R2b 角色脚本中
pipe = ForwardPipeline(
    comsol_server_path=env.COMSOL_SERVER,
    mli_path=env.MLI_PATH,
    matlab_exe=env.MATLAB_EXE,
)

result = pipe.solve_forward(
    eps_real_csv=app_config.eps_real_csv,
    eps_imag_csv=app_config.eps_imag_csv,
    freq_list=app_config.freq_list,
    model_path=app_config.model_path,
    output_dir=app_config.output_dir,
)

if result.status == "success" or result.status == "cached":
    # 直接用 result.mat_path 喂给反演算法
    pass
```

R2a/R2b 退化为"SDK 调用者"，不再背负"管线构建者"职责。

## 版本管理

- `SDK_VERSION`（当前 `1.0.0`）参与缓存哈希，升级即失效所有旧缓存
- `SDK_VERSION` 与 [engine/sdk/sdk.py](../sdk.py) 的 `SDK_VERSION`（当前 `2.0`，管 ROUTER 格式）独立
- MATLAB 资产变更需在 commit message 中记录 SHA-256 变化
