function check_bg_internal()
%CHECK_BG_INTERNAL 检查两个模型中背景场内部变量的实际值

this_dir = fileparts(mfilename('fullpath'));
pipeline_dir = fileparts(this_dir);
cd(pipeline_dir);
addpath('config','utils');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  背景场内部变量检查\n');
fprintf('#  点 (0.07, 0, 0)\n');
fprintf('############################################################\n\n');

obs_pt = [0.07; 0; 0];

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart\n'); return;
    end
end

%% 检查函数
check_vars = {'emw.Ebx', 'emw.Eby', 'emw.Ebz', ...
              'emw.bEz', 'emw.Eb', ...
              'emw.Ebz', 'emw.E0z', ...
              'emw.Ex', 'emw.Ey', 'emw.Ez', ...
              'emw.relEx', 'emw.relEy', 'emw.relEz', ...
              'emw.Ebgz', 'emw.Ebzbg', 'emw.Ebz_bg'};

%% 1. 管线2
fprintf('===== 管线2 (2layer.mph) =====\n');
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
try phys2.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model2.param.set('adjoint_mode', '1'); catch, end
model2.param.set('freq', num2str(p.freq));
try model2.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end

% eps_r=1
try phys2.feature('wee1').set('epsilonr_mat', 'userdef'); catch, end
try phys2.feature('wee1').set('epsilonr', '1'); catch, end

try model2.sol('sol1').clearSolutionData(); catch, end
try model2.sol('sol1').clearSolution(); catch, end
try
    s1 = model2.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
    end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end
model2.sol('sol1').runAll();

fprintf('\n变量值:\n');
for vi = 1:length(check_vars)
    vn = check_vars{vi};
    try
        val = mphinterp(model2, vn, 'coord', obs_pt);
        fprintf('  %-16s = %.6e (real=%.6e, imag=%.6e)\n', vn, abs(val), real(val), imag(val));
    catch
        fprintf('  %-16s = N/A\n', vn);
    end
end

%% 2. 主管线
fprintf('\n===== 主管线 (livelink_model.mph) =====\n');
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

model1 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
try model1.geom('geom1').run; catch, end
try model1.mesh('mesh1').run; catch, end

phys1 = model1.physics('emw');
try phys1.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model1.param.set('adjoint_mode', '1'); catch, end
model1.param.set('freq', num2str(p.freq));
try model1.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end

% eps_r=1
try phys1.feature('wee1').set('epsilonr_mat', 'userdef'); catch, end
try phys1.feature('wee1').set('epsilonr', '1'); catch, end

try model1.sol('sol1').clearSolutionData(); catch, end
try model1.sol('sol1').clearSolution(); catch, end
try
    s1 = model1.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
    end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end
model1.sol('sol1').runAll();

fprintf('\n变量值:\n');
for vi = 1:length(check_vars)
    vn = check_vars{vi};
    try
        val = mphinterp(model1, vn, 'coord', obs_pt);
        fprintf('  %-16s = %.6e (real=%.6e, imag=%.6e)\n', vn, abs(val), real(val), imag(val));
    catch
        fprintf('  %-16s = N/A\n', vn);
    end
end

fprintf('\n############################################################\n');

% 清理
try ModelUtil.remove('Model'); catch, end

end
