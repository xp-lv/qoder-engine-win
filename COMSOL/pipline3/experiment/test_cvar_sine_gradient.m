function test_cvar_sine_gradient()
%TEST_CVAR_SINE_GRADIENT COMSOL原生伴随梯度可视化
%   真值: ε_r = 5 - 2j
%   初值: ε_re = 4 + 2*sin(pi*x/R), ε_im = -2 + sin(pi*y/R)
%   画出: 初值实部/虚部体素图 + 梯度实部/虚部体素图

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  COMSOL原生伴随梯度可视化（正弦初值）\n');
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
coord3 = inner_pos';
R = p.R_inner;

%% 1. 重新生成真值场 CSV（ε_r = 5 - 2j）
fprintf('[1] 重新生成真值场 (ε_r=5-2j)...\n');
% 用原始的 update_epsilon + solve_forward 流程
voxel.epsilon_r = ones(size(voxel.mask_interior));
voxel.epsilon_r(inner) = 5.0 - 2.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol.remove('sol1'); catch; end
try model.study('std1').feature('sens').active(false); catch; end
model.study('std1').run;

% 提取真值场
E_truth = get_E(model, coord3);
fprintf('  |E_truth| mean=%.4e\n', mean(vecnorm(E_truth,2,2)));

% 重新导出 CSV
func_names = {'int3','int4','int5','int6','int7','int8'};
field_names = {'int_Et_x_re','int_Et_x_im','int_Et_y_re','int_Et_y_im','int_Et_z_re','int_Et_z_im'};
for d = 1:3
    for part = 1:2
        idx = (d-1)*2 + part;
        fn = func_names{idx};
        fn_name = field_names{idx};
        try model.component('comp1').func(fn); catch
            model.component('comp1').func.create(fn, 'Interpolation');
        end
        model.component('comp1').func(fn).set('funcname', fn_name);
        model.component('comp1').func(fn).set('nargs', '3');
        model.component('comp1').func(fn).set('source', 'table');
        try model.component('comp1').func(fn).set('extrap', 'specific'); catch; end
        try model.component('comp1').func(fn).set('constval', '0'); catch; end
        if part == 1
            vals = real(E_truth(:,d));
        else
            vals = imag(E_truth(:,d));
        end
        tmp_csv = [tempname, '.csv'];
        dlmwrite(tmp_csv, [inner_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp_csv);
        delete(tmp_csv);
    end
end
fprintf('  OK 真值场CSV已更新\n');

%% 2. 设置正弦初值
fprintf('\n[2] 设置正弦初值...\n');
% ε_re_init = 4 + 2*sin(pi*x/R)  → 范围 [2, 6]
% ε_im_init = -2 + 1*sin(pi*y/R) → 范围 [-3, -1]
x = inner_pos(:,1);
y = inner_pos(:,2);
eps_re_init = 4 + 2*sin(pi*x / R);
eps_im_init = -2 + 1*sin(pi*y / R);

% 用插值函数设置非均匀初值
% 控制变量场的 initialValue 只支持常数表达式
% 需要用插值函数作为初值 → 设 initialValue = eps_init_re(x,y,z)
fn_init_re = 'einit_re';
fn_init_im = 'einit_im';
fn_list = {fn_init_re, fn_init_im};
for fi = 1:2
    fn = fn_list{fi};
    try model.component('comp1').func(fn); catch
        model.component('comp1').func.create(fn, 'Interpolation');
    end
    model.component('comp1').func(fn).set('funcname', fn);
    model.component('comp1').func(fn).set('nargs', '3');
    model.component('comp1').func(fn).set('source', 'table');
    try model.component('comp1').func(fn).set('extrap', 'specific'); catch; end
    try model.component('comp1').func(fn).set('constval', '1'); catch; end
    if fi == 1
        vals = eps_re_init;
    else
        vals = eps_im_init;
    end
    tmp_csv = [tempname, '.csv'];
    dlmwrite(tmp_csv, [inner_pos, vals(:)]);
    model.component('comp1').func(fn).importData(tmp_csv);
    delete(tmp_csv);
end

% 设置控制变量场初值
model.component('comp1').common('cvf1').selection.all();
model.component('comp1').common('cvf2').selection.all();
model.component('comp1').common('cvf1').set('initialValue', sprintf('%s(x,y,z) - 1', fn_init_re));
model.component('comp1').common('cvf2').set('initialValue', sprintf('%s(x,y,z)', fn_init_im));
% ε_r = 1 + epsi_re + i*epsi_im = 1 + (einit_re-1) + i*einit_im = einit_re + i*einit_im
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});
fprintf('  ε_re: [%.1f, %.1f], ε_im: [%.1f, %.1f]\n', ...
    min(eps_re_init), max(eps_re_init), min(eps_im_init), max(eps_im_init));

%% 3. 运行 COMSOL 原生伴随
fprintf('\n[3] 运行 COMSOL 原生伴随...\n');
obj_expr = 'comp1.intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';

