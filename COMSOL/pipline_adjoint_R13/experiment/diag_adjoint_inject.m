% 诊断伴随源注入是否生效
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint');
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');

try mphstart(2036); catch, end
p = config();
model = mphload('2layer.mph');
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

% 创建 vec1
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
end
try phys.feature('vec1').selection().all(); catch, end

% 检查 vec1 的 selection
fprintf('\n===== vec1 诊断 =====\n');
try
    sel = phys.feature('vec1').selection();
    fprintf('selection set: %s\n', mat2str(sel.set()));
    fprintf('selection isempty: %d\n', sel.isEmpty());
catch ME
    fprintf('selection 检查失败: %s\n', ME.message);
end

% 检查 vec1 Je 当前值
try
    Je_val = phys.feature('vec1').getString('Je');
    for i = 1:length(Je_val)
        fprintf('Je(%d) = %s\n', i, char(Je_val(i)));
    end
catch ME
    fprintf('Je 读取失败: %s\n', ME.message);
end

% 检查 adjoint_mode 是否影响背景场
fprintf('\n===== 背景场诊断 =====\n');
try
    Eb_val = phys.prop('BackgroundField').getString('Eb');
    for i = 1:length(Eb_val)
        fprintf('Eb(%d) = %s\n', i, char(Eb_val(i)));
    end
catch ME
    fprintf('Eb 读取失败: %s\n', ME.message);
end

% 设置 adjoint_mode=0 看背景场是否变化
model.param.set('adjoint_mode', '0');
fprintf('adjoint_mode = 0\n');
try
    Eb_val2 = phys.prop('BackgroundField').getString('Eb');
    for i = 1:length(Eb_val2)
        fprintf('Eb(%d) = %s (adjoint_mode=0)\n', i, char(Eb_val2(i)));
    end
catch
end

% 正演求解一次
fprintf('\n===== 正演求解 =====\n');
model.param.set('freq', '1e9');
try model.study('std1').feature('freq').set('plist', '1e9[Hz]'); catch, end
model.sol('sol1').runAll();

grid = build_measurement_grid(p);
voxel = fem_mesh_utils(model, p, p.a_scatter);
inner = voxel.mask_interior;
inner_pos = voxel.pos(inner, :);

[E_total, ~] = read_field(model, inner_pos);
fprintf('E_total: |mean|=%.6e\n', mean(vecnorm(E_total, 2, 2)));

% 现在注入一个简单的测试源（非零 Je）
fprintf('\n===== 注入测试源 =====\n');
Je_test = {'1e3', '0', '0'};  % 简单的非零值
phys.feature('vec1').set('Je', Je_test);
fprintf('vec1 Je 设为测试值: %s\n', strjoin(Je_test, ', '));

% 归零背景场（手动）
fprintf('手动归零背景场...\n');
phys.prop('BackgroundField').set('Eb', [0 0 0]);

% 重新求解
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

% 提取 lambda_test
[lambda_test, ~] = read_field(model, inner_pos);
fprintf('lambda_test (Je=[1e3,0,0], Eb=0): |mean|=%.6e\n', mean(vecnorm(lambda_test, 2, 2)));

if abs(mean(vecnorm(lambda_test, 2, 2)) - mean(vecnorm(E_total, 2, 2))) < 1e-10
    fprintf('\n*** lambda_test == E_total！vec1 注入完全无效！***\n');
    fprintf('可能原因: vec1 selection 未设置到任何域\n');
else
    fprintf('\n*** lambda_test != E_total，vec1 注入有效！***\n');
    fprintf('差异 = %.6e\n', ...
        mean(vecnorm(lambda_test, 2, 2)) - mean(vecnorm(E_total, 2, 2)));
end

% 恢复
phys.feature('vec1').set('Je', {'0', '0', '0'});
phys.prop('BackgroundField').set('Eb', [0 0 1]);
