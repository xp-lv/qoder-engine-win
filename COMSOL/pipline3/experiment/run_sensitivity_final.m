function run_sensitivity_final()
% 用 comp1.intop1 前缀运行完整灵敏度分析

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

mphstart(2036);
try; ts=ModelUtil.tags(); for i=1:length(ts), ModelUtil.remove(char(ts(i))); end; catch; end

model = mphload('2layer_sensitive.mph');
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end

% 设置完整目标函数（用 comp1 前缀！）
obj_expr = 'comp1.intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';

fprintf('设置目标函数（comp1.intop1 前缀）...\n');
try model.sol.remove('sol1'); catch; end

% 关键: 设置 epsilonr = eps_re_ctrl + i*eps_im_ctrl（全局参数控制）
fprintf('设置 wee1.epsilonr = eps_re_ctrl + i*eps_im_ctrl...\n');
phys = model.physics('emw');
try
    phys.feature('wee1').set('epsilonr_mat', 'userdef');
    phys.feature('wee1').set('epsilonr', {'eps_re_ctrl + i*eps_im_ctrl'});
    fprintf('  OK wee1.epsilonr set\n');
catch ME
    fprintf('  wee1 FAIL: %s\n', ME.message);
end

model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);

fprintf('运行 study.run...\n');
try
    model.study('std1').run;
    fprintf('  OK!\n');
    
    sr = mphglobal(model, 'fsens(eps_re_ctrl)');
    si = mphglobal(model, 'fsens(eps_im_ctrl)');
    fprintf('  fsens(eps_re_ctrl) = %+.6e\n', sr);
    fprintf('  fsens(eps_im_ctrl) = %+.6e\n', si);
    
    % 保存
    model.save('2layer_sensitive_v2.mph');
    fprintf('  保存为 2layer_sensitive_v2.mph\n');
    
    %% FD 对比
    fprintf('\n=== FD 对比 ===\n');
    addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
    p = config();
    voxel = fem_mesh_utils(model, p, p.R_inner);
    inner = voxel.mask_interior; inner_idx = find(inner);
    dV = voxel.dV(inner_idx);
    
    % 加载真值场
    tmp = dlmread('Et_x_re.csv'); Etx = tmp(:,4);
    tmp = dlmread('Et_x_im.csv'); Etx = Etx + 1i*tmp(:,4);
    tmp = dlmread('Et_y_re.csv'); Ety = tmp(:,4);
    tmp = dlmread('Et_y_im.csv'); Ety = Ety + 1i*tmp(:,4);
    tmp = dlmread('Et_z_re.csv'); Etz = tmp(:,4);
    tmp = dlmread('Et_z_im.csv'); Etz = Etz + 1i*tmp(:,4);
    E_truth = [Etx, Ety, Etz];
    
    fd = 0.01;
    
    % FD re: eps_re+δ
    model.param.set('eps_re_ctrl', '3.1');
    model.param.set('eps_im_ctrl', '-1');
    try model.sol.remove('sol1'); catch; end
    model.sol.create('sol1'); model.sol('sol1').study('std1'); model.sol('sol1').attach('std1');
    model.sol('sol1').runAll;
    [Ep,~,~] = solve_forward(model, voxel, p);
    F_re_p = sum(dV .* sum(abs(Ep - E_truth).^2, 2));
    
    % FD re: eps_re-δ
    model.param.set('eps_re_ctrl', '2.9');
    try model.sol('sol1').clearSolution(); catch; end
    model.sol('sol1').runAll;
    [Em,~,~] = solve_forward(model, voxel, p);
    F_re_m = sum(dV .* sum(abs(Em - E_truth).^2, 2));
    g_fd_re = (F_re_p - F_re_m) / (2*fd);
    
    % FD im
    model.param.set('eps_re_ctrl', '3');
    model.param.set('eps_im_ctrl', '-0.9');
    try model.sol('sol1').clearSolution(); catch; end
    model.sol('sol1').runAll;
    [Ep,~,~] = solve_forward(model, voxel, p);
    F_im_p = sum(dV .* sum(abs(Ep - E_truth).^2, 2));
    
    model.param.set('eps_im_ctrl', '-1.1');
    try model.sol('sol1').clearSolution(); catch; end
    model.sol('sol1').runAll;
    [Em,~,~] = solve_forward(model, voxel, p);
    F_im_m = sum(dV .* sum(abs(Em - E_truth).^2, 2));
    g_fd_im = (F_im_p - F_im_m) / (2*fd);
    
    fprintf('\n############################################################\n');
    fprintf('  re: sens=%+.6e  FD=%+.6e  ratio=%+.4f  %s\n', ...
        sr, g_fd_re, sr/g_fd_re, ts(sr*g_fd_re>0));
    fprintf('  im: sens=%+.6e  FD=%+.6e  ratio=%+.4f  %s\n', ...
        si, g_fd_im, si/g_fd_im, ts(si*g_fd_im>0));
    fprintf('############################################################\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

try ModelUtil.remove('Model'); catch; end
end
