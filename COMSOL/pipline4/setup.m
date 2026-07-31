function setup()
%SETUP pipline4 路径初始化（MATLAB 会话启动时运行一次）
%
%   用法：
%     >> cd COMSOL/pipline4
%     >> setup()
%     >> verify_fd_complex    % 主验证：FD sign + ratio（需 COMSOL）

this_dir = fileparts(mfilename('fullpath'));

addpath(fullfile(this_dir, 'config'));
addpath(fullfile(this_dir, 'utils'));
addpath(fullfile(this_dir, 'core_forward'));
addpath(fullfile(this_dir, 'core_probe'));
addpath(fullfile(this_dir, 'core_adjoint'));
addpath(fullfile(this_dir, 'experiment'));

% COMSOL LiveLink
comsol_mli = 'D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli';
if exist(comsol_mli, 'dir')
    addpath(comsol_mli);
end

fprintf('[setup] pipline4 路径已配置\n');
fprintf('  可用命令:\n');
fprintf('    verify_fd_complex      — FD sign + ratio（主验证，需 COMSOL）\n');
fprintf('    verify_lambda_residual — K·λ 残差检查（需 COMSOL）\n');
fprintf('    p = config()           — 查看配置参数\n');

end
