function [g_re, g_im, F_val] = run_native_adjoint_field()
%RUN_NATIVE_ADJOINT_FIELD COMSOL原生伴随 + 控制变量场（逐节点梯度）
%
%   ε_r = eps_ctrl_re + i*eps_ctrl_im（控制变量场，域上分布）
%   初始值通过插值函数注入
%   Sensitivity 返回每个 FEM 节点的灵敏度（fsens 场）
%
%   输出:
%       g_re   逐节点 dQ/d(eps_re) 灵敏度场
%       g_im   逐节点 dQ/d(eps_im) 灵敏度场
%       F_val  当前代价函数值

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  COMSOL 原生伴随 + 控制变量场（逐节点梯度）\n');
fprintf('############################################################\n\n');

%% 1. 加载模型
mphstart(p.comsol_port);
try; ts=ModelUtil.tags(); for i=1:length(ts), ModelUtil.remove(char(ts(i))); end; catch; end

model = mphload('2layer_sensitive.mph');
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end
phys = model.physics('emw');

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);
inner_pos = voxel.pos(inner_idx, :);

%% 2. 加载真值场
fprintf('加载真值场...\n');
tmp = dlmread('Et_x_re.csv'); Etx = tmp(:,4);
tmp = dlmread('Et_x_im.csv'); Etx = Etx + 1i*tmp(:,4);
tmp = dlmread('Et_y_re.csv'); Ety = tmp(:,4);
tmp = dlmread('Et_y_im.csv'); Ety = Ety + 1i*tmp(:,4);
tmp = dlmread('Et_z_re.csv'); Etz = tmp(:,4);
tmp = dlmread('Et_z_im.csv'); Etz = Etz + 1i*tmp(:,4);
E_truth = [Etx, Ety, Etz];

%% 3. 设置初值 ε_r（非均匀插值函数）
% eps_r_init = 3.5 + 0.5*x/R - 1j（非均匀）
fprintf('设置初值 ε_r（非均匀）...\n');
eps_init_re = 3.5 + 0.5 * inner_pos(:,1) / p.R_inner;
eps_init_im = -1.0 * ones(N_inner, 1);

% 写入插值函数 int1(Re) 和 int2(Im)
for fi = 1:2
    if fi == 1
        fn = 'int1'; vals = eps_init_re;
    else
        fn = 'int2'; vals = eps_init_im;
    end
    try model.component('comp1').func(fn); catch
        model.component('comp1').func.create(fn, 'Interpolation');
    end
    model.component('comp1').func(fn).set('nargs', '3');
    model.component('comp1').func(fn).set('source', 'table');
    try model.component('comp1').func(fn).set('extrap', 'specific'); catch; end
    try model.component('comp1').func(fn).set('constval', '1'); catch; end
    tmp_csv = [tempname, '.csv'];
    dlmwrite(tmp_csv, [inner_pos, vals(:)]);
    model.component('comp1').func(fn).importData(tmp_csv);
    delete(tmp_csv);
end
fprintf('  OK int1/int2 已写入初值\n');

%% 4. 设置 wee1.epsilonr = int1 + i*int2（插值函数）
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'int1(x,y,z) + i*int2(x,y,z)'});
fprintf('  OK wee1.epsilonr = int1(x,y,z) + i*int2(x,y,z)\n');

%% 5. 在 Sensitivity 中添加 Control Variable Field
% 用全局参数 eps_re_ctrl 和 eps_im_ctrl 作为控制变量
% 但 ε_r = (int1 + eps_re_ctrl) + i*(int2 + eps_im_ctrl)
% 这样 Sensitivity 求的是"均匀偏移"的灵敏度

% 更好的方案: 用多个全局参数对应多个区域
fprintf('\n--- 方案A: 全局偏移灵敏度（均匀偏移梯度）---\n');

% ε_r = (int1 + eps_re_ctrl) + i*(int2 + eps_im_ctrl)
phys.feature('wee1').set('epsilonr', {'(int1(x,y,z) + eps_re_ctrl) + i*(int2(x,y,z) + eps_im_ctrl)'});
model.param.set('eps_re_ctrl', '0');  % 初始偏移=0
model.param.set('eps_im_ctrl', '0');

