# 实验日志 — H001_TV_lambda

| 字段 | 值 |
|------|-----|
| exp_id | H001_TV_lambda |
| hypothesis_id | H001 |
| 假设范围 | regularization.TV_lambda (0.001 → 1e-4) |
| git_commit | f3b8bc3074c32f4fce9d2fadfa4d5fcd4505f706 |
| git_tag | exp_H001_TV_lambda |
| M2 diff | `algorithm/plugin_a12/run_inversion.m` L21 `p.lambda_tv` 默认值 0.001 → 1e-4（未提交，工作区生效） |
| 执行时间 | 2026-07-22 22:59 → 23:05 |
| verdict | **fail**（阶段二反演崩溃；根因为 latent 基础设施缺陷，非 M2 H001 改动所致） |

---

## 环境前置检查

| 检查项 | 结果 |
|--------|------|
| COMSOL mphserver localhost:2036 | ✅ TcpTestSucceeded = True |
| MATLAB exe 存在 | ✅ D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe |
| pipline config.m 存在 | ✅ |
| exp_id 查重 | ✅ H001_TV_lambda 全局唯一（已存在 exp_H001_FullMaxwell，不同维度） |
| M2 diff 就位 | ✅ git status: ` M algorithm/plugin_a12/run_inversion.m`；L21 确认为 `p.lambda_tv = 1e-4` |
| git tag | ✅ exp_H001_TV_lambda → f3b8bc3 |

---

## 阶段一：正演管线完整性验证（verify_forward_pipeline）

**命令**：
```powershell
cd "d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline"
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "addpath('config','experiment'); verify_forward_pipeline"
```
**耗时**：约 90 秒（含 MATLAB 冷启动）。**原始 stdout**：`forward_result/phase1_stdout.txt`。

### 关键指标
| 指标 | 值 | 判据 | 结论 |
|------|----|------|------|
| cos θ (mean) | **0.995568** | > 0.99 | ✅ PASS |
| cos θ (min) | 0.931554 | — | — |
| cos θ (max) | 0.999986 | — | — |
| \|J_obs\|/\|J_hyp\| ratio (mean) | **0.9844** | ≈ 1.0（±2% 内） | ✅ PASS |
| V5a max F_k | 2.239e-02 | < 1e-3 | ⚠️ WARN（Born 近似固有偏差，强散射体 eps_r=5 预期，非管线 bug） |
| Gauss/centroid ratio | 1.0044 | ≈ 1.0 | ✅ 场光滑 |

### 物理尺度校验
- ka = k0·a = 20.9585 × 0.1300 = **2.7246**
- λ = 0.2998 m = 30.0 cm
- 散射体直径 = 0.2600 m，diameter/λ = 0.87（Mie 区间）
- 19268 tet 总数，673 内层体素（3.5%）

### 阶段一结论
**PASS**。cos θ > 0.99 且 ratio ≈ 1.0，正演管线未被破坏，准予进入阶段二。
> 注：verify_forward_pipeline 内部用 eps_r=3.0 做正演健全性测试（Path A=COMSOL J_obs vs Path B=Born J_hyp），仅诊断正演管线一致性，不涉及反演；阶段二 run_experiment 才会用 eps_r=5.0 真值。

---

## 阶段二：执行 M2 改动过的反演代码（run_experiment('plugin_a12')）

**命令**：
```powershell
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "addpath('config','experiment'); run_experiment('plugin_a12')"
```
**耗时**：约 110 秒后崩溃。**原始 stdout**：`inverse_result/phase2_stdout.txt`。

### 已成功执行的步骤
| run_experiment 步骤 | 结果 |
|---------------------|------|
| Step 0 初始化 | ✅ pipline root 已识别，plugin=plugin_a12 |
| Step 1 COMSOL LiveLink | ✅ mphstart(2036) + mphload 成功 |
| Step 2 fem_mesh_utils | ✅ 19268 tet，673 inner |
| Step 3 设真值 eps_r | ✅ inner eps_r=5.0 |
| Step 4 solve_forward (1 GHz) | ✅ \|E\| mean=5.0734e-01 |
| Step 5 J_obs (surface equiv) | ✅ \|J_obs\| mean=1.9256e-04，64 k-dir |
| Step 6 加载 plugin_a12 | ✅ addpath 成功 |
| plugin_a12 B-spline 算子构建 | ✅ 10×10×2=200 控制点，PoU 修复后 mean=1.000000，9.20 MB sparse |
| plugin_a12 3 频 J_obs 预计算 | ✅ 1 GHz / 2 GHz / 3 GHz 三频正演+J_obs 全部完成 |
| A12_inversion_loop 启动 | ✅ 打印 `lambda_TV=0.0001`（**M2 改动已生效，证明 lambda_tv=1e-4 实际生效**） |
| A12_inversion_loop L49 写 CSV 日志 | ❌ **崩溃** |

