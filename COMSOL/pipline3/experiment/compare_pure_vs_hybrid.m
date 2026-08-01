function compare_pure_vs_hybrid()
%COMPARE_PURE_VS_HYBRID 纯伴随 vs 混合方案的分区FD验证对比
%
%   纯伴随: g_re = fsens(epsi_re), g_im = fsens(epsi_im)  （直接用）
%   混合:   g_re = fsens(epsi_re) * scale_re               （FD标定后）
%
%   对每个分区，计算两种方案的 ratio vs 分区FD
%   如果纯伴随的 ratio 和混合的 ratio 在各分区都一样（只差一个全局常数），
%   说明混合方案没有提供额外信息。

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  纯伴随 vs 混合方案：分区FD对比\n');
fprintf('#  验证: 混合方案是否比纯伴随多了信息？\n');
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

N_zones = 5;
r_inner = vecnorm(inner_pos, 2, 2);
r_bins = linspace(0, p.R_inner, N_zones+1);
zone_id = discretize(r_inner, r_bins);

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

%% 2. 分区FD（用多种步长排除非线性误差）
fprintf('[2] 分区FD...\n');
fd_zones = [0.1, 0.3, 0.5];

% 创建分区指示函数
for zi = 1:N_zones
    mask = (zone_id == zi);
    fn = sprintf('zind%d', zi);
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

% 收集分区FD结果
g_fd_re_zones = zeros(N_zones, length(fd_zones));
g_fd_im_zones = zeros(N_zones, length(fd_zones));

for fi = 1:length(fd_zones)
    fd = fd_zones(fi);
    for zi = 1:N_zones
        mask = (zone_id == zi);
        if sum(mask) == 0, continue; end
        fn = sprintf('zind%d', zi);
        
        % 实部
        epsr_p = sprintf('1 + epsi_re + %g*%s(x,y,z) + i*epsi_im', fd, fn);
        phys.feature('wee1').set('epsilonr', {epsr_p});
        model.component('comp1').common('cvf1').set('initialValue', '2');
        model.component('comp1').common('cvf2').set('initialValue', '-1');
        try model.sol.remove('sol1'); catch; end; model.study('std1').run;
        F_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
        
        epsr_m = sprintf('1 + epsi_re - %g*%s(x,y,z) + i*epsi_im', fd, fn);
        phys.feature('wee1').set('epsilonr', {epsr_m});
        try model.sol.remove('sol1'); catch; end; model.study('std1').run;
        F_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
        g_fd_re_zones(zi, fi) = (F_p - F_m) / (2 * fd);
        
        % 虚部
        epsr_p = sprintf('1 + epsi_re + i*(epsi_im + %g*%s(x,y,z))', fd, fn);
        phys.feature('wee1').set('epsilonr', {epsr_p});
        try model.sol.remove('sol1'); catch; end; model.study('std1').run;
        F_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
        
        epsr_m = sprintf('1 + epsi_re + i*(epsi_im - %g*%s(x,y,z))', fd, fn);
        phys.feature('wee1').set('epsilonr', {epsr_m});
        try model.sol.remove('sol1'); catch; end; model.study('std1').run;
        F_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
        g_fd_im_zones(zi, fi) = (F_p - F_m) / (2 * fd);
    end
    fprintf('  fd=%.1f done\n', fd);
end

% 恢复 base
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});

%% 3. 均匀FD标定（混合方案需要）
fprintf('\n[3] 均匀FD标定...\n');
fd_uniform = 0.01;

model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 + fd_uniform));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_re_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 - fd_uniform));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_re_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
g_fd_re_uniform = (F_re_p - F_re_m) / (2*fd_uniform);

model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 + fd_uniform));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_im_p = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 - fd_uniform));
try model.sol.remove('sol1'); catch; end; model.study('std1').run;
F_im_m = sum(dV .* sum(abs(get_E(model,coord3) - E_truth).^2, 2));
g_fd_im_uniform = (F_im_p - F_m) / (2*fd_uniform);

re_scale = g_fd_re_uniform / sum(g_re_adj);
im_scale = g_fd_im_uniform / sum(g_im_adj);

%% 4. 核心对比
fprintf('\n############################################################\n');
fprintf('#  核心对比: 纯伴随 vs 混合 (分区ratio分布)\n');
fprintf('############################################################\n');

