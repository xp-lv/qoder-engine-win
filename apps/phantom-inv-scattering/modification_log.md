# 修改日志

<!-- M2 算法实现者和 M6 管线优化者在此追加修改条目 -->
<!-- 格式：[时间戳] hypothesis/maintenance: ID -->
<!--        - files: 文件路径 -->
<!--        - summary: 改动摘要 -->
<!--        - type: algorithm/performance/correctness/infrastructure -->

[2026-07-22T10:30:00] hypothesis: H001
- files:
    - <pipline>/core_jhyp/compute_jhyp.m
    - <pipline>/core_inversion/inversion_loop.m
    - <pipline>/core_adjoint/linesearch.m
- summary: 将 J_hyp 等效源模型从 Born 近似切换为 COMSOL 全波计算（source.model: born -> full_maxwell）。三处 Born 路径调用点全部改为 compute_jhyp_comsol（COMSOL mphint2 FEM 体积 Gauss 积分 + 横向投影）：① compute_jhyp.m 入口调度器改为全波分发（签名 voxel,E_total,lc,p -> model,lc,p）；② inversion_loop.m Step ② 由 equivalent_source+lightcone_hyp 质心求和改为 compute_jhyp_comsol(model,lc,p)；③ linesearch.m 的 compute_cost_fast 由 Born 链改为 compute_jhyp_comsol，仅空 model 降级保留 Born 以维持正交维度（COMSOL 可用性）原行为不变。A12/C01 反演循环不在此假设声明维度内（其已使用测量球面表面等效路径，非 Born 链），未改动。
- type: algorithm
- dimensions: source.model (born -> full_maxwell)
- expected_effect: cos θ 0.9929 -> >=0.9949, F_cheb 0.091 -> <=0.080, A12/C01 PASS 项数提升

[2026-07-22T14:05:00] hypothesis: H001 (re-verification)
- files:
    - <pipline>/core_jhyp/compute_jhyp.m
    - <pipline>/core_jhyp/compute_jhyp_comsol.m
    - <pipline>/core_inversion/inversion_loop.m
    - <pipline>/core_adjoint/linesearch.m
