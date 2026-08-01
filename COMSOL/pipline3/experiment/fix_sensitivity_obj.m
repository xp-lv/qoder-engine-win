function fix_sensitivity_obj()
% 尝试不同的目标函数定义方式

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

mphstart(2036);
try; ts=ModelUtil.tags(); for i=1:length(ts), ModelUtil.remove(char(ts(i))); end; catch; end

model = mphload('2layer_sensitive.mph');
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end

% 删除旧 solver
try model.sol.remove('sol1'); catch; end

% 尝试方法1: 用全局变量定义目标函数
fprintf('方法1: 用全局变量定义目标函数\n');
try
    % 先定义全局变量 Q_obj = intop1(...)
    model.param.set('Q_obj', 'comp1.intop1((emw.Ex-(comp1.int_Et_x_re(x,y,z)+i*comp1.int_Et_x_im(x,y,z)))^2 + (emw.Ey-(comp1.int_Et_y_re(x,y,z)+i*comp1.int_Et_y_im(x,y,z)))^2 + (emw.Ez-(comp1.int_Et_z_re(x,y,z)+i*comp1.int_Et_z_im(x,y,z)))^2)');
    % 目标函数直接用全局变量
    model.study('std1').feature('sens').setIndex('optobj', 'Q_obj', 0);
    model.study('std1').run;
    fprintf('  OK!\n');
    sr = mphglobal(model, 'fsens(eps_re_ctrl)');
    fprintf('  fsens(eps_re_ctrl) = %+.6e\n', sr);
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

% 尝试方法2: 简化目标函数（不用 intop1，直接用一个简单表达式测试）
fprintf('\n方法2: 简化目标函数测试\n');
try
    model.sol.remove('sol1');
    model.study('std1').feature('sens').setIndex('optobj', 'intop1(emw.Ex^2 + emw.Ey^2 + emw.Ez^2)', 0);
    model.study('std1').run;
    fprintf('  OK!\n');
    sr = mphglobal(model, 'fsens(eps_re_ctrl)');
    fprintf('  fsens(eps_re_ctrl) = %+.6e\n', sr);
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

% 尝试方法3: 用最简目标函数（单点场值）
fprintf('\n方法3: 用全局变量 emw.Ex 在原点\n');
try
    model.sol.remove('sol1');
    model.study('std1').feature('sens').setIndex('optobj', 'comp1.intop1(emw.Ez)', 0);
    model.study('std1').run;
    fprintf('  OK!\n');
    sr = mphglobal(model, 'fsens(eps_re_ctrl)');
    fprintf('  fsens(eps_re_ctrl) = %+.6e\n', sr);
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

% 尝试方法4: 完全不用 intop1，用全局约简
fprintf('\n方法4: 不用 intop1，直接用表达式\n');
try
    model.sol.remove('sol1');
    % 用 emw.Ez 在某点的值作为目标函数（最简）
    model.study('std1').feature('sens').setIndex('optobj', 'emw.Ez', 0);
    model.study('std1').run;
    fprintf('  OK!\n');
    sr = mphglobal(model, 'fsens(eps_re_ctrl)');
    fprintf('  fsens(eps_re_ctrl) = %+.6e\n', sr);
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

try ModelUtil.remove('Model'); catch; end
end
