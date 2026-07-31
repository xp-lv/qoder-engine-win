function check_eps_effective()
%CHECK_EPS_EFFECTIVE 检查 update_epsilon 后插值函数在该点的实际值

this_dir = fileparts(mfilename('fullpath'));
pipeline_dir = fileparts(this_dir);
cd(pipeline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  插值函数实际值检查\n');
fprintf('#  在 (0.07, 0, 0) 和球心 (0,0,0) 处\n');
fprintf('############################################################\n\n');

pts = [0.07, 0, 0;   % 球外
       0, 0, 0;       % 球心
       0.03, 0, 0;   % 球内
       0, 0, 0.03];  % 球内
pt_labels = {'(0.07,0,0)球外', '(0,0,0)球心', '(0.03,0,0)球内', '(0,0,0.03)球内'};
obs_pts = pts';  % [3x4]

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart\n'); return;
    end
end

%% 管线2 — 用 update_epsilon 注入 eps_r=5
fprintf('===== 管线2 (2layer.mph): update_epsilon 注入 eps_r=5 =====\n');
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

p = config();
model2 = mphload(p.comsol_model_path);
try model2.geom('geom1').run; catch, end
try model2.mesh('mesh1').run; catch, end

phys2 = model2.physics('emw');
try phys2.feature('vec1'); catch
    phys2.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys2.feature('vec1').set('Je', {'0','0','0'});
    try phys2.feature('vec1').selection().all(); catch, end
end
try model2.param.set('adjoint_mode', '1'); catch, end

voxel2 = fem_mesh_utils(model2, p, p.R_inner);
inner2 = voxel2.mask_interior;
voxel2.epsilon_r(inner2) = 5.0;
update_epsilon(model2, voxel2, p);

% 查询插值函数的实际值
fprintf('\n  int1(x,y,z) 和 wee1.epsilonr 的实际值:\n');
for pi = 1:size(pts,1)
    pt = pts(pi,:)';
    try
        int1_val = mphinterp(model2, 'int1(x,y,z)', 'coord', pt);
    catch
        try int1_val = mphinterp(model2, 'comp1.int1(x,y,z)', 'coord', pt); catch, int1_val = NaN; end
    end
    try
        int2_val = mphinterp(model2, 'int2(x,y,z)', 'coord', pt);
    catch
        try int2_val = mphinterp(model2, 'comp1.int2(x,y,z)', 'coord', pt); catch, int2_val = NaN; end
    end
    fprintf('    %s: int1=%.4f, int2=%.4f, eps_r_expr=%.4f\n', ...
        pt_labels{pi}, real(int1_val), real(int2_val), real(int1_val)+1i*real(int2_val));
end

% 直接查 wee1 的表达式
try
    eps_expr = char(phys2.feature('wee1').getString('epsilonr'));
    fprintf('\n  wee1.epsilonr 表达式 = %s\n', eps_expr);
catch
end

%% 管线2 — 对比：直接设 epsilonr='5'（不走插值）
fprintf('\n----- 对比：直接设 epsilonr=''5'' (常数) -----\n');
try phys2.feature('wee1').set('epsilonr', '5'); catch, end
fprintf('  wee1.epsilonr 已设为常数 5\n');

%% 主管线 — 用 update_epsilon 注入 eps_r=5
fprintf('\n===== 主管线 (livelink_model.mph): update_epsilon 注入 eps_r=5 =====\n');
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

model1 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
try model1.geom('geom1').run; catch, end
try model1.mesh('mesh1').run; catch, end

phys1 = model1.physics('emw');
try phys1.feature('vec1'); catch
    phys1.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys1.feature('vec1').set('Je', {'0','0','0'});
    try phys1.feature('vec1').selection().all(); catch, end
end
try model1.param.set('adjoint_mode', '1'); catch, end

% 主管线用 p.a_scatter = 0.06（当前配置）
voxel1 = fem_mesh_utils(model1, p, p.R_inner);
inner1 = voxel1.mask_interior;
voxel1.epsilon_r(inner1) = 5.0;
update_epsilon(model1, voxel1, p);

fprintf('\n  int1/int2 和 wee1.epsilonr 的实际值:\n');
for pi = 1:size(pts,1)
    pt = pts(pi,:)';
    % 主管线用 int2/int3
    try
        int2_val = mphinterp(model1, 'int2(x,y,z)', 'coord', pt);
    catch
        try int2_val = mphinterp(model1, 'comp1.int2(x,y,z)', 'coord', pt); catch, int2_val = NaN; end
    end
    try
        int3_val = mphinterp(model1, 'int3(x,y,z)', 'coord', pt);
    catch
        try int3_val = mphinterp(model1, 'comp1.int3(x,y,z)', 'coord', pt); catch, int3_val = NaN; end
    end
    fprintf('    %s: int2=%.4f, int3=%.4f, eps_r=%.4f\n', ...
        pt_labels{pi}, real(int2_val), real(int3_val), real(int2_val)+1i*real(int3_val));
end

try
    eps_expr1 = char(phys1.feature('wee1').getString('epsilonr'));
    fprintf('\n  wee1.epsilonr 表达式 = %s\n', eps_expr1);
catch
end

fprintf('\n############################################################\n');

try ModelUtil.remove('Model'); catch, end

end
