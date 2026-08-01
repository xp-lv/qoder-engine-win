function fix_intop1_selection()
% 修复 intop1 的域选择为内部域，然后保存为新 mph

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

mphstart(2036);
try; ts=ModelUtil.tags(); for i=1:length(ts), ModelUtil.remove(char(ts(i))); end; catch; end

model = mphload('2layer_sensitive.mph');
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end

% 修改 intop1 域选择为内部域
fprintf('设置 intop1 域选择为 [9 10 11 12 13 18 19 22 23]...\n');
model.component('comp1').cpl('intop1').selection.set([9 10 11 12 13 18 19 22 23]);
fprintf('  OK\n');

% 验证
try
    sel = model.component('comp1').cpl('intop1').selection();
    s = sel.set();
    fprintf('  intop1 selection = %s\n', mat2str(s));
catch
    fprintf('  无法读取（可能是 all）\n');
end

% 删除旧 solver
try model.sol.remove('sol1'); catch; end

% 运行 study
fprintf('\n运行 study.run...\n');
try
    model.study('std1').run;
    fprintf('  study.run OK!\n');
    
    % 提取灵敏度
    sr = mphglobal(model, 'fsens(eps_re_ctrl)');
    si = mphglobal(model, 'fsens(eps_im_ctrl)');
    fprintf('  fsens(eps_re_ctrl) = %+.6e\n', sr);
    fprintf('  fsens(eps_im_ctrl) = %+.6e\n', si);
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

% 保存
fprintf('\n保存为 2layer_sensitive_fixed.mph...\n');
try
    model.save('2layer_sensitive_fixed.mph');
    fprintf('  保存成功\n');
catch ME
    fprintf('  保存失败: %s\n', ME.message);
end

try ModelUtil.remove('Model'); catch; end
end
