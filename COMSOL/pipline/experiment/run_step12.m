% MATLAB batch script: 执行步骤 1-2 纯数学验证
% 不需要 COMSOL，~2 秒完成
% 必须从 pipline 目录运行（test 函数内部 addpath 用相对路径）

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);  % 上一级 = pipline/
cd(pipline_dir);
addpath(fullfile(pipline_dir, 'config'), ...
        fullfile(pipline_dir, 'utils'), ...
        fullfile(pipline_dir, 'core_jobs'), ...
        fullfile(pipline_dir, 'core_jhyp'), ...
        fullfile(pipline_dir, 'core_forward'), ...
        fullfile(pipline_dir, 'experiment'));

fprintf('\n=========================================================\n');
fprintf('  步骤 1/5: 矩阵级内积测试\n');
fprintf('=========================================================\n');

try
    ratio1 = test_adjoint_matrix();
    if abs(ratio1 - 1) < 1e-10
        fprintf('\n>>> 步骤 1 [PASS] ratio = %.15f + %.15fi\n', real(ratio1), imag(ratio1));
        step1_pass = true;
    else
        fprintf('\n>>> 步骤 1 [FAIL] ratio = %.6e + %.6ei\n', real(ratio1), imag(ratio1));
        step1_pass = false;
    end
catch ME
    fprintf('\n>>> 步骤 1 [FAIL] %s\n', ME.message);
    step1_pass = false;
end

fprintf('\n=========================================================\n');
fprintf('  步骤 2/5: 算子级自验证\n');
fprintf('=========================================================\n');

try
    ratio2 = test_adjoint_correctness();
    if abs(ratio2 - 1) < 1e-10
        fprintf('\n>>> 步骤 2 [PASS] ratio = %.15f + %.15fi\n', real(ratio2), imag(ratio2));
        step2_pass = true;
    else
        fprintf('\n>>> 步骤 2 [FAIL] ratio = %.6e + %.6ei\n', real(ratio2), imag(ratio2));
        step2_pass = false;
    end
catch ME
    fprintf('\n>>> 步骤 2 [FAIL] %s\n', ME.message);
    step2_pass = false;
end

fprintf('\n=========================================================\n');
fprintf('  步骤 1-2 汇总\n');
fprintf('=========================================================\n');
fprintf('  步骤 1 (矩阵级): %s\n', ternary(step1_pass, '[PASS]', '[FAIL]'));
fprintf('  步骤 2 (算子级): %s\n', ternary(step2_pass, '[PASS]', '[FAIL]'));
if step1_pass && step2_pass
    fprintf('  >>> 伴随算子结构 A = L^H 验证通过（数学精确）\n');
else
    fprintf('  >>> 伴随算子结构存在 bug，需修复\n');
end

% 保存结果
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir, 'dir'), mkdir(results_dir); end
save(fullfile(results_dir, 'step1_2_result.mat'), 'step1_pass', 'step2_pass', 'ratio1', 'ratio2');

function s = ternary(cond, a, b)
    if cond, s = a; else, s = b; end
end