### 崩溃点与堆栈
```
出错 A12_inversion_loop (第 49 行)
    log_path = fullfile(p.dir_result_A12, 'A12_inversion_log.csv');
出错 run_inversion (第 51 行)
    state = A12_inversion_loop(voxel, lc, J_obs_perp_multi, freqs, grid, model, p, B_op, c_init);
出错 run_experiment (第 97 行)
    state = run_inversion(model, voxel, lc, grid, p);

matlab.exe : 无法识别的字段名称 "dir_result_A12"。
ERROR: MATLAB error Exit Status: 0x00000001
```

### 根因诊断（执行者定位，供 M2/M6 修复）

**缺陷类型**：plugin_a12 入口脚本基础设施缺陷（infrastructure），**不属于 M2 本轮 H001 声明维度**（regularization.TV_lambda）。

**证据链**：
1. `A12_inversion_loop.m` L49 引用 `p.dir_result_A12`；`A12_postprocess.m` L6 同样引用。
2. 全仓 grep `dir_result_A12` 共 7 处：消费方 2 处（inversion_loop / postprocess），提供方 1 处（`A12_multi_freq_inversion.m` L35-38）：
   ```matlab
   p.dir_result_A12 = fullfile(p.dir_result, 'A12');
   if ~exist(p.dir_result_A12, 'dir'), mkdir(p.dir_result_A12); end
   ```
3. **plugin 入口 `algorithm/plugin_a12/run_inversion.m` 在 L51 调用 `A12_inversion_loop(...)` 之前未设置 `p.dir_result_A12`**，故 `run_experiment('plugin_a12')` 路径必崩。
4. `config.m` 全文（125 行）无 `dir_result_A12` 字段。
5. M2 本轮 diff 仅触及 `run_inversion.m` L21（`p.lambda_tv` 默认值），未触及 L48 附近的目录设置；modification_log 第 4 条目明确写操作范围限定 L21。

**结论**：此为 plugin 架构自引入以来的 latent 缺陷——独立脚本 `A12_multi_freq_inversion.m` 因自带 `p.dir_result_A12` 设置而从未暴露此问题，但 plugin 化重构（commit f3b8bc3 "plugin architecture"）未把目录初始化逻辑迁入 `run_inversion.m`。

**重要旁证**：崩溃前 stdout 明确打印 `lambda_TV=0.0001`（见 `A12_inversion_loop` L18），**证明 M2 的 H001 改动（0.001→1e-4）已被正确加载并实际生效**——实验在进入反演迭代（lambda_tv 起作用的环节）之前的目录设置阶段就崩溃了，与 lambda_tv 数值无关。即使 lambda_tv 保持 0.001 基线值，本崩溃同样会发生。

### 修复建议（供 M2 或 M6 接手，不在本角色执行范围内）
在 `algorithm/plugin_a12/run_inversion.m` L51 调用 `A12_inversion_loop` 之前补：
```matlab
if ~isfield(p, 'dir_result_A12')
    p.dir_result_A12 = fullfile(p.dir_result, 'A12');
    if ~exist(p.dir_result_A12, 'dir'), mkdir(p.dir_result_A12); end
end
```
此修复属 plugin 入口基础设施补全，建议作为独立 hypothesis（infrastructure 类）或 maintenance 条目记录，不混入 H001。

---

## verdict 判定（首次跑 commit f3b8bc3）

**fail**

依据 verdict 判定规则第 5 行："阶段二反演未运行或崩溃 → fail"。

