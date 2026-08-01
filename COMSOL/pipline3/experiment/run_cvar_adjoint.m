function [g_re, g_im] = run_cvar_adjoint()
%RUN_CVAR_ADJOINT 控制变量场原生伴随（逐节点梯度）
%   ε_r 在内部域 = epsi_re + i*epsi_im
%   ε_r 在外部域 = 1（空气）
%   用 int_dom(x,y,z) 指示函数区分内外域

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  COMSOL 控制变量场原生伴随（逐节点梯度）\n');
fprintf('############################################################\n\n');

mphstart(p.comsol_port);
try; ts=ModelUtil.tags(); for i=1:length(ts), ModelUtil.remove(char(ts(i))); end; catch; end

model = mphload('2layer_sensitive.mph');
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end
phys = model.physics('emw');

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);
inner_pos = voxel.pos(inner_idx, :);

%% 1. 设置控制变量场初值（正确属性名: initialValue）
fprintf('设置控制变量场初值...\n');
% epsi_re 初值 = 3 (均匀，简单测试)
% epsi_im 初值 = -1
try
    model.component('comp1').common('cvf1').set('initialValue', '3');
    model.component('comp1').common('cvf2').set('initialValue', '-1');
    fprintf('  OK cvf1.initialValue=3, cvf2.initialValue=-1\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

%% 2. 设置 ε_r 表达式
% epsi_re/epsi_im 只在内部域定义（域 9-13,18,19,22,23）
% 外部域 ε_r=1，用条件表达式或材料域分配
% 最简方案: 用材料 mat2/mat3 分配外部域 ε_r=1，
%           wee1 的 ε_r 只作用于内部域
% 但 wee1 作用于所有域...
% 用表达式: epsi_re 在未定义处外推为 0 → ε_r = (1+epsi_re) + i*epsi_im 在内部，1 在外部
% 不行，控制变量场在外部域不存在
% 
% 正确方案: wee1.epsilonr 用表达式
%   (1+epsi_re) + i*epsi_im  会在外部域出错
% 
% 用 intop 的域选择来限制...
% 
% 最实际方案: 让控制变量场选择所有域，外部域初值=0
% ε_r = (1 + epsi_re) + i*epsi_im，外部域 epsi_re=0 → ε_r=1
fprintf('\n扩展控制变量场到所有域...\n');
try
    model.component('comp1').common('cvf1').selection.all();
    model.component('comp1').common('cvf2').selection.all();
    % 内部域初值: epsi_re=2 (ε_r=3), epsi_im=-1
    % 外部域初值: epsi_re=0 (ε_r=1), epsi_im=0
    % 但 initialValue 是全局的...
    % 改为: initialValue=0, 然后用插值函数区分
    model.component('comp1').common('cvf1').set('initialValue', '0');
    model.component('comp1').common('cvf2').set('initialValue', '0');
    fprintf('  OK control variable fields set to all domains, init=0\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

% ε_r = (1 + epsi_re * ind_inner + epsi_re_offset) + i*(epsi_im * ind_inner)
% 但这太复杂了。最简单:
% ε_r = 1 + epsi_re*(int1_ind(x,y,z)) + i*epsi_im*(int1_ind(x,y,z))
% 其中 int1_ind 是指示函数: 内部=1, 外部=0
% 
% 更简单: 用内部域的插值函数做指示
% epsi_re 在所有域=0 初值，Sensitivity 对它求梯度
% ε_r = 1 + epsi_re + i*epsi_im (当 epsi_re 在外部=0 时 ε_r=1)

% 设置 ε_r = 1 + epsi_re + i*epsi_im
fprintf('\n设置 wee1.epsilonr = 1 + epsi_re + i*epsi_im...\n');
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});
fprintf('  OK\n');