fprintf('\n=== 实部: 分区 ratio = Σ(adj_zone) / Σ(FD_zone) ===\n');
fprintf('  zone  r_mid   n_vox');
for fi = 1:length(fd_zones)
    fprintf('  FD(δ=%.1f)', fd_zones(fi));
end
fprintf('  纯伴随ratio  混合ratio\n');

for zi = 1:N_zones
    mask = (zone_id == zi);
    n_vox = sum(mask);
    if n_vox == 0, continue; end
    r_mid = (r_bins(zi) + r_bins(zi+1)) / 2;
    
    g_adj_zone = sum(g_re_adj(mask));  % 纯伴随
    g_hyb_zone = g_adj_zone * re_scale; % 混合 = 纯伴随 * scale
    
    fprintf('  %d    %.4f  %4d', zi, r_mid, n_vox);
    for fi = 1:length(fd_zones)
        fd_ratio_pure = g_adj_zone / max(abs(g_fd_re_zones(zi,fi)), 1e-30);
        fprintf('  %+.4f', fd_ratio_pure);
    end
    % 纯伴随ratio 和 混合ratio 的关系: 混合ratio = 纯伴随ratio * scale
    % 所以混合ratio = 纯伴随ratio * (g_fd_uniform / Σg_adj)
    % 但对于分区FD，混合ratio = g_adj_zone*scale / g_fd_zone = (纯伴随ratio) * scale
    ratio_pure = g_adj_zone / max(abs(g_fd_re_zones(zi,1)), 1e-30);
    ratio_hybrid = ratio_pure * re_scale;
    fprintf('  %+.4f     %+.4f\n', ratio_pure, ratio_hybrid);
end

fprintf('\n=== 虚部: 分区 ratio ===\n');
fprintf('  zone  r_mid   n_vox');
for fi = 1:length(fd_zones)
    fprintf('  FD(δ=%.1f)', fd_zones(fi));
end
fprintf('  纯伴随ratio  混合ratio\n');

for zi = 1:N_zones
    mask = (zone_id == zi);
    n_vox = sum(mask);
    if n_vox == 0, continue; end
    r_mid = (r_bins(zi) + r_bins(zi+1)) / 2;
    
    g_adj_zone = sum(g_im_adj(mask));
    
    fprintf('  %d    %.4f  %4d', zi, r_mid, n_vox);
    for fi = 1:length(fd_zones)
        fd_ratio_pure = g_adj_zone / max(abs(g_fd_im_zones(zi,fi)), 1e-30);
        fprintf('  %+.4f', fd_ratio_pure);
    end
    ratio_pure = g_adj_zone / max(abs(g_fd_im_zones(zi,1)), 1e-30);
    ratio_hybrid = ratio_pure * im_scale;
    fprintf('  %+.4f     %+.4f\n', ratio_pure, ratio_hybrid);
end

%% 5. 关键论证
fprintf('\n############################################################\n');
fprintf('#  论证: 混合方案是否比纯伴随多提供了信息？\n');
fprintf('############################################################\n');
fprintf('\n  纯伴随:   g_re = fsens(epsi_re)\n');
fprintf('  混合:     g_re = fsens(epsi_re) * scale\n');
fprintf('  scale = %.4f (全局常数)\n\n', re_scale);
fprintf('  对于任何分区 z:\n');
fprintf('    ratio_pure(z)   = Σfsens(z) / FD(z)\n');
fprintf('    ratio_hybrid(z) = [Σfsens(z) * scale] / FD(z)\n');
fprintf('                   = ratio_pure(z) * scale\n');
fprintf('                   = ratio_pure(z) * %.4f\n\n', re_scale);
fprintf('  → 混合方案的每个分区 ratio = 纯伴随 ratio × 全局常数\n');
fprintf('  → 空间分布形状完全相同，只是整体缩放\n');
fprintf('  → 混合方案没有比纯伴随提供更多空间信息\n');
fprintf('  → 唯一作用: 修正全局均匀偏移的绝对幅度\n');
fprintf('############################################################\n');

try ModelUtil.remove('Model'); catch; end
end

function E = get_E(model, coord3)
Ex = mphinterp(model,'emw.Ex','coord',coord3);
Ey = mphinterp(model,'emw.Ey','coord',coord3);
Ez = mphinterp(model,'emw.Ez','coord',coord3);
E = [Ex(:), Ey(:), Ez(:)];
end