**为何不擅自补丁**：
- 本角色（实验执行者）职责是把"M2 的 diff + 配置"驱动为可复现实验，**不修改算法/插件代码**（M2/M6 域）。
- git tag `exp_H001_TV_lambda` 已绑定 commit `f3b8bc3`；若擅自改 `run_inversion.m` 加入目录设置，则实验结果对应代码版本与 tag 不符，**破坏可复现性**（违反 skill.md 原则 1）。
- 此缺陷属 plugin_a12 入口基础设施，与 H001 声明的 regularization.TV_lambda 维度无关，应作为独立修复条目，不应隐式并入 H001 实验记录。

**M2 的 H001 改动（L21 lambda_tv）本身已验证生效**（stdout 打印 `lambda_TV=0.0001`），但被前置基础设施缺陷阻断，无法产出反演三件套数据。

---

## 重跑（commit 7269fed — plugin_a12 基础设施已修复）

| 字段 | 值 |
|------|-----|
| git_commit | 7269fedfa9c14be00167f4a40061947c4bf526f3 |
| git_tag | exp_H001_TV_lambda（强制重指：f3b8bc3 → 7269fed）✅ |
| 修复内容 | plugin_a12/run_inversion.m L25-28 补 `dir_result_A12` 守卫；L29-30 设 max_iter=10 + eps_tol=1e-6 |
| M2 H001 diff | L21 `p.lambda_tv = 1e-4`（commit 7269fed 内已生效，工作区无未提交算法 diff） |
| 执行时间 | 2026-07-22 23:48 → 23:52 |
| verdict | **fail**（mphserver 在阶段一执行后崩溃，阶段二 mphstart Connection refused；3 次重连 5s 间隔全部失败） |

### 环境前置检查（重跑）

| 检查项 | 结果 |
|--------|------|
| COMSOL mphserver localhost:2036（dispatch 时） | ✅ TcpTestSucceeded=True |
| MATLAB exe 存在 | ✅ |
| git HEAD | ✅ 7269fed |
| git status (algorithm) | ✅ 空（算法文件全部已 commit，仅 data/results/ 两个 mph/csv artifact 变更） |
| git tag | ✅ exp_H001_TV_lambda → 7269fed（已重指） |
| plugin_a12 修复核验 | ✅ run_inversion.m L21=1e-4；L25-28 dir_result_A12 守卫；L29-30 max_iter/eps_tol |

---

### 阶段一（重跑）：正演管线完整性验证 ✅ PASS

**命令**：
```powershell
cd "d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline"
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "addpath('config','experiment'); verify_forward_pipeline"
```
**耗时**：约 60 秒（mphserver 已热）。**原始 stdout**：`forward_result/phase1_stdout.txt`（已覆盖）。

| 指标 | 值 | 判据 | 结论 |
|------|----|------|------|
| cos θ (mean) | **0.995568** | > 0.99 | ✅ PASS |
| cos θ (min) | 0.931554 | — | — |
| \|J_obs\|/\|J_hyp\| ratio (mean) | **0.9844** | ≈ 1.0 | ✅ PASS |
| V5a max F_k | 2.239e-02 | < 1e-3 | ⚠️ WARN（Born 近似固有偏差，eps_r=5 强散射预期） |
| Gauss/centroid ratio | 1.0044 | ≈ 1.0 | ✅ 场光滑 |
| 19268 tet / 673 inner voxel | — | — | ✅ 网格一致 |

**阶段一结论**：PASS。数值与首次跑完全一致（cos θ=0.995568 / ratio=0.9844），确认 commit 7269fed 的 plugin_a12 修复未触及正演管线（写操作仅限 algorithm/plugin_a12/run_inversion.m，正演路径未变）。准予进入阶段二。

---

### 阶段二（重跑）：执行 run_experiment('plugin_a12') ❌ BLOCKED

**命令**：
```powershell
cd "d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline"
& "D:\LenovoSoftstore\Install\MATLAB\bin\matlab.exe" -batch "addpath('config','experiment'); run_experiment('plugin_a12')"
```

**崩溃点**：MATLAB 冷启动加载后 `run_experiment` Step 1 `mphstart(p.comsol_port)` 立即失败，未进入任何 plugin_a12 代码路径。