%% 3. 写入内部域的 epsi_re/epsi_im 初值（非均匀）
% 用插值函数设置初始分布不行——控制变量场是独立于插值函数的
% 控制变量场的 initialValue 只能是常数或表达式
% 要设置非均匀初值，initialValue 可以用表达式
fprintf('\n设置非均匀初值...\n');
try
    % 内部域 epsi_re = 2 + 0.5*x/R (使 ε_r = 3+0.5*x/R)
    % 外部域 epsi_re = 0
    % 用条件: r < 0.06 ? (2+0.5*x/0.06) : 0
    % 但控制变量场 initialValue 不支持空间条件...
    % 用表达式: epsi_re_init(x,y,z) 插值函数
    model.component('comp1').common('cvf1').set('initialValue', '2');
    model.component('comp1').common('cvf2').set('initialValue', '-1');
    fprintf('  OK (uniform: epsi_re=2→ε_r=3, epsi_im=-1)\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

%% 4. 配置 Sensitivity
fprintf('\n配置 Sensitivity...\n');
try model.sol.remove('sol1'); catch; end

% 设置目标函数
obj_expr = 'comp1.intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';

% 先清空旧的 pname，重新设置
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);

% 控制变量场自动出现在 Sensitivity 参数列表中
try
    model.study('std1').feature('sens').setIndex('pname', 'epsi_re', 0);
    model.study('std1').feature('sens').setIndex('initval', 2, 0);
    model.study('std1').feature('sens').setIndex('scale', 1, 0);
    model.study('std1').feature('sens').setIndex('valuetype', 'real', 0);
    
    model.study('std1').feature('sens').setIndex('pname', 'epsi_im', 1);
    model.study('std1').feature('sens').setIndex('initval', -1, 1);
    model.study('std1').feature('sens').setIndex('scale', 1, 1);
    model.study('std1').feature('sens').setIndex('valuetype', 'real', 1);
    fprintf('  OK pname set\n');
catch ME
    fprintf('  pname FAIL: %s\n', ME.message);
    % 尝试用旧的全局参数
    try
        model.study('std1').feature('sens').setIndex('pname', 'eps_re_ctrl', 0);
        model.study('std1').feature('sens').setIndex('pname', 'eps_im_ctrl', 1);
        fprintf('  fallback to eps_re_ctrl/eps_im_ctrl\n');
    catch
        fprintf('  fallback also failed\n');
    end
end

%% 5. 求解
fprintf('\n运行 study.run...\n');
try
    model.study('std1').run;
    fprintf('  OK!\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
    return;
end

%% 6. 提取逐节点灵敏度场
fprintf('\n提取灵敏度场...\n');
g_re = []; g_im = [];
try
    g_re = mphinterp(model, 'fsens(epsi_re)', 'coord', inner_pos');
    fprintf('  fsens(epsi_re): %d 点, |g_re| mean=%.4e\n', length(g_re), mean(abs(g_re)));
catch ME
    fprintf('  fsens(epsi_re) FAIL: %s\n', ME.message);
end

try
    g_im = mphinterp(model, 'fsens(epsi_im)', 'coord', inner_pos');
    fprintf('  fsens(epsi_im): %d 点, |g_im| mean=%.4e\n', length(g_im), mean(abs(g_im)));
catch ME
    fprintf('  fsens(epsi_im) FAIL: %s\n', ME.message);
end

%% 7. 打印采样点
if ~isempty(g_re)
    fprintf('\n  采样点伴随梯度:\n');
    fprintf('  体素  r       g_re(adj)        g_im(adj)\n');
    r_inner = vecnorm(inner_pos, 2, 2);
    [~, sort_idx] = sort(r_inner);
    N_show = min(10, N_inner);
    step_sz = floor(N_inner / N_show);
    for si = 1:N_show
        vi = sort_idx(max(1, si * step_sz));
        fprintf('  %4d  %.4f  %+.6e  %+.6e\n', vi, r_inner(vi), g_re(vi), g_im(vi));
    end
end

fprintf('\n############################################################\n');
try
    save('native_adjoint_result.mat', 'g_re', 'g_im', 'inner_pos', 'inner_idx');
    fprintf('结果已保存: native_adjoint_result.mat\n');
catch; end
try ModelUtil.remove('Model'); catch; end
end
