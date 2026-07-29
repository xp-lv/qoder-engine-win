function check_eps_timing()
%CHECK_EPS_TIMING 验证 update_epsilon 后、solve 前后的 int1 值

this_dir = fileparts(mfilename('fullpath'));
pipeline_dir = fileparts(this_dir);
cd(pipeline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  插值函数时序验证\n');
fprintf('############################################################\n\n');

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL]\n'); return;
    end
end

try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

p = config();
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);

% 找一个内部体素质心
test_idx = inner_idx(1);
test_pos = voxel.pos(test_idx, :)';
fprintf('测试点（内部体素质心）: [%.4f, %.4f, %.4f], eps_r=%.1f\n', ...
    test_pos(1), test_pos(2), test_pos(3), 5.0);

%% Step 1: update_epsilon 之前
fprintf('\n--- Step 1: update_epsilon 之前 ---\n');
try
    val = mphinterp(model, 'int1(x,y,z)', 'coord', test_pos);
    fprintf('  int1 = %.4f\n', real(val));
catch
    fprintf('  int1 查询失败（可能未创建）\n');
end

%% Step 2: update_epsilon 之后
fprintf('\n--- Step 2: update_epsilon 之后 ---\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
try
    val = mphinterp(model, 'int1(x,y,z)', 'coord', test_pos);
    fprintf('  int1 = %.4f (期望 5.0)\n', real(val));
catch
    fprintf('  int1 查询失败\n');
end

%% Step 3: 重新 run geom + mesh 之后
fprintf('\n--- Step 3: 重新 run geom + mesh 之后 ---\n');
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end
try
    val = mphinterp(model, 'int1(x,y,z)', 'coord', test_pos);
    fprintf('  int1 = %.4f (期望 5.0)\n', real(val));
catch
    fprintf('  int1 查询失败\n');
end

%% Step 4: clearSolution + runAll 之后
fprintf('\n--- Step 4: clearSolution + runAll 之后 ---\n');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
try
    val = mphinterp(model, 'int1(x,y,z)', 'coord', test_pos);
    fprintf('  int1 = %.4f (期望 5.0)\n', real(val));
catch
    fprintf('  int1 查询失败\n');
end

%% Step 5: 直接查体素位置数组中的实际值
fprintf('\n--- Step 5: 直接查 COMSOL func 的 table 数据 ---\n');
try
    % 尝试读取 int1 的表数据
    func1 = model.component('comp1').func('int1');
    tbl = func1.getTable();
    fprintf('  int1 表行数: %d\n', size(tbl, 1));
    fprintf('  int1 前 5 行:\n');
    for ri = 1:min(5, size(tbl,1))
        fprintf('    [%+.4f, %+.4f, %+.4f] = %.2f\n', tbl(ri,1), tbl(ri,2), tbl(ri,3), tbl(ri,4));
    end
    % 找测试点最近的行
    dists = sqrt(sum((tbl(:,1:3) - test_pos').^2, 2));
    [min_dist, min_idx] = min(dists);
    fprintf('  最近数据点 #1: dist=%.6f, val=%.2f\n', min_dist, tbl(min_idx, 4));
catch ME
    fprintf('  getTable 失败: %s\n', ME.message);
end

%% Step 6: 用体素质心点直接查
fprintf('\n--- Step 6: 直接用 voxel.pos 中的点查询 ---\n');
pos_query = voxel.pos(test_idx, :)';
try
    val = mphinterp(model, 'int1(x,y,z)', 'coord', pos_query);
    fprintf('  int1(voxel_pos) = %.4f (期望 5.0)\n', real(val));
catch
    fprintf('  查询失败\n');
end

fprintf('\n############################################################\n');

try ModelUtil.remove('Model'); catch, end

end
