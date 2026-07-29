function build_and_verify_R13()
% 在管线3中构建R=0.13模型并运行verify_per_voxel
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint','experiment');

p = config();
fprintf('\n=== R_inner=%.2f, R_air=%.2f, R_sphere=%.2f ===\n\n', p.R_inner, p.R_air, p.R_sphere);

%% 1. 连接 COMSOL Server
mphstart(2036);

%% 2. 构建模型
fprintf('=== Building model ===\n');
model = build_lightweight_model(p);
model.save(fullfile(p.base_path, '2layer.mph'));
fprintf('OK saved 2layer.mph\n');

%% 3. 运行 verify_per_voxel
fprintf('\n=== Running verify_per_voxel(30) ===\n');
result = verify_per_voxel(30);

fprintf('\n=== FINAL RESULT ===\n');
fprintf('sign_rate = %.1f%%\n', 100*result.sign_rate);
fprintf('cos_theta = %.6f\n', result.cos_theta);
