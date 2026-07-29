function plot_gradient_3d(eps_mean_init)
%PLOT_GRADIENT_3D 绘制伴随法梯度的三维点云图
%
%   设非均匀初值 eps_r = eps_mean_init + grad_amp*x/R（沿 x 方向梯度）
%   正演 + 伴随求解 → 逐体素梯度 g(v)
%   画 g(v) 的 3D 散点图
%
%   用法：
%     >> plot_gradient_3d(4.5)

if nargin < 1, eps_mean_init = 4.5; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  伴随梯度 3D 点云图\n');
fprintf('#  初值: mean=%.1f + 梯度, 真值: eps_r=5.0\n', eps_mean_init);
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);

fprintf('[GRAD] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[GRAD] [FAIL] mphstart: %s\n', ME.message); return;
    end
end

try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

fprintf('[GRAD] 加载 2layer.mph...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end

%% 2. 提取网格
fprintf('[GRAD] 提取 FEM 网格...\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
pos = voxel.pos(inner_idx, :);  % [N_inner x 3]
fprintf('[GRAD] N_inner = %d\n', N_inner);

%% 3. 预计算 J_obs（真值 eps_r=5）
fprintf('[GRAD] 预计算 J_obs (eps_r=5.0)...\n');
voxel.epsilon_r(inner) = p.eps_r_true;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

sf_obs = extract_scattered(model, grid_meas);
lc_obs = lightcone_project(grid_meas, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min, F_obs = 1.0; end

%% 4. 设正弦波动初值（x 方向，中值=eps_mean_init，振幅=1.0）
% eps_r(x) = eps_mean_init + 1.0 * sin(2*pi*x / lambda_eps)
% lambda_eps = R_inner（一个完整周期跨半个球）
x_pos = pos(:,1);
sin_amp = 1.0;  % 振幅：eps_r 在 [4, 6] 范围内波动
eps_init = eps_mean_init + sin_amp * sin(pi * x_pos / p.R_inner);
voxel.epsilon_r(inner) = eps_init;
fprintf('[GRAD] 正弦初值: eps_r = %.1f + %.1f*sin(pi*x/R), range [%.3f, %.3f], mean=%.3f\n', ...
    eps_mean_init, sin_amp, min(eps_init), max(eps_init), mean(eps_init));

%% 5. 正演 + 伴随
fprintf('[GRAD] 正演...\n');
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

sf = extract_scattered(model, grid_meas);
lc = lightcone_project(grid_meas, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
F = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs;
fprintf('[GRAD] F = %.6e\n', F);

lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid_meas, lc, p);

fprintf('[GRAD] 伴随求解...\n');
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
if ~ok_adj
    fprintf('[GRAD] [FAIL] solve_adjoint\n'); return;
end

%% 6. 逐体素梯度
k0_sq = p.k0^2;
dV_vec = voxel.dV;
g_voxel = zeros(N_inner, 1);

use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && size(E_gauss,1) == size(voxel.gauss_pos,1);

if use_gauss
    gw = voxel.gauss_w;
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gw(gpi) * real(sum(E_gauss(gp(gpi),:) .* lambda_gauss(gp(gpi),:)));
        end
        g_voxel(vi) = -k0_sq * dV_vec(inner_idx(vi)) * gs;
    end
else
    for vi = 1:N_inner
        g_voxel(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(sum(E_total(vi,:) .* lambda(vi,:)));
    end
end
g_voxel = g_voxel / F_obs;

fprintf('[GRAD] 梯度统计: range [%.4e, %.4e], mean=%.4e\n', ...
    min(g_voxel), max(g_voxel), mean(g_voxel));

%% 7. 绘图
figure('Position', [50, 50, 1400, 500], 'Color', 'w');

% 子图 1: 梯度 3D 点云
subplot(1, 3, 1);
scatter3(pos(:,1)*1000, pos(:,2)*1000, pos(:,3)*1000, 20, g_voxel, 'filled');
colorbar;
colormap(jet);
c = max(abs(min(g_voxel)), abs(max(g_voxel)));
caxis([-c, c]);  % 对称色标
title(sprintf('Adjoint Gradient g(v)\nmean_{\\epsilon}=%.1f, F=%.4f', eps_mean_init, F), 'FontSize', 10);
xlabel('x [mm]'); ylabel('y [mm]'); zlabel('z [mm]');
axis equal; view(30, 25);

% 子图 2: 初值 eps_r 3D 点云
subplot(1, 3, 2);
scatter3(pos(:,1)*1000, pos(:,2)*1000, pos(:,3)*1000, 20, eps_init, 'filled');
colorbar;
colormap(jet);
caxis([1, 8]);
title(sprintf('Initial \\epsilon_r\nrange=[%.2f, %.2f], mean=%.2f', ...
    min(eps_init), max(eps_init), mean(eps_init)), 'FontSize', 10);
xlabel('x [mm]'); ylabel('y [mm]'); zlabel('z [mm]');
axis equal; view(30, 25);

% 子图 3: 梯度 vs x（分 bin）
subplot(1, 3, 3);
x_vals = pos(:,1);
x_bins = linspace(min(x_vals), max(x_vals), 15);
x_centers = (x_bins(1:end-1) + x_bins(2:end)) / 2;
g_mean_x = zeros(size(x_centers));
g_std_x = zeros(size(x_centers));
for bi = 1:length(x_centers)
    mask = x_vals >= x_bins(bi) & x_vals < x_bins(bi+1);
    if sum(mask) > 0
        g_mean_x(bi) = mean(g_voxel(mask));
        g_std_x(bi) = std(g_voxel(mask));
    end
end
errorbar(x_centers*1000, g_mean_x, g_std_x, 'b-o', 'LineWidth', 1.5);
hold on;
yline(0, 'k--', 'LineWidth', 1);
xlabel('x [mm]'); ylabel('g(v)');
title('Gradient vs x (mean \pm std)', 'FontSize', 10);
grid on;

% 保存
img_path = fullfile(p.dir_result, sprintf('gradient_3d_mean%.1f.png', eps_mean_init));
saveas(gcf, img_path);
fprintf('\n[GRAD] 图片已保存: %s\n', img_path);

% 恢复模型
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model.param.set('adjoint_mode', '1'); catch, end

end