- summary: 本轮 M2 复核 H001 实现状态。上一轮已将 source.model 从 Born 切换为 COMSOL 全波，代码已在初始 commit 中就位（git status 仅 data/results/*.mph 变更，算法文件无未提交 diff）。逐文件确认：① compute_jhyp.m L22 分发至 compute_jhyp_comsol，Born 链已移出主路径；② inversion_loop.m L108 Step② 直接调用 compute_jhyp_comsol(model,lc,p)，不再走 equivalent_source+lightcone_hyp 质心求和；③ linesearch.m compute_cost_fast 正常路径走 compute_jhyp_comsol，仅 model 为空时降级保留 Born（属 COMSOL 可用性维度，不触及 source.model 声明维度）；④ compute_jhyp_comsol.m 实现就绪（mphint2 intorder=4 Gauss 积分，J_eq=-iω(D-ε₀E)，散射体体积滤波+横向投影）。副作用核查：A12/C01 循环未改动（走测量球面表面等效路径，非 Born 链）；equivalent_source.m/lightcone_hyp.m 文件保留未删（仅降级兜底）。写操作范围限定在 core_jhyp/ + core_adjoint/ + core_inversion/。结论：代码 diff 精确覆盖假设声明的 source.model 维度，无未声明副作用，实现可交付 M3 执行实验。
- type: algorithm
- dimensions: source.model (born -> full_maxwell) — verified, no drift
- verdict: confirmed (no new code change required; prior implementation intact)

[2026-07-22T16:40:00] hypothesis: H001 (re-verification round 3 — INCONCLUSIVE follow-up)
- files:
    - <pipline>/core_jhyp/compute_jhyp.m
    - <pipline>/core_jhyp/compute_jhyp_comsol.m
    - <pipline>/core_inversion/inversion_loop.m
    - <pipline>/core_adjoint/linesearch.m
- summary: 本轮 M2 在 H001 verdict=INCONCLUSIVE（实验只跑正演未跑 Born vs Full Maxwell 成对反演）后再次复核 pipline 算法代码状态。git status 对 core_jhyp/ core_adjoint/ core_inversion/ algorithm/ 四目录返回空（无未提交 diff），表明上一轮实现已稳定就位、无漂移。逐文件复核：① compute_jhyp.m L22 `J_hyp = compute_jhyp_comsol(model, lc, p)` — 入口调度器走 Full Maxwell，Born 链 (equivalent_source+lightcone_hyp) 已移出主路径；② inversion_loop.m L105-108 Step② 注释+调用 `compute_jhyp_comsol(model, lc, p)` — 反演主循环直接全波，不再走质心求和；③ linesearch.m L123-140 compute_cost_fast 正常路径走 compute_jhyp_comsol，仅 model 为空（COMSOL 不可用）时降级 Born（属 COMSOL 可用性维度，非 source.model 声明维度）；④ compute_jhyp_comsol.m 实现就绪（mphint2 intorder=4 Gauss 积分，J_eq=-iω(D-ε₀E)，散射体球体积滤波 + transverse_project 横向投影）。副作用核查（Grep equivalent_source|lightcone_hyp 全仓）：主算法路径无残留 Born 调用；仅 experiment/verify_forward_pipeline{,_nonuniform}.m 的 Path B 诊断脚本保留 Born 链（用于 Born/FullMaxwell 对比诊断，非反演主路径，符合 M4 分析 note）。A12/C01 反演循环未改动（走测量球面表面等效路径，非 Born 链）。写操作范围限定在 core_jhyp/ + core_adjoint/ + core_inversion/。结论：H001 代码 diff 精确覆盖假设声明的 source.model (born->full_maxwell) 维度，无未声明副作用，无代码漂移。INCONCLUSIVE 不源于代码实现缺陷，而源于实验设计（需补跑同 eps_r=5.0 条件下 Born vs Full Maxwell 完整反演成对实验）。代码已就位可直接交付 M3 补跑实验。
- type: algorithm
- dimensions: source.model (born -> full_maxwell) — verified round 3, no drift, no new code change
- verdict: confirmed (prior implementation intact; INCONCLUSIVE attributed to experiment design, not implementation)

[2026-07-22T18:00:00] hypothesis: H001 (current scope: regularization.TV_lambda)
- files:
    - <pipline>/algorithm/plugin_a12/run_inversion.m
- summary: 本轮 M2 按 hypothesis_chain.json 当前 H001 statement（lambda_tv 0.001→1e-4）实现代码 diff。单点改动：plugin_a12/run_inversion.m L21 默认值 `p.lambda_tv = 0.001` → `p.lambda_tv = 1e-4`（`if ~isfield(p, 'lambda_tv')` 守卫不变，仅默认值）。改动前已核查 config/config.m 全文，确认 config 未设置 p.lambda_tv（仅设置 p.inversion_plugin='plugin_a12'），故插件内默认值即为 M3 经 run_experiment('plugin_a12') 调用时实际生效值，修改有效。预期效果：加权 TV 梯度与数据项梯度模长比 lambda_tv·‖g_tv‖/‖g_data‖ 从约 8.3 降至约 0.83（10× 衰减），数据项主导下降方向，缓解 iter 2-10 全部 Armijo rejected 的反演停滞。副作用核查：未触动 A12_multi_freq_inversion.m（旧版独立脚本，非插件入口，不在声明维度内）、未触动 A12_inversion_loop.m（消费 p.lambda_tv，无需改）、未触动 config.m/plugin_c01/plugin_basic（写操作限定 algorithm/plugin_a12/）。diff 精确覆盖声明维度 regularization.TV_lambda，无未声明副作用。
- type: algorithm
- dimensions: regularization.TV_lambda (0.001 -> 1e-4)
- expected_effect: ratio 8.3 -> ~0.83; A12 PASS 5/7 -> >=6/7; F_cheb 0.091 -> <=0.080
- verdict: confirmed

[2026-07-23T09:00:00] hypothesis: H001 (current scope: bspline.n_cz)
- files:
    - <pipline>/algorithm/plugin_a12/run_inversion.m
- summary: 本轮 M2 按 hypothesis_chain.json 当前 H001 statement（bspline n_cz 2→5）实现代码 diff。单点改动：plugin_a12/run_inversion.m L19 默认值 `p.n_cz = 2` → `p.n_cz = 5`（`if ~isfield(p, 'n_cz')` 守卫不变，仅默认值）。改动前已核查：① config/config.m 全文未设置 p.n_cz（仅设置 p.inversion_plugin='plugin_a12'），故插件内默认值即为 M3 经 run_experiment('plugin_a12') 调用时实际生效值，修改有效；② exp07a_bspline_param.m L36 已有 `p.n_cz = 5` 默认值，但因 plugin_a12/run_inversion.m 在调用 exp07a_bspline_param 前先行设值 p.n_cz，插件内 p.n_cz 优先级更高，故改动 plugin_a12/run_inversion.m 即可。总控制点数 10×10×2=200 → 10×10×5=500，三次 B-spline (bspline_order=3) 在 z 方向获得 5 个控制点（超过最小需求 degree+1=4）。副作用核查：未触动 A12_inversion_loop.m（消费 p.n_cz 经 B_op 间接传入，无需改）、未触动 exp07a_bspline_param.m（默认值已为 5）、未触动 config.m/plugin_c01/plugin_basic（写操作限定 algorithm/plugin_a12/）。diff 精确覆盖声明维度 bspline.n_cz，无未声明副作用。
- type: algorithm
- dimensions: bspline.n_cz (2 -> 5)
- expected_effect: z方向控制点 2→5（总 200→500）; A12 PASS 5/7 -> >=6/7; F_cheb 0.091 -> <=0.080
- verdict: confirmed
