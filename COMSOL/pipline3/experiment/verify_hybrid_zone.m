function verify_hybrid_zone(N_zones)
%VERIFY_HYBRID_ZONE 多体素分区 FD 验证（高信噪比）
%   将内部域按 r 分成 N_zones 个径向区域
%   每个区域包含 ~100-200 个体素，FD 信噪比远高于单体素

if nargin < 1, N_zones = 5; end

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  分区 FD 验证混合梯度 (N_zones=%d)\n', N_zones);
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

%% 1. 分区
r_inner = vecnorm(inner_pos, 2, 2);
r_bins = linspace(0, p.R_inner, N_zones+1);
zone_id = discretize(r_inner, r_bins);

fprintf('分区信息:\n');
for zi = 1:N_zones
    mask = (zone_id == zi);
    fprintf('  zone %d: r=[%.3f,%.3f], %d 体素, ΣdV=%.2e\n', ...
        zi, r_bins(zi), r_bins(zi+1), sum(mask), sum(dV(mask)));
end

%% 2. 伴随灵敏度 + 均匀FD标定
fprintf('\n[1] 伴随 + 均匀FD标定...\n');
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

% 均匀FD标定
fd = 0.01;
model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 + fd));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_re_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 - fd));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_re_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
g_fd_re = (F_re_p - F_re_m) / (2*fd);

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

%% 3. 分区FD验证
fprintf('\n[2] 分区FD验证（每区扰动delta=0.5）...\n');
fd_zone = 0.5;  % 大步长，高信噪比

% 为每个分区创建指示函数
for zi = 1:N_zones
    mask = (zone_id == zi);
    fn_re = sprintf('zre_%d', zi);
    fn_im = sprintf('zim_%d', zi);
    
    for fi = 1:2
        fn_list = {fn_re, fn_im};
        fn = fn_list{fi};
        try model.component('comp1').func(fn); catch
            model.component('comp1').func.create(fn, 'Interpolation');
        end
        model.component('comp1').func(fn).set('nargs', '3');
        model.component('comp1').func(fn).set('source', 'table');
        try model.component('comp1').func(fn).set('extrap', 'specific'); catch; end
        try model.component('comp1').func(fn).set('constval', '0'); catch; end
        tmp_csv = [tempname, '.csv'];
        dlmwrite(tmp_csv, [inner_pos, double(mask)]);
        model.component('comp1').func(fn).importData(tmp_csv);
        delete(tmp_csv);
    end
end

% 恢复 base
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', '-1');

fprintf('\n  === 实部分区验证 ===\n');
fprintf('  zone  r_mid   n_vox   g_re(hybrid,Σ)   g_re(FD)          ratio    sign\n');

for zi = 1:N_zones
    mask = (zone_id == zi);
    n_vox = sum(mask);
    if n_vox == 0, continue; end
    r_mid = (r_bins(zi) + r_bins(zi+1)) / 2;
    
    % 伴随梯度（该区域的加权和）
    g_adj_zone = sum(g_re_hybrid(mask));
    
    % 分区FD: ε_r 在该区域 += fd_zone
    fn = sprintf('zre_%d', zi);
    epsr_p = sprintf('1 + epsi_re + %g*%s(x,y,z) + i*epsi_im', fd_zone, fn);
    phys.feature('wee1').set('epsilonr', {epsr_p});
    try model.sol.remove('sol1'); catch; end; model.study('std1').run;
    F_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
    
    epsr_m = sprintf('1 + epsi_re - %g*%s(x,y,z) + i*epsi_im', fd_zone, fn);
    phys.feature('wee1').set('epsilonr', {epsr_m});
    try model.sol.remove('sol1'); catch; end; model.study('std1').run;
    F_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
    
    g_fd_zone = (F_p - F_m) / (2 * fd_zone);
    
    if abs(g_fd_zone) > 1e-30
        ratio = g_adj_zone / g_fd_zone;
    else
        ratio = NaN;
    end
    s = 'XX'; if g_fd_zone * g_adj_zone > 0, s = 'OK'; end
    
    fprintf('  %d    %.4f  %4d   %+.6e   %+.6e   %+.4f  %s\n', ...
        zi, r_mid, n_vox, g_adj_zone, g_fd_zone, ratio, s);
end

fprintf('\n  === 虚部分区验证 ===\n');
fprintf('  zone  r_mid   n_vox   g_im(hybrid,Σ)   g_im(FD)          ratio    sign\n');

phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});

for zi = 1:N_zones
    mask = (zone_id == zi);
    n_vox = sum(mask);
    if n_vox == 0, continue; end
    r_mid = (r_bins(zi) + r_bins(zi+1)) / 2;
    
    g_adj_zone = sum(g_im_hybrid(mask));
    
    fn = sprintf('zim_%d', zi);
    epsr_p = sprintf('1 + epsi_re + i*(epsi_im + %g*%s(x,y,z))', fd_zone, fn);
    phys.feature('wee1').set('epsilonr', {epsr_p});
    try model.sol.remove('sol1'); catch; end; model.study('std1').run;
    F_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
    
    epsr_m = sprintf('1 + epsi_re + i*(epsi_im - %g*%s(x,y,z))', fd_zone, fn);
    phys.feature('wee1').set('epsilonr', {epsr_m});
    try model.sol.remove('sol1'); catch; end; model.study('std1').run;
    F_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
    
    g_fd_zone = (F_p - F_m) / (2 * fd_zone);
    
    if abs(g_fd_zone) > 1e-30
        ratio = g_adj_zone / g_fd_zone;
    else
        ratio = NaN;
    end
    s = 'XX'; if g_fd_zone * g_adj_zone > 0, s = 'OK'; end
    
    fprintf('  %d    %.4f  %4d   %+.6e   %+.6e   %+.4f  %s\n', ...
        zi, r_mid, n_vox, g_adj_zone, g_fd_zone, ratio, s);
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
