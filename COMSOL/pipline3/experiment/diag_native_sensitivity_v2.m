function diag_native_sensitivity_v2()
%DIAG_NATIVE_SENSITIVITY_V2 COMSOL原生灵敏度（用 layer_sensitive.m 学到的 API）

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

p = config();

fprintf('\n############################################################\n');
fprintf('#  COMSOL 原生灵敏度分析 v2（正确 API）\n');
fprintf('############################################################\n\n');

%% 1. 加载模型
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[FAIL] mphstart\n'); return; end
end
try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end
phys = model.physics('emw');

%% 2. 提取体素信息
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);
inner_pos = voxel.pos(inner_idx, :);

%% 3. 加载真值场（从已导出的 CSV）
fprintf('加载真值场...\n');
Et_x_re = dlmread(fullfile(p.base_path, 'Et_x_re.csv')); Et_x_re_v = Et_x_re(:,4);
Et_x_im = dlmread(fullfile(p.base_path, 'Et_x_im.csv')); Et_x_im_v = Et_x_im(:,4);
Et_y_re = dlmread(fullfile(p.base_path, 'Et_y_re.csv')); Et_y_re_v = Et_y_re(:,4);
Et_y_im = dlmread(fullfile(p.base_path, 'Et_y_im.csv')); Et_y_im_v = Et_y_im(:,4);
Et_z_re = dlmread(fullfile(p.base_path, 'Et_z_re.csv')); Et_z_re_v = Et_z_re(:,4);
Et_z_im = dlmread(fullfile(p.base_path, 'Et_z_im.csv')); Et_z_im_v = Et_z_im(:,4);
E_truth = [Et_x_re_v+1i*Et_x_im_v, Et_y_re_v+1i*Et_y_im_v, Et_z_re_v+1i*Et_z_im_v];
fprintf('  |E_truth| mean=%.4e\n\n', mean(vecnorm(E_truth,2,2)));

%% 4. 设置插值函数（真值场）
fprintf('写入真值场插值函数...\n');
func_info = {'int3','int_Et_x_re',real(E_truth(:,1));
             'int4','int_Et_x_im',imag(E_truth(:,1));
             'int5','int_Et_y_re',real(E_truth(:,2));
             'int6','int_Et_y_im',imag(E_truth(:,2));
             'int7','int_Et_z_re',real(E_truth(:,3));
             'int8','int_Et_z_im',imag(E_truth(:,3))};
for fi = 1:size(func_info,1)
    fn_tag = func_info{fi,1};
    fn_name = func_info{fi,2};
    fn_vals = func_info{fi,3};
    try model.component('comp1').func(fn_tag); catch
        model.component('comp1').func.create(fn_tag, 'Interpolation');
    end
    model.component('comp1').func(fn_tag).set('funcname', fn_name);
    model.component('comp1').func(fn_tag).set('nargs', '3');
    model.component('comp1').func(fn_tag).set('source', 'table');
    try model.component('comp1').func(fn_tag).set('extrap', 'specific'); catch; end
    try model.component('comp1').func(fn_tag).set('constval', '0'); catch; end
    tmp = [tempname, '.csv'];
    dlmwrite(tmp, [inner_pos, fn_vals(:)]);
    model.component('comp1').func(fn_tag).importData(tmp);
    delete(tmp);
end
fprintf('  OK 真值场函数已写入\n');

%% 5. 创建积分算子 intop1
fprintf('创建积分算子...\n');
try
    model.component('comp1').cpl.create('intop1', 'Integration');
catch
    fprintf('  intop1 已存在\n');
end
model.component('comp1').cpl('intop1').selection.set([9 10 11 12 13 18 19 22 23]);  % 内球域
fprintf('  OK intop1 域选择\n');

% 运行几何让 intop1 生效
try model.component('comp1').geom('geom1').run; catch; end
try model.component('comp1').mesh('mesh1').run; catch; end

% 验证 intop1 可用
try
    model.param.set('test_intop', '1');
    model.sol('sol1').clearSolution();
    model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq));
    model.sol('sol1').runAll();
    test_val = mphglobal(model, 'intop1(1)');
    fprintf('  intop1(1) = %.4e (验证算子可用)\n', test_val);
catch ME
    fprintf('  intop1 验证: %s\n', ME.message);
end

%% 6. 设置全局参数（控制变量）
model.param.set('eps_re_ctrl', '3');
model.param.set('eps_im_ctrl', '-1');
fprintf('OK 控制变量: eps_re_ctrl=3, eps_im_ctrl=-1\n');

%% 7. 设置 ε_r = eps_re_ctrl + i*eps_im_ctrl（内部域）
% 当前模型的 wee1.epsilonr 用的是 int1+i*int2
% 需要改为用全局参数
try
    phys.feature('wee1').set('epsilonr_mat', 'userdef');
    phys.feature('wee1').set('epsilonr', 'eps_re_ctrl + i*eps_im_ctrl');
    fprintf('OK wee1.epsilonr = eps_re_ctrl + i*eps_im_ctrl\n');
catch ME
    fprintf('FAIL wee1: %s\n', ME.message);
end

