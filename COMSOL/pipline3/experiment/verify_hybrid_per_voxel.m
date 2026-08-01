function verify_hybrid_per_voxel(N_sample)
%VERIFY_HYBRID_PER_VOXEL 逐体素 FD 验证混合梯度的空间分布
%   关键：FD 和伴随完全独立计算，然后对比逐体素的值

if nargin < 1, N_sample = 5; end

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  逐体素 FD 验证混合梯度 (N=%d)\n', N_sample);
fprintf('#  FD 和伴随完全独立，对比逐体素值\n', N_sample);
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

%% 加载真值场
tmp = dlmread('Et_x_re.csv'); Etx = tmp(:,4);
tmp = dlmread('Et_x_im.csv'); Etx = Etx + 1i*tmp(:,4);
tmp = dlmread('Et_y_re.csv'); Ety = tmp(:,4);
tmp = dlmread('Et_y_im.csv'); Ety = Ety + 1i*tmp(:,4);
tmp = dlmread('Et_z_re.csv'); Etz = tmp(:,4);
tmp = dlmread('Et_z_im.csv'); Etz = Etz + 1i*tmp(:,4);
E_truth = [Etx, Ety, Etz];

obj_expr = 'comp1.intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';

%% 1. 伴随灵敏度（1次求解）
fprintf('[1] 伴随灵敏度...\n');
model.component('comp1').common('cvf1').selection.all();
model.component('comp1').common('cvf2').selection.all();
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', '-1');
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});
try model.sol.remove('sol1'); catch; end
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);
model.study('std1').run;

g_re_adj = mphinterp(model, 'fsens(epsi_re)', 'coord', coord3); g_re_adj = g_re_adj(:);
g_im_adj = mphinterp(model, 'fsens(epsi_im)', 'coord', coord3); g_im_adj = g_im_adj(:);
fprintf('  adj: Σg_re=%+.4e, Σg_im=%+.4e\n', sum(g_re_adj), sum(g_im_adj));

%% 2. 均匀FD标定（2次求解，得到全局缩放因子）
fprintf('[2] 均匀FD标定...\n');
fd = 0.01;

% 实部均匀FD
model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 + fd));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_re_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 - fd));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_re_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
g_fd_re = (F_re_p - F_re_m) / (2*fd);

% 虚部均匀FD
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 + fd));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_im_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 - fd));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_im_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
g_fd_im = (F_im_p - F_im_m) / (2*fd);

re_scale = g_fd_re / sum(g_re_adj);
im_scale = g_fd_im / sum(g_im_adj);
g_re_hybrid = g_re_adj * re_scale;
g_im_hybrid = g_im_adj * im_scale;
fprintf('  re_scale=%.4f, im_scale=%.4f\n', re_scale, im_scale);

%% 3. 逐体素 FD（独立的局部扰动验证）
fprintf('\n[3] 逐体素 FD（独立局部扰动）...\n');
% 对选定体素，用指示函数构造局部偏移
% ε_r = 1 + epsi_re + delta*ind_v + i*epsi_im

% 恢复 base 状态
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});

