function verify_cvar_fd(N_sample)
%VERIFY_CVAR_FD 控制变量场伴随梯度的 FD 验证
%   方法: 用插值函数构造局部扰动，FD 验证逐体素梯度

if nargin < 1, N_sample = 5; end

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  控制变量场伴随梯度 FD 验证 (N=%d)\n', N_sample);
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
dV = voxel.dV(inner_idx);

%% 1. 设置控制变量场（均匀初值 epsi_re=2, epsi_im=-1）
fprintf('设置控制变量场 (epsi_re=2, epsi_im=-1)...\n');
model.component('comp1').common('cvf1').selection.all();
model.component('comp1').common('cvf2').selection.all();
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', '-1');
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});

%% 2. 运行 Sensitivity 获取伴随梯度
fprintf('运行 Sensitivity...\n');
try model.sol.remove('sol1'); catch; end
obj_expr = 'comp1.intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);
model.study('std1').run;
fprintf('  OK\n');

g_re = mphinterp(model, 'fsens(epsi_re)', 'coord', inner_pos');
g_im = mphinterp(model, 'fsens(epsi_im)', 'coord', inner_pos');
fprintf('  |g_re| mean=%.4e, |g_im| mean=%.4e\n', mean(abs(g_re)), mean(abs(g_im)));

%% 3. 获取 base F 值
% 用全局参数 FD 方式验证（均匀偏移）
fprintf('\n=== 均匀偏移 FD 验证 ===\n');
% 加载真值场
tmp = dlmread('Et_x_re.csv'); Etx = tmp(:,4);
tmp = dlmread('Et_x_im.csv'); Etx = Etx + 1i*tmp(:,4);
tmp = dlmread('Et_y_re.csv'); Ety = tmp(:,4);
tmp = dlmread('Et_y_im.csv'); Ety = Ety + 1i*tmp(:,4);
tmp = dlmread('Et_z_re.csv'); Etz = tmp(:,4);
tmp = dlmread('Et_z_im.csv'); Etz = Etz + 1i*tmp(:,4);
E_truth = [Etx, Ety, Etz];

% base 正演（epsi_re=2 → ε_r=3）
% Sensitivity 求解已包含正演解，直接读
coord3 = inner_pos';  % 3 x N
E_base_x = mphinterp(model, 'emw.Ex', 'coord', coord3);
E_base_y = mphinterp(model, 'emw.Ey', 'coord', coord3);
E_base_z = mphinterp(model, 'emw.Ez', 'coord', coord3);
E_base = [E_base_x(:), E_base_y(:), E_base_z(:)];
fprintf('  E_base size: %dx%d\n', size(E_base));
F_base = sum(dV .* sum(abs(E_base - E_truth).^2, 2));
fprintf('  F_base = %.6e\n', F_base);

% 均匀偏移 FD：epsi_re += delta → ε_r += delta
% 但 epsi_re 是控制变量场，不能用全局参数改...
% 改用 initialValue
fd_delta = 0.01;

% epsi_re + delta
model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 + fd_delta));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
coord3 = inner_pos';
E_p_x = mphinterp(model, 'emw.Ex', 'coord', coord3);
E_p_y = mphinterp(model, 'emw.Ey', 'coord', coord3);
E_p_z = mphinterp(model, 'emw.Ez', 'coord', coord3);
E_p = [E_p_x(:), E_p_y(:), E_p_z(:)];
F_re_p = sum(dV .* sum(abs(E_p - E_truth).^2, 2));

% epsi_re - delta
model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 - fd_delta));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
E_m_x = mphinterp(model, 'emw.Ex', 'coord', coord3);
E_m_y = mphinterp(model, 'emw.Ey', 'coord', coord3);
E_m_z = mphinterp(model, 'emw.Ez', 'coord', coord3);
E_m = [E_m_x(:), E_m_y(:), E_m_z(:)];
F_re_m = sum(dV .* sum(abs(E_m - E_truth).^2, 2));

g_fd_re_uniform = (F_re_p - F_re_m) / (2 * fd_delta);

% 伴随预测的均匀偏移梯度 = Σ g_re(v) * dV(v) / Σ dV(v) ... 不对
% 实际上 fsens(epsi_re) 返回的是 dQ/d(epsi_re_node)
% 均匀偏移 δ 对所有节点同时加 δ
% dQ = Σ_v fsens(v) * δ * dV_v  ← 不对，fsens 已经包含了体积权重？
% 还是 dQ = Σ_v fsens(v) * δ ？
% 
% COMSOL 的 fsens 返回的是灵敏度密度还是总灵敏度？
% 从之前的 5-group 测试看: fsens(eps_re_g3) 是一个标量（全局量）
% 但现在 fsens(epsi_re) 是一个场（逐节点）
% 
% COMSOL 文档说: "the discretization of the control variable field is constant in each element"
% 所以 fsens(epsi_re) 在每个单元上返回 dQ/d(epsi_re_at_that_element)
% 均匀偏移 δ → dQ = Σ_elements fsens(element) * δ
% 但 fsens 是"per element"还是"per node"？
% 
% 验证方式: 比较 Σ g_re vs FD
g_adj_uniform = sum(g_re);
fprintf('\n  均匀偏移 (eps_re + %g):\n', fd_delta);
fprintf('    FD      = %+.6e\n', g_fd_re_uniform);
fprintf('    Σg_re   = %+.6e\n', g_adj_uniform);
fprintf('    ratio   = %+.4f\n', g_adj_uniform / g_fd_re_uniform);