%% 8. 创建 Sensitivity 节点（用 layer_sensitive.m 学到的 API）
fprintf('\n创建 Sensitivity 节点...\n');
try
    % 先删除已有的
    try model.study('std1').feature().remove('sens'); catch; end
    
    % 创建 Sensitivity study step
    model.study('std1').create('sens', 'Sensitivity');
    
    % 设置目标函数
    obj_expr = 'intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';
    model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);
    
    % 控制变量 1: eps_re_ctrl
    model.study('std1').feature('sens').setIndex('pname', 'eps_re_ctrl', 0);
    model.study('std1').feature('sens').setIndex('initval', 3, 0);
    model.study('std1').feature('sens').setIndex('scale', 1, 0);
    model.study('std1').feature('sens').setIndex('valuetype', 'real', 0);
    
    % 控制变量 2: eps_im_ctrl
    model.study('std1').feature('sens').setIndex('pname', 'eps_im_ctrl', 1);
    model.study('std1').feature('sens').setIndex('initval', -1, 1);
    model.study('std1').feature('sens').setIndex('scale', 1, 1);
    model.study('std1').feature('sens').setIndex('valuetype', 'real', 1);
    
    fprintf('  OK Sensitivity 节点已创建\n');
    
    % 重建 solver sequence（让 intop1 和 sens 生效）
    fprintf('  重建 solver sequence...\n');
    model.sol('sol1').clearSolution();
    try model.sol.remove('sol1'); catch; end
    model.sol.create('sol1');
    model.sol('sol1').study('std1');
    model.sol('sol1').attach('std1');
    model.sol('sol1').create('st1', 'StudyStep');
    model.sol('sol1').feature('st1').set('study', 'std1');
    model.sol('sol1').feature('st1').set('studystep', 'freq');
    model.sol('sol1').create('v1', 'Variables');
    model.sol('sol1').feature('v1').set('control', 'freq');
    model.sol('sol1').create('s1', 'Stationary');
    model.sol('sol1').feature('s1').set('stol', 0.01);
    model.sol('sol1').feature('s1').feature('aDef').set('complexfun', true);
    model.sol('sol1').feature('s1').create('fc1', 'FullyCoupled');
    model.sol('sol1').feature('s1').feature('fc1').set('linsolver', 'dDirect');
    model.sol('sol1').feature('s1').create('dDirect', 'Direct');
    model.sol('sol1').feature('s1').feature('dDirect').set('linsolver', 'pardiso');
    fprintf('  OK solver 重建完成\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
    return;
end

%% 9. 求解
fprintf('\n求解灵敏度...\n');
try
    model.sol('sol1').clearSolution();
    model.study('std1').run;
    fprintf('  OK 求解完成\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
    return;
end

%% 10. 提取灵敏度值
fprintf('\n提取灵敏度...\n');
try
    sens_re = mphglobal(model, 'fsens(eps_re_ctrl)');
    sens_im = mphglobal(model, 'fsens(eps_im_ctrl)');
    fprintf('  dQ/d(eps_re) = %+.6e\n', sens_re);
    fprintf('  dQ/d(eps_im) = %+.6e\n', sens_im);
catch ME
    fprintf('  FAIL fsens: %s\n', ME.message);
    % 尝试其他提取方式
    try
        fprintf('  尝试 mphinterp...\n');
        pt = [0;0;0];
        sens_re = mphinterp(model, 'fsens(eps_re_ctrl)', 'coord', pt);
        sens_im = mphinterp(model, 'fsens(eps_im_ctrl)', 'coord', pt);
        fprintf('  fsens(eps_re) at origin = %+.6e\n', sens_re(1));
        fprintf('  fsens(eps_im) at origin = %+.6e\n', sens_im(1));
    catch ME2
        fprintf('  mphinterp also failed: %s\n', ME2.message);
    end
end

%% 11. FD 对比
fprintf('\nFD 对比...\n');
fd_delta = 0.01;
dV = voxel.dV(inner_idx);

% FD re: eps_re+δ
model.param.set('eps_re_ctrl', '3.1');
model.param.set('eps_im_ctrl', '-1');
model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq));
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[Ep,~,~] = solve_forward(model, voxel, p);
F_re_p = sum(dV .* sum(abs(Ep - E_truth).^2, 2));

% FD re: eps_re-δ
model.param.set('eps_re_ctrl', '2.9');
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[Em,~,~] = solve_forward(model, voxel, p);
F_re_m = sum(dV .* sum(abs(Em - E_truth).^2, 2));
g_FD_re = (F_re_p - F_re_m) / (2*fd_delta);

% FD im: eps_im+δ
model.param.set('eps_re_ctrl', '3');
model.param.set('eps_im_ctrl', '-0.9');
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[Ep,~,~] = solve_forward(model, voxel, p);
F_im_p = sum(dV .* sum(abs(Ep - E_truth).^2, 2));

% FD im: eps_im-δ
model.param.set('eps_im_ctrl', '-1.1');
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[Em,~,~] = solve_forward(model, voxel, p);
F_im_m = sum(dV .* sum(abs(Em - E_truth).^2, 2));
g_FD_im = (F_im_p - F_im_m) / (2*fd_delta);

%% 12. 输出
fprintf('\n############################################################\n');
fprintf('#  COMSOL 原生灵敏度 vs FD（均匀 eps_r=3-1j）\n');
fprintf('############################################################\n');
fprintf('  实部: adjoint=%+.6e  FD=%+.6e  ratio=%+.4f  %s\n', ...
    sens_re, g_FD_re, sens_re/g_FD_re, ts(sens_re*g_FD_re>0));
fprintf('  虚部: adjoint=%+.6e  FD=%+.6e  ratio=%+.4f  %s\n', ...
    sens_im, g_FD_im, sens_im/g_FD_im, ts(sens_im*g_FD_im>0));
fprintf('############################################################\n');

%% 恢复
model.param.set('adjoint_mode','1');
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end

end

function s = ts(c), if c, s='OK'; else, s='XX'; end, end
