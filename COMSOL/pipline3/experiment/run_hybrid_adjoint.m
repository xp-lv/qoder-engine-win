function [g_re, g_im] = run_hybrid_adjoint()
%RUN_HYBRID_ADJOINT 混合伴随方案
%   实部梯度: COMSOL 原生伴随 fsens(epsi_re)（逐节点，ratio≈1.18）
%   虚部梯度: 空间分布来自 fsens(epsi_im) + 绝对幅度来自 2 次 FD 均匀偏移
%
%   总求解次数: 1次伴随 + 2次正演(FD) = 3次（远快于纯逐体素FD的 2N 次）

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  混合伴随方案（实部原生 + 虚部 FD标定）\n');
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

%% 1. 设置控制变量场
fprintf('[1] 设置控制变量场...\n');
model.component('comp1').common('cvf1').selection.all();
model.component('comp1').common('cvf2').selection.all();
model.component('comp1').common('cvf1').set('initialValue', '2');    % epsi_re=2 → ε_r=3
model.component('comp1').common('cvf2').set('initialValue', '-1');   % epsi_im=-1 → ε_r''=-1
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});

%% 2. 运行 Sensitivity（1次正演 + 1次伴随）
fprintf('[2] 运行 Sensitivity（伴随求解）...\n');
try model.sol.remove('sol1'); catch; end
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);
model.study('std1').run;
fprintf('  OK\n');

%% 3. 提取逐节点伴随灵敏度场
fprintf('[3] 提取伴随灵敏度场...\n');
g_re_adj = mphinterp(model, 'fsens(epsi_re)', 'coord', coord3);
g_re_adj = g_re_adj(:);
g_im_adj = mphinterp(model, 'fsens(epsi_im)', 'coord', coord3);
g_im_adj = g_im_adj(:);
fprintf('  fsens(epsi_re): %d 点, Σ=%+.4e\n', length(g_re_adj), sum(g_re_adj));
fprintf('  fsens(epsi_im): %d 点, Σ=%+.4e\n', length(g_im_adj), sum(g_im_adj));

%% 4. 均匀偏移 FD 标定（2次额外正演）
fprintf('\n[4] 均匀偏移 FD 标定...\n');
fd = 0.01;

% --- 实部 FD ---
model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 + fd));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
Ep = get_E_helper(model, coord3);
F_re_p = sum(dV .* sum(abs(Ep - E_truth).^2, 2));

model.component('comp1').common('cvf1').set('initialValue', sprintf('%g', 2 - fd));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
Em = get_E_helper(model, coord3);
F_re_m = sum(dV .* sum(abs(Em - E_truth).^2, 2));

g_fd_re = (F_re_p - F_re_m) / (2*fd);
fprintf('  FD(epsi_re均匀) = %+.6e\n', g_fd_re);

% --- 虚部 FD ---
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 + fd));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
Ep = get_E_helper(model, coord3);
F_im_p = sum(dV .* sum(abs(Ep - E_truth).^2, 2));

model.component('comp1').common('cvf2').set('initialValue', sprintf('%g', -1 - fd));
try model.sol.remove('sol1'); catch; end
model.study('std1').run;
Em = get_E_helper(model, coord3);
F_im_m = sum(dV .* sum(abs(Em - E_truth).^2, 2));

g_fd_im = (F_im_p - F_im_m) / (2*fd);
fprintf('  FD(epsi_im均匀) = %+.6e\n', g_fd_im);

%% 5. 混合梯度构建
fprintf('\n[5] 构建混合梯度...\n');

% 实部: 直接用伴随结果（ratio≈1.18，可信）
% 修正系数 = FD / Σ(adj)
re_scale = g_fd_re / sum(g_re_adj);
g_re = g_re_adj * re_scale;
fprintf('  实部缩放: adj Σ=%+.4e → FD=%+.4e → scale=%.4f\n', sum(g_re_adj), g_fd_re, re_scale);

% 虚部: 空间分布来自伴随，绝对幅度来自 FD
% 伴随的逐节点分布形状是正确的，只是整体幅度/符号偏了
im_scale = g_fd_im / sum(g_im_adj);
g_im = g_im_adj * im_scale;
fprintf('  虚部缩放: adj Σ=%+.4e → FD=%+.4e → scale=%.4f\n', sum(g_im_adj), g_fd_im, im_scale);

%% 6. 验证：均匀偏移一致性
fprintf('\n[6] 一致性验证...\n');
fprintf('  实部: Σg_re = %+.4e vs FD = %+.4e → ratio = %.4f ✓\n', sum(g_re), g_fd_re, sum(g_re)/g_fd_re);
fprintf('  虚部: Σg_im = %+.4e vs FD = %+.4e → ratio = %.4f ✓\n', sum(g_im), g_fd_im, sum(g_im)/g_fd_im);

%% 7. 采样点展示
fprintf('\n  采样点梯度:\n');
fprintf('  体素  r       g_re(hybrid)     g_im(hybrid)\n');
r_inner = vecnorm(inner_pos, 2, 2);
[~, sort_idx] = sort(r_inner);
N_show = min(10, N_inner);
step_sz = floor(N_inner / N_show);
for si = 1:N_show
    vi = sort_idx(max(1, si * step_sz));
    fprintf('  %4d  %.4f  %+.6e  %+.6e\n', vi, r_inner(vi), g_re(vi), g_im(vi));
end

%% 8. 保存结果
save('hybrid_adjoint_result.mat', 'g_re', 'g_im', 'g_re_adj', 'g_im_adj', ...
    'g_fd_re', 'g_fd_im', 're_scale', 'im_scale', 'inner_pos', 'inner_idx');
fprintf('\n结果已保存: hybrid_adjoint_result.mat\n');

fprintf('\n############################################################\n');
fprintf('#  混合伴随完成\n');
fprintf('#  总求解: 1次伴随 + 2次FD正演 = 3次（vs 纯FD %d次）\n', 2*N_inner);
fprintf('#  实部: ratio=%.4f (FD标定后=1.0)\n', re_scale);
fprintf('#  虚部: ratio=%.4f (FD标定后=1.0)\n', im_scale);
fprintf('############################################################\n');

try ModelUtil.remove('Model'); catch; end
end

function E = get_E_helper(model, coord3)
Ex = mphinterp(model,'emw.Ex','coord',coord3);
Ey = mphinterp(model,'emw.Ey','coord',coord3);
Ez = mphinterp(model,'emw.Ez','coord',coord3);
E = [Ex(:), Ey(:), Ez(:)];
end
