function setup()
%SETUP pipline_adjoint 路径初始化（MATLAB 会话启动时运行一次）
%
%   用法：
%     >> cd COMSOL/pipline_adjoint
%     >> setup()
%     >> verify_matrix_level       % Layer 1: 矩阵级（无需 COMSOL）
%     >> result = run_fd_truth();  % Layer 2: FD vs 伴随（需 COMSOL）

this_dir = fileparts(mfilename('fullpath'));

addpath(fullfile(this_dir, 'config'));
addpath(fullfile(this_dir, 'utils'));
addpath(fullfile(this_dir, 'core_forward'));
addpath(fullfile(this_dir, 'core_jobs'));
addpath(fullfile(this_dir, 'core_jhyp'));
addpath(fullfile(this_dir, 'core_adjoint'));
addpath(fullfile(this_dir, 'experiment'));

% COMSOL LiveLink
comsol_mli = 'D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli';
if exist(comsol_mli, 'dir')
    addpath(comsol_mli);
end

fprintf('[setup] pipline_adjoint 路径已配置\n');
fprintf('  可用命令:\n');
fprintf('    verify_matrix_level  — Layer 1 矩阵级内积测试（无需 COMSOL）\n');
fprintf('    run_fd_truth         — Layer 2 FD vs 伴随梯度对比（需 COMSOL）\n');
fprintf('    p = config()         — 查看配置参数\n');

end