% 虚部
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 + fd_delta));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
E_p_x = mphinterp(model, 'emw.Ex', 'coord', coord3);
E_p_y = mphinterp(model, 'emw.Ey', 'coord', coord3);
E_p_z = mphinterp(model, 'emw.Ez', 'coord', coord3);
E_p = [E_p_x(:), E_p_y(:), E_p_z(:)];
F_im_p = sum(dV .* sum(abs(E_p - E_truth).^2, 2));

model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 - fd_delta));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
E_m_x = mphinterp(model, 'emw.Ex', 'coord', coord3);
E_m_y = mphinterp(model, 'emw.Ey', 'coord', coord3);
E_m_z = mphinterp(model, 'emw.Ez', 'coord', coord3);
E_m = [E_m_x(:), E_m_y(:), E_m_z(:)];
F_im_m = sum(dV .* sum(abs(E_m - E_truth).^2, 2));

g_fd_im_uniform = (F_im_p - F_im_m) / (2 * fd_delta);
g_adj_im_uniform = sum(g_im);

fprintf('\n  均匀偏移 (eps_im + %g):\n', fd_delta);
fprintf('    FD      = %+.6e\n', g_fd_im_uniform);
fprintf('    Σg_im   = %+.6e\n', g_adj_im_uniform);
fprintf('    ratio   = %+.4f\n', g_adj_im_uniform / g_fd_im_uniform);

%% 4. 逐体素 FD（局部扰动）
fprintf('\n=== 逐体素 FD（局部扰动）===\n');
% 对选定的体素，用插值函数构造局部偏移
% ε_r = 1 + (epsi_re + delta * ind_v) + i*epsi_im
% 其中 ind_v 是第 v 个体素的指示函数（在该体素=1，其他=0）

r_inner = vecnorm(inner_pos, 2, 2);
[~, sort_idx] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_idx(max(1, step_sz):step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

% 先恢复 base 状态
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', '-1');

fd_vox = 0.1;  % 局部扰动步长（较大以确保 FD 精度）

fprintf('  N_sample=%d, delta=%.2f\n\n', N_s, fd_vox);
fprintf('  体素  r       g_re(adj)        g_re(FD)         ratio    sign\n');

for si = 1:N_s
    vi = sample_idx(si);
    
    % 创建该体素的指示函数
    fn_ind = sprintf('ind_fd_%d', si);
    try model.component('comp1').func(fn_ind); catch
        model.component('comp1').func.create(fn_ind, 'Interpolation');
    end
    model.component('comp1').func(fn_ind).set('nargs', '3');
    model.component('comp1').func(fn_ind).set('source', 'table');
    try model.component('comp1').func(fn_ind).set('extrap', 'specific'); catch; end
    try model.component('comp1').func(fn_ind).set('constval', '0'); catch; end
    
    % 指示函数: 在体素 vi 处 = 1，其他 = 0
    ind_vals = zeros(N_inner, 1);
    ind_vals(vi) = 1;
    tmp_csv = [tempname, '.csv'];
    dlmwrite(tmp_csv, [inner_pos, ind_vals]);
    model.component('comp1').func(fn_ind).importData(tmp_csv);
    delete(tmp_csv);
    
    % ε_r = 1 + epsi_re + delta*ind_v + i*epsi_im
    ind_expr = sprintf('%s(x,y,z)', fn_ind);
    epsr_expr = sprintf('1 + epsi_re + %g*%s + i*epsi_im', fd_vox, ind_expr);
    phys.feature('wee1').set('epsilonr', {epsr_expr});
    
    try model.sol.remove('sol1'); catch; end
    model.sol.create('sol1'); model.sol('sol1').study('std1'); model.sol('sol1').attach('std1');
    model.sol('sol1').runAll;
    E_p = solve_forward_simple(model, voxel, p);
    F_p = sum(dV .* sum(abs(E_p - E_truth).^2, 2));
    
    % 负扰动
    epsr_expr_m = sprintf('1 + epsi_re - %g*%s + i*epsi_im', fd_vox, ind_expr);
    phys.feature('wee1').set('epsilonr', {epsr_expr_m});
    try model.sol.remove('sol1'); catch; end
    model.sol.create('sol1'); model.sol('sol1').study('std1'); model.sol('sol1').attach('std1');
    model.sol('sol1').runAll;
    E_m = solve_forward_simple(model, voxel, p);
    F_m = sum(dV .* sum(abs(E_m - E_truth).^2, 2));
    
    g_fd = (F_p - F_m) / (2 * fd_vox);
    g_adj = g_re(vi);
    r_ratio = g_adj / max(abs(g_fd), 1e-30);
    s = 'XX'; if g_fd * g_adj > 0, s = 'OK'; end
    
    fprintf('  %4d  %.4f  %+.6e  %+.6e  %+.4f  %s\n', vi, r_inner(vi), g_adj, g_fd, r_ratio, s);
end

fprintf('\n############################################################\n');
try ModelUtil.remove('Model'); catch; end
end

function E_vox = solve_forward_simple(model, voxel, p)
% 简化正演: 只返回体素中心场值
inner = voxel.mask_interior; inner_idx = find(inner);
inner_pos = voxel.pos(inner_idx, :);
try
    model.param.set('freq', num2str(p.freq));
    try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
    coord3 = inner_pos';
    E_vox_x = mphinterp(model, 'emw.Ex', 'coord', coord3);
    E_vox_y = mphinterp(model, 'emw.Ey', 'coord', coord3);
    E_vox_z = mphinterp(model, 'emw.Ez', 'coord', coord3);
    E_vox = [E_vox_x(:), E_vox_y(:), E_vox_z(:)];
catch
    E_vox = zeros(length(inner_idx), 3);
end
end
