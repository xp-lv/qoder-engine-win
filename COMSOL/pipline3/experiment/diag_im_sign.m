function diag_im_sign()
%DIAG_IM_SIGN 排查虚部灵敏度符号反转
%   测试1: ε_r = 1 + epsi_re + i*epsi_im（当前表达式）
%   测试2: ε_r = 1 + epsi_re - i*epsi_im（翻转虚部符号）
%   对比两种情况下的 fsens 和 FD

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  虚部灵敏度符号诊断\n');
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
coord3 = inner_pos';

% 加载真值场
tmp = dlmread('Et_x_re.csv'); Etx = tmp(:,4);
tmp = dlmread('Et_x_im.csv'); Etx = Etx + 1i*tmp(:,4);
tmp = dlmread('Et_y_re.csv'); Ety = tmp(:,4);
tmp = dlmread('Et_y_im.csv'); Ety = Ety + 1i*tmp(:,4);
tmp = dlmread('Et_z_re.csv'); Etz = tmp(:,4);
tmp = dlmread('Et_z_im.csv'); Etz = Etz + 1i*tmp(:,4);
E_truth = [Etx, Ety, Etz];

obj_expr = 'comp1.intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';
get_E = @() get_E_helper(model, coord3);

fd = 0.01;

%% ========== 测试1: ε_r = 1 + epsi_re + i*epsi_im ==========
fprintf('=== 测试1: ε_r = 1 + epsi_re + i*epsi_im ===\n');
model.component('comp1').common('cvf1').selection.all();
model.component('comp1').common('cvf2').selection.all();
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', '-1');
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});

try model.sol.remove('sol1'); catch; end
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);
model.study('std1').run;
g_re1 = mphinterp(model, 'fsens(epsi_re)', 'coord', coord3);
g_im1 = mphinterp(model, 'fsens(epsi_im)', 'coord', coord3);
fprintf('  fsens(epsi_re): Σ=%+.6e\n', sum(g_re1));
fprintf('  fsens(epsi_im): Σ=%+.6e\n', sum(g_im1));

% FD epsi_im
model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 + fd));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
Ep = get_E();
F_p = sum(dV .* sum(abs(Ep - E_truth).^2, 2));

model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 - fd));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
Em = get_E();
F_m = sum(dV .* sum(abs(Em - E_truth).^2, 2));
fd_im1 = (F_p - F_m) / (2*fd);
fprintf('  FD(epsi_im):    %+.6e  → ratio=%+.4f\n\n', fd_im1, sum(g_im1)/fd_im1);

%% ========== 测试2: ε_r = 1 + epsi_re - i*epsi_im ==========
fprintf('=== 测试2: ε_r = 1 + epsi_re - i*epsi_im ===\n');
% 注意: 翻转符号后 epsi_im=-1 → ε_r = 3 + i（虚部为正！）
% 需要同时调整真值场? 不，真值场不变，只是参数化方式变了
% epsi_im 的物理含义变了: epsi_im=1 对应虚部=-1
phys.feature('wee1').set('epsilonr', {'1 + epsi_re - i*epsi_im'});
model.component('comp1').common('cvf2').set('initialValue', '1');  % epsi_im=1 → 虚部=-1

try model.sol.remove('sol1'); catch; end
model.study('std1').run;
g_re2 = mphinterp(model, 'fsens(epsi_re)', 'coord', coord3);
g_im2 = mphinterp(model, 'fsens(epsi_im)', 'coord', coord3);
fprintf('  fsens(epsi_re): Σ=%+.6e\n', sum(g_re2));
fprintf('  fsens(epsi_im): Σ=%+.6e\n', sum(g_im2));

% FD epsi_im (现在 epsi_im=1, δ=0.01 → 1.01/0.99)
model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', 1 + fd));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
Ep = get_E();
F_p = sum(dV .* sum(abs(Ep - E_truth).^2, 2));

model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', 1 - fd));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
Em = get_E();
F_m = sum(dV .* sum(abs(Em - E_truth).^2, 2));
fd_im2 = (F_p - F_m) / (2*fd);
fprintf('  FD(epsi_im):    %+.6e  → ratio=%+.4f\n\n', fd_im2, sum(g_im2)/fd_im2);

%% ========== 测试3: 用 fsensimag ==========
fprintf('=== 测试3: fsensimag 操作符 ===\n');
% COMSOL 有 fsensimag 操作符用于复数灵敏度的虚部
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', '-1');
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
try
    g_imag = mphinterp(model, 'fsensimag(epsi_im)', 'coord', coord3);
    fprintf('  fsensimag(epsi_im): Σ=%+.6e  → ratio_vs_FD=%+.4f\n', sum(g_imag), sum(g_imag)/fd_im1);
catch ME
    fprintf('  fsensimag FAIL: %s\n', ME.message);
end
try
    g_real_op = mphinterp(model, 'fsensreal(epsi_im)', 'coord', coord3);
    fprintf('  fsensreal(epsi_im): Σ=%+.6e\n', sum(g_real_op));
catch ME
    fprintf('  fsensreal FAIL: %s\n', ME.message);
end

%% ========== 测试4: 复数 valuetype ==========
fprintf('\n=== 测试4: valuetype=complex ===\n');
try
    model.study('std1').feature('sens').setIndex('valuetype', 'complex', 1);
    try model.sol.remove('sol1'); catch; end
    model.study('std1').run;
    g_im_c = mphinterp(model, 'fsens(epsi_im)', 'coord', coord3);
    fprintf('  fsens(epsi_im) [complex]: Σ=%+.6e  → ratio=%+.4f\n', sum(g_im_c), sum(g_im_c)/fd_im1);
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

%% ========== 总结 ==========
fprintf('\n############################################################\n');
fprintf('  测试1 (+i*epsi_im):  adj=%+.4e  FD=%+.4e  ratio=%+.4f\n', sum(g_im1), fd_im1, sum(g_im1)/fd_im1);
fprintf('  测试2 (-i*epsi_im):  adj=%+.4e  FD=%+.4e  ratio=%+.4f\n', sum(g_im2), fd_im2, sum(g_im2)/fd_im2);
fprintf('############################################################\n');

try ModelUtil.remove('Model'); catch; end
end

function E = get_E_helper(model, coord3)
Ex = mphinterp(model,'emw.Ex','coord',coord3);
Ey = mphinterp(model,'emw.Ey','coord',coord3);
Ez = mphinterp(model,'emw.Ez','coord',coord3);
E = [Ex(:), Ey(:), Ez(:)];
end