% 目标函数
obj_expr = 'comp1.intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';

% 配置 Sensitivity
try model.sol.remove('sol1'); catch; end
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);
model.study('std1').feature('sens').setIndex('pname', 'eps_re_ctrl', 0);
model.study('std1').feature('sens').setIndex('initval', 0, 0);
model.study('std1').feature('sens').setIndex('scale', 1, 0);
model.study('std1').feature('sens').setIndex('valuetype', 'real', 0);
model.study('std1').feature('sens').setIndex('pname', 'eps_im_ctrl', 1);
model.study('std1').feature('sens').setIndex('initval', 0, 1);
model.study('std1').feature('sens').setIndex('scale', 1, 1);
model.study('std1').feature('sens').setIndex('valuetype', 'real', 1);

fprintf('运行 Sensitivity...\n');
model.study('std1').run;
fprintf('  OK\n');

% 提取全局灵敏度（均匀偏移）
g_re_global = mphglobal(model, 'fsens(eps_re_ctrl)');
g_im_global = mphglobal(model, 'fsens(eps_im_ctrl)');
fprintf('  全局偏移灵敏度:\n');
fprintf('    dQ/d(eps_re_offset) = %+.6e\n', g_re_global);
fprintf('    dQ/d(eps_im_offset) = %+.6e\n', g_im_global);

%% 6. 方案B: 逐体素灵敏度（用 N 个全局参数）
% 由于 COMSOL Sensitivity 伴随法不依赖参数数量，
% 可以定义 N 个全局参数，每个对应一个体素
% ε_r = Σ eps_re_i * δ_i(x,y,z)（δ_i 是第 i 个体素的特征函数）
% 但实际实现用插值函数更简洁

fprintf('\n--- 方案B: 逐区域灵敏度（多区域分组）---\n');
fprintf('  将内部域分为 %d 个径向区域...\n', 5);

% 按 r 分成 5 组
tet_center = voxel.pos(inner_idx, :);
tet_r = vecnorm(tet_center, 2, 2);
r_bins = linspace(0, p.R_inner, 6);  % 5 组
group_idx = discretize(tet_r, r_bins);
N_groups = 5;

% 每组写入一个插值函数 eps_re_g1, ..., eps_re_g5
eps_group_expr_re = '(';
eps_group_expr_im = '(';
for gi = 1:N_groups
    mask = (group_idx == gi);
    if ~any(mask), continue; end
    
    % 创建组参数
    gparam_re = sprintf('eps_re_g%d', gi);
    gparam_im = sprintf('eps_im_g%d', gi);
    model.param.set(gparam_re, sprintf('%.4f', mean(eps_init_re(mask))));
    model.param.set(gparam_im, sprintf('%.4f', mean(eps_init_im(mask))));
    
    % 创建组的指示函数（插值）
    fn_re = sprintf('igrp_re_%d', gi);
    fn_im = sprintf('igrp_im_%d', gi);
    ind_vals = double(mask);  % 1 for this group, 0 otherwise
    
    fn_list = {fn_re, fn_im};
    for fi = 1:2
        fn = fn_list{fi};
        try model.component('comp1').func(fn); catch
            model.component('comp1').func.create(fn, 'Interpolation');
        end
        model.component('comp1').func(fn).set('nargs', '3');
        model.component('comp1').func(fn).set('source', 'table');
        try model.component('comp1').func(fn).set('extrap', 'specific'); catch; end
        try model.component('comp1').func(fn).set('constval', '0'); catch; end
        tmp_csv = [tempname, '.csv'];
        dlmwrite(tmp_csv, [inner_pos, ind_vals]);
        model.component('comp1').func(fn).importData(tmp_csv);
        delete(tmp_csv);
    end
    
    if gi > 1
        eps_group_expr_re = [eps_group_expr_re, ' + '];
        eps_group_expr_im = [eps_group_expr_im, ' + '];
    end
    eps_group_expr_re = sprintf('%s%s_g%d*%s(x,y,z)', eps_group_expr_re, 'eps_re', gi, fn_re);
    eps_group_expr_im = sprintf('%s%s_g%d*%s(x,y,z)', eps_group_expr_im, 'eps_im', gi, fn_im);