try model.sol.remove('sol1'); catch; end
try model.study('std1').feature('sens').active(true); catch; end
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);
model.study('std1').run;
fprintf('  OK\n');

% 提取梯度
g_re = mphinterp(model, 'fsens(epsi_re)', 'coord', coord3); g_re = g_re(:);
g_im = mphinterp(model, 'fsens(epsi_im)', 'coord', coord3); g_im = g_im(:);
fprintf('  g_re: [%.4e, %.4e], Σ=%+.4e\n', min(g_re), max(g_re), sum(g_re));
fprintf('  g_im: [%.4e, %.4e], Σ=%+.4e\n', min(g_im), max(g_im), sum(g_im));

%% 4. 画图
fprintf('\n[4] 绘图...\n');
r_vox = vecnorm(inner_pos, 2, 2);

figure('Position', [100 100 1400 900], 'Color', 'w');

% --- Row 1: 初值 ---
% 实部
subplot(2,2,1);
scatter3(inner_pos(:,1), inner_pos(:,2), inner_pos(:,3), 15, eps_re_init, 'filled');
colorbar; colormap jet;
xlabel('x'); ylabel('y'); zlabel('z');
title(sprintf('初值 \\epsilon_r'' (真值=5)\n[%.1f, %.1f]', min(eps_re_init), max(eps_re_init)));
view(3); grid on;

% 虚部
subplot(2,2,2);
scatter3(inner_pos(:,1), inner_pos(:,2), inner_pos(:,3), 15, eps_im_init, 'filled');
colorbar; colormap jet;
xlabel('x'); ylabel('y'); zlabel('z');
title(sprintf('初值 \\epsilon_r'''' (真值=-2)\n[%.1f, %.1f]', min(eps_im_init), max(eps_im_init)));
view(3); grid on;

% --- Row 2: 梯度 ---
% 实部梯度
subplot(2,2,3);
scatter3(inner_pos(:,1), inner_pos(:,2), inner_pos(:,3), 15, g_re, 'filled');
colorbar; colormap jet;
xlabel('x'); ylabel('y'); zlabel('z');
title(sprintf('梯度 dQ/d\\epsilon_r''\n[%.2e, %.2e], \\Sigma=%+.2e', min(g_re), max(g_re), sum(g_re)));
view(3); grid on;

% 虚部梯度
subplot(2,2,4);
scatter3(inner_pos(:,1), inner_pos(:,2), inner_pos(:,3), 15, g_im, 'filled');
colorbar; colormap jet;
xlabel('x'); ylabel('y'); zlabel('z');
title(sprintf('梯度 dQ/d\\epsilon_r''''\n[%.2e, %.2e], \\Sigma=%+.2e', min(g_im), max(g_im), sum(g_im)));
view(3); grid on;

sgtitle('COMSOL 原生伴随梯度（正弦初值 \epsilon_r = 4+2sin(\pix/R) - i(2-sin(\piy/R))）', 'FontSize', 14);

% 保存图片
saveas(gcf, 'native_adjoint_sine_gradient.png');
fprintf('  图已保存: native_adjoint_sine_gradient.png\n');

%% 5. 额外：径向分布图
figure('Position', [100 100 1000 400], 'Color', 'w');

subplot(1,2,1);
scatter(r_vox, eps_re_init, 10, 'b', 'filled'); hold on;
scatter(r_vox, g_re*1e5 + 5, 10, 'r', 'filled');  % 缩放梯度叠加在真值=5线上
yline(5, 'k--', '真值=5');
xlabel('r (m)'); ylabel('值');
legend('初值 \epsilon_r''', '梯度×10^5+5', 'Location', 'best');
title('实部: 初值 vs 梯度（径向）');
grid on;

subplot(1,2,2);
scatter(r_vox, eps_im_init, 10, 'b', 'filled'); hold on;
scatter(r_vox, g_im*1e5 - 2, 10, 'r', 'filled');
yline(-2, 'k--', '真值=-2');
xlabel('r (m)'); ylabel('值');
legend('初值 \epsilon_r''''', '梯度×10^5-2', 'Location', 'best');
title('虚部: 初值 vs 梯度（径向）');
grid on;

sgtitle('径向分布: 初值 vs 伴随梯度', 'FontSize', 14);
saveas(gcf, 'native_adjoint_sine_radial.png');
fprintf('  径向图已保存: native_adjoint_sine_radial.png\n');

%% 6. 保存数据
save('sine_gradient_data.mat', 'eps_re_init', 'eps_im_init', 'g_re', 'g_im', 'inner_pos', 'r_vox');
fprintf('\n数据已保存: sine_gradient_data.mat\n');

%% 恢复
model.param.set('adjoint_mode', '1');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end

fprintf('\n############################################################\n');
try ModelUtil.remove('Model'); catch; end
end

function E = get_E(model, coord3)
Ex = mphinterp(model,'emw.Ex','coord',coord3);
Ey = mphinterp(model,'emw.Ey','coord',coord3);
Ez = mphinterp(model,'emw.Ez','coord',coord3);
E = [Ex(:), Ey(:), Ez(:)];
end