**完整 stderr**：
```
=== Step 1: COMSOL LiveLink ===
matlab.exe : 错误使用 mphstart
A connection to COMSOL could not be established. Please check that a COMSOL
server is started prior to calling mphstart
mphstart (0): Java exception occurred:
Exception:
        java.net.ConnectException: Connection refused: no further information
        (rethrown as com.comsol.util.exceptions.FlException)
Messages:
        Failed to connect to server
        Connection refused: no further information
出错 run_experiment (第 50 行)
    mphstart(p.comsol_port);
ERROR: MATLAB error Exit Status: 0x00000001
```

**重连策略**（按 skill 手册 §5）：3 次重试，每次间隔 5 秒，全部 `TcpTestSucceeded=False`（IPv4 127.0.0.1 与 IPv6 ::1 均拒绝连接）。

### 根因诊断

**缺陷类型**：环境基础设施失败（mphserver 崩溃），**不属于 M2 H001 声明维度**（regularization.TV_lambda），**不属于 M6 修复范围**（commit 7269fed 的 plugin_a12 修复在阶段一已证明无副作用）。

**证据链**：
1. dispatch 注入状态：`COMSOL mphserver localhost:2036：✅ 运行中` —— 实验启动时 mphserver 可达。
2. 阶段一 verify_forward_pipeline 完整跑通 10 步，最后打印 `[verify_forward_pipeline] model saved to results/`，COMSOL LiveLink 全程正常。
3. 阶段一 MATLAB 进程退出后，端口 2036 TCP 探测立即 `False`（IPv4+IPv6 全拒绝），表明 mphserver 进程已死亡（非空闲）。
4. 阶段二 MATLAB 冷启动后 mphstart Java 异常 `ConnectException: Connection refused`，与 TCP 探测一致。
5. 3 次重试（间隔 5s）全部失败 → skill 规则：报告 `E_MPH_UNREACHABLE` 并判 `fail`。

**为何 mphserver 死亡**（推测，不在本角色执行域内验证）：
- COMSOL mphserver 在 MATLAB 进程异常断开（如 `-batch` 模式 MATLAB 退出时未 mphexit）时可能崩溃，属已知行为。
- 也可能 dispatch 时报告的 "运行中" 是基于历史状态而非实时探测。

**重要旁证**：阶段二在进入 plugin_a12 任何代码（包括 L21 的 lambda_tv=1e-4 改动）**之前**就崩溃了。M2 的 H001 改动本轮完全未被执行，但阶段一已证明 commit 7269fed 的算法路径未被破坏。

### 修复建议（供 dispatch / 用户接手）

在独立终端启动 COMSOL mphserver（不要由本角色自动启动，违反 skill 手册 §1）：
```powershell
& "D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\bin\win64\comsolmphserver.exe" -port 2036
```
启动后再次 dispatch 本任务即可。git tag `exp_H001_TV_lambda` → 7269fed 已就位，config_snapshot.json 已更新，无需重做阶段一（结果与上次完全一致）。

---

## verdict 判定（重跑 commit 7269fed）

**fail**

依据 verdict 判定规则："mphserver 不可达且重连耗尽 → fail"。

**与首次 fail 的区别**：
- 首次 fail：阶段二进入反演迭代前因 plugin_a12 入口 `dir_result_A12` 缺失崩溃 → 代码层缺陷 → M2/M6 已修复（commit 7269fed）。
- 本次 fail：阶段二 mphstart 立即崩溃 → 环境层 mphserver 死亡 → **可恢复**，重启 mphserver 即可继续。
- **plugin_a12 修复（commit 7269fed）已被阶段一旁证有效**（正演管线未破坏），但阶段二 plugin_a12 入口（含修复）本轮未被实际执行（mphstart 先于插件加载失败）。

**M2 的 H001 改动本轮未被验证**（lambda_tv=1e-4 路径未进入），需在 mphserver 恢复后重跑确认。

---

## 产出物清单（重跑）
- `config_snapshot.json` — 物理参数七字段 + hypothesis_id + git_commit_hash (7269fed) + git_tag ✅
- `forward_result/phase1_stdout.txt` — 阶段一完整 stdout（重跑，已覆盖；cos θ=0.995568 PASS）✅
- `inverse_result/phase2_stdout.txt` — 阶段二完整 stdout（含 mphstart ConnectException 堆栈）✅
- `log.md` — 本文件 ✅
- `inverse_result/` — （无反演三件套产出：mphstart 阶段崩溃，未进入 plugin_a12 反演代码）