r_inner = vecnorm(inner_pos, 2, 2);
[~, sort_idx] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_idx(max(1, step_sz):step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fd_vox = 0.1;  % 局部扰动步长

fprintf('  N_sample=%d, delta=%.2f\n\n', N_s, fd_vox);
fprintf('  === 实部逐体素验证 ===\n');
fprintf('  体素  r       g_re(hybrid)     g_re(FD)          ratio    sign\n');

for si = 1:N_s
    vi = sample_idx(si);
    
    % 创建指示函数
    fn_ind = sprintf('ifd%d', si);
    try model.component('comp1').func(fn_ind); catch
        model.component('comp1').func.create(fn_ind, 'Interpolation');
    end
    model.component('comp1').func(fn_ind).set('nargs', '3');
    model.component('comp1').func(fn_ind).set('source', 'table');
    try model.component('comp1').func(fn_ind).set('extrap', 'specific'); catch; end
    try model.component('comp1').func(fn_ind).set('constval', '0'); catch; end
    ind_vals = zeros(N_inner, 1); ind_vals(vi) = 1;
    tmp_csv = [tempname, '.csv'];
    dlmwrite(tmp_csv, [inner_pos, ind_vals]);
    model.component('comp1').func(fn_ind).importData(tmp_csv);
    delete(tmp_csv);
    
    ind_expr = sprintf('%s(x,y,z)', fn_ind);
    
    % +delta 局部扰动
    epsr_p = sprintf('1 + epsi_re + %g*%s + i*epsi_im', fd_vox, ind_expr);
    phys.feature('wee1').set('epsilonr', {epsr_p});
    model.component('comp1').common('cvf1').set('initialValue', '2');
    model.component('comp1').common('cvf2').set('initialValue', '-1');
    try model.sol.remove('sol1'); catch; end; model.study('std1').run;
    F_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
    
    % -delta
    epsr_m = sprintf('1 + epsi_re - %g*%s + i*epsi_im', fd_vox, ind_expr);
    phys.feature('wee1').set('epsilonr', {epsr_m});
    try model.sol.remove('sol1'); catch; end; model.study('std1').run;
    F_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
    
    g_fd_vox = (F_p - F_m) / (2 * fd_vox);
    g_hyb = g_re_hybrid(vi);
    
    if abs(g_fd_vox) > 1e-30
        ratio = g_hyb / g_fd_vox;
    else
        ratio = NaN;
    end
    s = 'XX'; if g_fd_vox * g_hyb > 0, s = 'OK'; end
    
    fprintf('  %4d  %.4f  %+.6e  %+.6e  %+.4f  %s\n', vi, r_inner(vi), g_hyb, g_fd_vox, ratio, s);
end

fprintf('\n  === 虚部逐体素验证 ===\n');
fprintf('  体素  r       g_im(hybrid)     g_im(FD)          ratio    sign\n');

phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});

for si = 1:N_s
    vi = sample_idx(si);
    fn_ind = sprintf('ifd%d', si);
    ind_expr = sprintf('%s(x,y,z)', fn_ind);
    
    % +delta 虚部局部扰动
    epsr_p = sprintf('1 + epsi_re + i*(epsi_im + %g*%s)', fd_vox, ind_expr);
    phys.feature('wee1').set('epsilonr', {epsr_p});
    model.component('comp1').common('cvf1').set('initialValue', '2');
    model.component('comp1').common('cvf2').set('initialValue', '-1');
    try model.sol.remove('sol1'); catch; end; model.study('std1').run;
    F_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
    
    % -delta
    epsr_m = sprintf('1 + epsi_re + i*(epsi_im - %g*%s)', fd_vox, ind_expr);
    phys.feature('wee1').set('epsilonr', {epsr_m});
    try model.sol.remove('sol1'); catch; end; model.study('std1').run;
    F_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
    
    g_fd_vox = (F_p - F_m) / (2 * fd_vox);
    g_hyb = g_im_hybrid(vi);
    
    if abs(g_fd_vox) > 1e-30
        ratio = g_hyb / g_fd_vox;
    else
        ratio = NaN;
    end
    s = 'XX'; if g_fd_vox * g_hyb > 0, s = 'OK'; end
    
    fprintf('  %4d  %.4f  %+.6e  %+.6e  %+.4f  %s\n', vi, r_inner(vi), g_hyb, g_fd_vox, ratio, s);
end

fprintf('\n############################################################\n');

try ModelUtil.remove('Model'); catch; end
end

function E = get_E(model, coord3)
Ex = mphinterp(model,'emw.Ex','coord',coord3);
Ey = mphinterp(model,'emw.Ey','coord',coord3);
Ez = mphinterp(model,'emw.Ez','coord',coord3);
E = [Ex(:), Ey(:), Ez(:)];
end
