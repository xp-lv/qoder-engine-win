function verify_adjoint_precision()
%VERIFY_ADJOINT_PRECISION 伴随法精确性完整五步验证主脚本
%
%   ★ 用法：在 MATLAB 命令行执行 ★
%     >> cd COMSOL/pipline/experiment
%     >> verify_adjoint_precision
%
%   自动执行全部 5 步验证，给出 PASS/FAIL 总判定：
%     步骤 1: 矩阵级内积测试（纯数学，~1秒）
%     步骤 2: 算子级自验证（纯数学，~1秒）
%     步骤 3: 参数级 FD 对比（需 COMSOL，~3分钟/点）
%     步骤 4: coeff_base 自动标定（从步骤 3 结果反推）
%     步骤 5: 凸区域多点方向验证（需 COMSOL，步骤 3 的子集）
%
%   判定标准（全部满足才算精确）：
%     - 步骤 1-2: ratio = 1 ± 1e-10（机器精度）
%     - 步骤 3:   cos(g_FD, g_adj) > 0.95
%     - 步骤 3:   ratio CV < 0.1（恒定性，非漂移）
%     - 步骤 5:   g · (p_true - p_init) > 0 在所有测试点

    fprintf('\n');
    fprintf('############################################################\n');
    fprintf('#       伴随法精确性五步验证                                #\n');
    fprintf('#       verify_adjoint_precision.m                         #\n');
    fprintf('############################################################\n\n');

    overall_pass = true;
    step_results = struct();

    %% ====== 步骤 1: 矩阵级内积测试 ======
    fprintf('========== 步骤 1/5: 矩阵级内积测试 ==========\n');
    fprintf('  原理: <L(x), y> == <x, L^H y>  (ratio 应 = 1, 机器精度)\n');
    fprintf('  依赖: 纯 MATLAB 矩阵运算，不需 COMSOL\n\n');

    addpath('config', 'utils', 'core_jobs', 'core_jhyp', 'core_forward');

    try
        ratio1 = test_adjoint_matrix();
        step_results.step1 = ~isnan(ratio1) && abs(ratio1 - 1) < 1e-10;
        if step_results.step1
            fprintf('\n  >>> 步骤 1 结果: [PASS] (ratio = %.15f)\n', ratio1);
        else
            overall_pass = false;
            fprintf('\n  >>> 步骤 1 结果: [FAIL] (ratio = %.6e, 需 |ratio-1|<1e-10)\n', ratio1);
        end
    catch ME
        step_results.step1 = false;
        overall_pass = false;
        fprintf('\n  >>> 步骤 1 结果: [FAIL] %s\n', ME.message);
    end
    fprintf('=============================================\n\n');

    %% ====== 步骤 2: 算子级自验证 ======
    fprintf('========== 步骤 2/5: 算子级自验证 ==========\n');
    fprintf('  原理: build_adjoint_source 输出 vs L^H dJ  (ratio 应 = 1)\n');
    fprintf('  依赖: 纯 MATLAB 矩阵运算，不需 COMSOL\n\n');

    try
        ratio2 = test_adjoint_correctness();
        step_results.step2 = ~isnan(ratio2) && abs(ratio2 - 1) < 1e-10;
        if step_results.step2
            fprintf('\n  >>> 步骤 2 结果: [PASS] (ratio = %.15f)\n', ratio2);
        else
            overall_pass = false;
            fprintf('\n  >>> 步骤 2 结果: [FAIL] (ratio = %.6e, 需 |ratio-1|<1e-10)\n', ratio2);
        end
    catch ME
        step_results.step2 = false;
        overall_pass = false;
        fprintf('\n  >>> 步骤 2 结果: [FAIL] %s\n', ME.message);
    end
    fprintf('=============================================\n\n');

    %% ====== 步骤 3-5: 需要 COMSOL ======
    fprintf('========== 步骤 3-5: FD 标定 + 凸区域验证 ==========\n');
    fprintf('  依赖: 需要 COMSOL Server 运行中\n');
    fprintf('  耗时: ~3 分钟/测试点（8 次 COMSOL 正演 + 1 次伴随）\n\n');

    % 检查 COMSOL 是否可用
    comsol_available = false;
    try
        p = config();
        mphstart_err = '';
        try
            mphstart(p.comsol_port);
            comsol_available = true;
        catch ME_inner
            if contains(ME_inner.message, 'Already connected')
                comsol_available = true;
            else
                mphstart_err = ME_inner.message;
            end
        end
        if ~comsol_available
            fprintf('  [WARN] COMSOL Server 不可用: %s\n', mphstart_err);
            fprintf('  跳过步骤 3-5。\n');
            fprintf('  请启动 COMSOL Server 后重新运行此脚本。\n\n');
        end
    catch
        fprintf('  [WARN] 无法加载 config，跳过步骤 3-5。\n\n');
    end

    if ~comsol_available
        % 仅输出步骤 1-2 结果
        fprintf('\n############################################################\n');
        fprintf('#  部分验证结果（步骤 1-2）                                  #\n');
        fprintf('############################################################\n');
        if step_results.step1 && step_results.step2
            fprintf('#  步骤 1-2 全部 PASS：伴随算子结构 = L^H（数学精确）         #\n');
            fprintf('#  步骤 3-5 待 COMSOL 环境下运行                              #\n');
        else
            fprintf('#  步骤 1-2 有 FAIL：伴随算子结构有 bug，需先修复             #\n');
        end
        fprintf('############################################################\n');
        return;
    end

    %% 凸区域多测试点定义
    % p(t) = p_init + t*(p_true - p_init)
    % p_init = [3.0; 0; 0; 0], p_true = [5.0; 0.03; 0.02; 0.01]
    p_init = [3.0; 0; 0; 0];
    p_true_vec = [5.0; 0.03; 0.02; 0.01];
    t_values = [0.3, 0.5, 0.7];
    dp_true = p_true_vec - p_init;

    test_points = struct();
    for ti = 1:length(t_values)
        t = t_values(ti);
        pt = p_init + t * dp_true;
        test_points(ti).t = t;
        test_points(ti).eps_r = pt(1);
        test_points(ti).hole_pos = pt(2:4);
        test_points(ti).label = sprintf('t=%.1f (eps=%.1f, hole=[%.3f,%.3f,%.3f])', ...
            t, pt(1), pt(2), pt(3), pt(4));
    end

    %% 逐点运行 FD 诊断
    multi_results = cell(1, length(test_points));

    for ti = 1:length(test_points)
        fprintf('\n--- 测试点 %d/%d: %s ---\n', ti, length(test_points), test_points(ti).label);

        try
            r = diagnose_adjoint_vs_fd(test_points(ti).eps_r, test_points(ti).hole_pos);
            multi_results{ti} = r;
        catch ME
            fprintf('  [ERROR] 诊断失败: %s\n', ME.message);
            multi_results{ti} = struct('criteria_pass', 0, 'criteria_total', 0, ...
                'cos_vec', NaN, 'ratio_mean', NaN, 'ratio_cv', NaN, ...
                'gAdj_dot_dp', NaN);
        end
    end

    %% ====== 步骤 4: coeff_base 汇总 ======
    fprintf('\n\n========== 步骤 4: coeff_base 标定汇总 ==========\n');

    all_ratios = [];
    all_cos = [];
    all_cv = [];
    all_dp = [];
    coeff_recs = [];

    for ti = 1:length(multi_results)
        r = multi_results{ti};
        if isnan(r.ratio_mean), continue; end
        all_ratios = [all_ratios, r.ratio_mean];
        all_cos = [all_cos, r.cos_vec];
        all_cv = [all_cv, r.ratio_cv];
        all_dp = [all_dp, r.gAdj_dot_dp];
        if ~isnan(r.coeff_base_rec)
            coeff_recs = [coeff_recs, r.coeff_base_rec];
        end
    end

    if ~isempty(all_ratios)
        fprintf('  跨测试点 ratio 统计:\n');
        fprintf('    各点 ratio_mean = %s\n', mat2str(all_ratios, 6));
        fprintf('    全局 ratio mean = %.6f\n', mean(all_ratios));
        fprintf('    全局 ratio std  = %.6f\n', std(all_ratios));
        fprintf('    全局 ratio CV   = %.6f  (阈值 <0.1)\n', std(all_ratios)/abs(mean(all_ratios)));
        fprintf('\n  各点 cos(g_FD, g_adj):\n');
        fprintf('    %s\n', mat2str(all_cos, 6));
        fprintf('  各点 g_adj·dp:\n');
        fprintf('    %s\n', mat2str(all_dp, 4));

        if ~isempty(coeff_recs)
            fprintf('\n  coeff_base 推荐:\n');
            fprintf('    各点推荐值 = %s\n', mat2str(coeff_recs, 6));
            fprintf('    全局推荐 coeff_base_final = %.6e\n', mean(coeff_recs));
            fprintf('    推荐值一致性 CV = %.6f\n', std(coeff_recs)/abs(mean(coeff_recs)));
        end
    else
        fprintf('  无有效 ratio 数据\n');
    end

    %% ====== 步骤 5: 凸区域方向验证 ======
    fprintf('\n\n========== 步骤 5: 凸区域方向验证 ==========\n');

    all_dp_positive = true;
    for ti = 1:length(multi_results)
        r = multi_results{ti};
        status = '[PASS]';
        if isnan(r.gAdj_dot_dp) || r.gAdj_dot_dp <= 0
            all_dp_positive = false;
            status = '[FAIL]';
        end
        fprintf('  %s: g_adj·dp = %+.4e  %s\n', test_points(ti).label, r.gAdj_dot_dp, status);
    end
    if all_dp_positive
        fprintf('\n  >>> 步骤 5 结果: [PASS]（所有测试点 g·dp > 0）\n');
    else
        fprintf('\n  >>> 步骤 5 结果: [FAIL]（存在 g·dp ≤ 0 的点）\n');
        overall_pass = false;
    end

    %% ====== 总判定 ======
    fprintf('\n\n');
    fprintf('############################################################\n');
    fprintf('#                    总判定                                 #\n');
    fprintf('############################################################\n');

    % 汇总各步结果
    step1_pass = step_results.step1;
    step2_pass = step_results.step2;

    % 步骤 3: 所有点 cos > 0.95
    step3_pass = ~isempty(all_cos) && all(all_cos > 0.95);
    % 步骤 3 补充: ratio CV < 0.1（恒定性）
    step3_cv_pass = ~isempty(all_cv) && all(all_cv < 0.1);
    % 步骤 4: coeff_base 推荐值一致
    step4_pass = ~isempty(coeff_recs) && (std(coeff_recs)/abs(mean(coeff_recs))) < 0.15;
    step5_pass = all_dp_positive;

    fprintf('#  步骤 1 (矩阵级 ratio=1):       %s\n', pass_str(step1_pass));
    fprintf('#  步骤 2 (算子级 ratio=1):       %s\n', pass_str(step2_pass));
    fprintf('#  步骤 3 (cos > 0.95):           %s\n', pass_str(step3_pass));
    fprintf('#  步骤 3 (ratio CV < 0.1):       %s\n', pass_str(step3_cv_pass));
    fprintf('#  步骤 4 (coeff_base 一致):      %s\n', pass_str(step4_pass));
    fprintf('#  步骤 5 (凸区域 g·dp > 0):      %s\n', pass_str(step5_pass));
    fprintf('#                                                            #\n');

    if step1_pass && step2_pass && step3_pass && step3_cv_pass && step4_pass && step5_pass
        fprintf('#  ★★★★★ 伴随法验证通过：数学精确 ★★★★★\n');
        fprintf('#                                                            #\n');
        fprintf('#  结论：当前实现满足精确伴随法的全部数学判据。              #\n');
        if ~isempty(coeff_recs)
            fprintf('#  最终 coeff_base = %.6e\n', mean(coeff_recs));
            fprintf('#  （填入 build_adjoint_source_fullmaxwell.m 即完成标定）   #\n');
        end
    else
        fprintf('#  [FAIL] 伴随法验证未通过，需修复以下问题：                 #\n');
        if ~step1_pass, fprintf('#    - 步骤 1: 矩阵结构有误                                  #\n'); end
        if ~step2_pass, fprintf('#    - 步骤 2: 算子实现有误                                  #\n'); end
        if ~step3_pass, fprintf('#    - 步骤 3: 梯度方向偏差 (cos < 0.95)                     #\n'); end
        if ~step3_cv_pass, fprintf('#    - 步骤 3: ratio 漂移 (CV > 0.1) → 结构性 bug            #\n'); end
        if ~step4_pass, fprintf('#    - 步骤 4: coeff_base 推荐值不一致 → 结构性 bug          #\n'); end
        if ~step5_pass, fprintf('#    - 步骤 5: 凸区域方向判据失败                            #\n'); end
    end

    fprintf('############################################################\n');

    % 保存汇总
    summary = struct();
    summary.step1_pass = step1_pass;
    summary.step2_pass = step2_pass;
    summary.step3_cos_pass = step3_pass;
    summary.step3_cv_pass = step3_cv_pass;
    summary.step4_pass = step4_pass;
    summary.step5_pass = step5_pass;
    summary.all_ratios = all_ratios;
    summary.all_cos = all_cos;
    summary.all_cv = all_cv;
    if ~isempty(coeff_recs)
        summary.coeff_base_final = mean(coeff_recs);
    end
    save(fullfile('data', 'results', 'verify_adjoint_precision_summary.mat'), '-struct', 'summary');
    fprintf('\n[VERIFY] 汇总已保存: data/results/verify_adjoint_precision_summary.mat\n');

end

function s = pass_str(b)
    if b, s = '[PASS]'; else, s = '[FAIL]'; end
end
