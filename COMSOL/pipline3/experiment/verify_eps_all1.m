function verify_eps_all1()
%VERIFY_EPS_ALL1 验证 update_epsilon 后 COMSOL 中每个体素的 eps_r 是否真的都是1

this_dir = fileparts(mfilename('fullpath'));
pipeline_dir = fileparts(this_dir);
cd(pipeline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  验证 eps_r=1 是否真的注入成功\n');
fprintf('############################################################\n\n');

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL]\n'); return;
    end
end

p = config();

for mi = 1:2
    if mi == 1
        fprintf('===== 管线2 (2layer.mph) =====\n');
        try
            tags = ModelUtil.tags();
            for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
        catch
        end
        model = mphload(p.comsol_model_path);
        mname = '2layer';
    else
        fprintf('\n===== 主管线 (livelink_model.mph) =====\n');
        try
            tags = ModelUtil.tags();
            for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
        catch
        end
        model = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
        mname = 'livelink';
    end
    
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
    N_v = length(voxel.epsilon_r);
    inner = voxel.mask_interior;
    N_inner = sum(inner);
    
    % 全部设为 1
    voxel.epsilon_r(:) = 1.0;
    fprintf('  MATLAB 端: voxel.epsilon_r min=%.4f max=%.4f mean=%.4f\n', ...
        min(voxel.epsilon_r), max(voxel.epsilon_r), mean(voxel.epsilon_r));
    
    update_epsilon(model, voxel, p);
    
    % 必须 runAll 才能刷新插值缓存
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    model.param.set('freq', num2str(p.freq));
    try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end
    try
        s1 = model.sol('sol1').feature('s1');
        try s1.feature('dDirect'); catch
            s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
        end
        try s1.feature('fc1').set('linsolver','dDirect'); catch, end
    catch
    end
    model.sol('sol1').runAll();
    fprintf('  runAll 完成（缓存已刷新）\n');
    
    % 查询所有体素质心处的 eps_r
    % 管线2 用 int1，主管线也用 int1（update_epsilon 统一写入）
    int_vals = zeros(N_v, 1);
    int2_vals = zeros(N_v, 1);
    for vi = 1:N_v
        pt = voxel.pos(vi, :)';
        try
            int_vals(vi) = real(mphinterp(model, 'int1(x,y,z)', 'coord', pt));
        catch
            int_vals(vi) = NaN;
        end
    end
    
    fprintf('\n  COMSOL int1 查询结果:\n');
    fprintf('    总体素: %d\n', N_v);
    fprintf('    int1 min=%.4f, max=%.4f, mean=%.4f\n', ...
        min(int_vals), max(int_vals), mean(int_vals));
    fprintf('    int1 == 1.0 的点: %d / %d\n', sum(abs(int_vals - 1.0) < 1e-6), N_v);
    fprintf('    int1 != 1.0 的点: %d / %d\n', sum(abs(int_vals - 1.0) >= 1e-6), N_v);
    
    if any(abs(int_vals - 1.0) >= 1e-6)
        fprintf('    ★ 有 %d 个体素的 int1 != 1.0!\n', sum(abs(int_vals - 1.0) >= 1e-6));
        bad_idx = find(abs(int_vals - 1.0) >= 1e-6);
        fprintf('    前 10 个异常点:\n');
        for bi = 1:min(10, length(bad_idx))
            vi = bad_idx(bi);
            fprintf('      #1: pos=[%.4f,%.4f,%.4f], int1=%.4f, inner=%d\n', ...
                voxel.pos(vi,1), voxel.pos(vi,2), voxel.pos(vi,3), int_vals(vi), inner(vi));
        end
    else
        fprintf('    ★ 所有体素 int1 = 1.0，注入完全正确\n');
    end
    
    % 同时查 wee1 的表达式
    try
        expr = char(phys.feature('wee1').getString('epsilonr'));
        fprintf('    wee1.epsilonr 表达式 = %s\n', expr);
    catch
    end
end

fprintf('\n############################################################\n');

try ModelUtil.remove('Model'); catch, end

end
