% MATLAB batch script: 执行步骤 3-5 FD 标定 + 凸区域验证
% 需要 COMSOL Server 运行中（端口 2036）

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir, 'config'), ...
        fullfile(pipline_dir, 'utils'), ...
        fullfile(pipline_dir, 'core_jobs'), ...
        fullfile(pipline_dir, 'core_jhyp'), ...
        fullfile(pipline_dir, 'core_forward'), ...
        fullfile(pipline_dir, 'algorithm'), ...
        fullfile(pipline_dir, 'experiment'));

addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  步骤 3-5: FD 标定 + 凸区域多点验证\n');
fprintf('#  需要 COMSOL Server (端口 2036)\n');
fprintf('############################################################\n\n');

% 凸区域测试点: p(t) = p_init + t*(p_true - p_init)
p_init = [3.0; 0; 0; 0];
p_true_vec = [5.0; 0.03; 0.02; 0.01];
dp_true = p_true_vec - p_init;
t_values = [0.5];  % 先跑 t=0.5 一个点，确认修正效果

% 存储所有结果
all_g_FD = [];
all_g_adj = [];
all_cos = [];
all_ratio_mean = [];
all_ratio_cv = [];
all_dp_dot = [];
all_coeff_rec = [];

for ti = 1:length(t_values)
    t = t_values(ti);
    pt = p_init + t * dp_true;
    fprintf('\n=========================================================\n');
    fprintf('  测试点 t=%.1f: eps_r=%.2f, hole=[%.4f, %.4f, %.4f]\n', ...
        t, pt(1), pt(2), pt(3), pt(4));
    fprintf('=========================================================\n');

    try
        r = diagnose_adjoint_vs_fd(pt(1), pt(2:4));
        all_cos = [all_cos, r.cos_vec];
        all_ratio_mean = [all_ratio_mean, r.ratio_mean];
        all_ratio_cv = [all_ratio_cv, r.ratio_cv];
        all_dp_dot = [all_dp_dot, r.gAdj_dot_dp];
        if ~isnan(r.coeff_base_rec)
            all_coeff_rec = [all_coeff_rec, r.coeff_base_rec];
        end
        fprintf('\n  >>> t=%.1f 完成: cos=%.4f, ratio_mean=%.4f, CV=%.4f, g·dp=%+.4e\n', ...
            t, r.cos_vec, r.ratio_mean, r.ratio_cv, r.gAdj_dot_dp);
    catch ME
        fprintf('\n  >>> t=%.1f FAILED: %s\n', t, ME.message);
        all_cos = [all_cos, NaN];
        all_ratio_mean = [all_ratio_mean, NaN];
        all_ratio_cv = [all_ratio_cv, NaN];
        all_dp_dot = [all_dp_dot, NaN];
    end
end

% 汇总
fprintf('\n\n############################################################\n');
fprintf('#  步骤 3-5 汇总\n');
fprintf('############################################################\n');
fprintf('#  各测试点 cos(g_FD, g_adj):\n');
for ti = 1:length(t_values)
    fprintf('#    t=%.1f: cos = %.6f  %s\n', t_values(ti), all_cos(ti), ...
        ternary(all_cos(ti)>0.95, '[PASS]', '[FAIL]'));
end
fprintf('#\n');
fprintf('#  各测试点 ratio 均值:\n');
for ti = 1:length(t_values)
    fprintf('#    t=%.1f: ratio_mean = %.6f, CV = %.6f  %s\n', ...
        t_values(ti), all_ratio_mean(ti), all_ratio_cv(ti), ...
        ternary(all_ratio_cv(ti)<0.1, '[CV PASS]', '[CV FAIL]'));
end
fprintf('#\n');
fprintf('#  凸区域方向判据 g·dp:\n');
for ti = 1:length(t_values)
    fprintf('#    t=%.1f: g·dp = %+.4e  %s\n', t_values(ti), all_dp_dot(ti), ...
        ternary(all_dp_dot(ti)>0, '[PASS]', '[FAIL]'));
end

if ~isempty(all_coeff_rec)
    fprintf('#\n');
    fprintf('#  coeff_base 推荐: %.6e\n', mean(all_coeff_rec));
    fprintf('#  (填入 build_adjoint_source_fullmaxwell.m 即完成标定)\n');
end

fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
save(fullfile(results_dir, 'step3_5_result.mat'), ...
    'all_cos', 'all_ratio_mean', 'all_ratio_cv', 'all_dp_dot', 'all_coeff_rec', 't_values');

function s = ternary(cond, a, b)
    if cond, s = a; else, s = b; end
end