end
eps_group_expr_re = [eps_group_expr_re, ')'];
eps_group_expr_im = [eps_group_expr_im, ')'];

% ε_r = Σ eps_re_gi * ind_gi + i*Σ eps_im_gi * ind_gi
epsr_full = sprintf('%s + i*%s', eps_group_expr_re, eps_group_expr_im);
fprintf('  ε_r 表达式长度: %d 字符\n', length(epsr_full));

phys.feature('wee1').set('epsilonr', {epsr_full});

% 设置 Sensitivity 参数
try model.sol.remove('sol1'); catch; end
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);

for gi = 1:N_groups
    gparam_re = sprintf('eps_re_g%d', gi);
    gparam_im = sprintf('eps_im_g%d', gi);
    idx_re = (gi-1)*2;
    idx_im = (gi-1)*2 + 1;
    
    model.study('std1').feature('sens').setIndex('pname', gparam_re, idx_re);
    model.study('std1').feature('sens').setIndex('initval', ...
        str2double(model.param.get(gparam_re)), idx_re);
    model.study('std1').feature('sens').setIndex('scale', 1, idx_re);
    model.study('std1').feature('sens').setIndex('valuetype', 'real', idx_re);
    
    model.study('std1').feature('sens').setIndex('pname', gparam_im, idx_im);
    model.study('std1').feature('sens').setIndex('initval', ...
        str2double(model.param.get(gparam_im)), idx_im);
    model.study('std1').feature('sens').setIndex('scale', 1, idx_im);
    model.study('std1').feature('sens').setIndex('valuetype', 'real', idx_im);
end

fprintf('运行 Sensitivity（%d 个参数）...\n', N_groups*2);
try
    model.study('std1').run;
    fprintf('  OK\n');
    
    % 提取逐组灵敏度
    fprintf('\n  逐组灵敏度:\n');
    fprintf('  组号  r_range      dQ/d(eps_re)    dQ/d(eps_im)\n');
    g_re = zeros(N_groups, 1);
    g_im = zeros(N_groups, 1);
    for gi = 1:N_groups
        gparam_re = sprintf('eps_re_g%d', gi);
        gparam_im = sprintf('eps_im_g%d', gi);
        g_re(gi) = mphglobal(model, ['fsens(' gparam_re ')']);
        g_im(gi) = mphglobal(model, ['fsens(' gparam_im ')']);
        r_lo = r_bins(gi); r_hi = r_bins(gi+1);
        fprintf('  %d    [%.3f,%.3f]  %+.6e  %+.6e\n', gi, r_lo, r_hi, g_re(gi), g_im(gi));
    end
    
    % FD 验证第3组
    fprintf('\n  FD 验证第3组实部...\n');
    fd = 0.1;
    orig_val = str2double(model.param.get('eps_re_g3'));
    model.param.set('eps_re_g3', sprintf('%.4f', orig_val + fd));
    model.sol.remove('sol1');
    model.sol.create('sol1'); model.sol('sol1').study('std1'); model.sol('sol1').attach('std1');
    model.sol('sol1').runAll;
    [Ep,~,~] = solve_forward(model, voxel, p);
    F_p = sum(voxel.dV(inner_idx) .* sum(abs(Ep - E_truth).^2, 2));
    
    model.param.set('eps_re_g3', sprintf('%.4f', orig_val - fd));
    model.sol('sol1').clearSolution; model.sol('sol1').runAll;
    [Em,~,~] = solve_forward(model, voxel, p);
    F_m = sum(voxel.dV(inner_idx) .* sum(abs(Em - E_truth).^2, 2));
    g_fd = (F_p - F_m) / (2*fd);
    model.param.set('eps_re_g3', sprintf('%.4f', orig_val));
    
    fprintf('    伴随=%+.6e  FD=%+.6e  ratio=%+.4f\n', g_re(3), g_fd, g_re(3)/g_fd);
    
    F_val = sum(voxel.dV(inner_idx) .* sum(abs(Ep - E_truth).^2, 2));
    
catch ME
    fprintf('  FAIL: %s\n', ME.message);
    g_re = []; g_im = []; F_val = NaN;
end

fprintf('\n############################################################\n');
try ModelUtil.remove('Model'); catch; end
end
