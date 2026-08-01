function diag_inspect_sensitive()
% 诊断并修复 2layer_sensitive.mph

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

mphstart(p.comsol_port);
try; ts=ModelUtil.tags(); for i=1:length(ts), ModelUtil.remove(char(ts(i))); end; catch; end

model = mphload('2layer_sensitive.mph');
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end

fprintf('\n=== 模型信息 ===\n');
% Study features
st = model.study('std1');
ftags = st.feature().tags();
fprintf('Study features: ');
for i=1:length(ftags), fprintf('%s ', char(ftags(i))); end
fprintf('\n');

% intop1
try
    sel = model.component('comp1').cpl('intop1').selection();
    try; s = sel.set(); fprintf('intop1 selection: %s\n', mat2str(s)); catch; fprintf('intop1 selection: (all)\n'); end
catch; end

%% 关键修复: 删除旧 solver，让 study.run 自动重建（注册 intop1）
fprintf('\n=== 删除旧 solver + study.run ===\n');
try
    model.sol.remove('sol1');
    fprintf('  旧 solver 已删除\n');
catch ME
    fprintf('  sol.remove: %s\n', ME.message);
end

fprintf('  运行 study.run (自动生成新 solver)...\n');
try
    model.study('std1').run;
    fprintf('  study.run OK\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

%% 提取灵敏度
fprintf('\n=== 灵敏度 ===\n');
try
    sr = mphglobal(model, 'fsens(eps_re_ctrl)');
    si = mphglobal(model, 'fsens(eps_im_ctrl)');
    fprintf('  fsens(eps_re_ctrl) = %+.6e\n', sr);
    fprintf('  fsens(eps_im_ctrl) = %+.6e\n', si);
catch ME
    fprintf('  FAIL fsens: %s\n', ME.message);
end

%% FD 对比
fprintf('\n=== FD 对比 ===\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner);
dV = voxel.dV(inner_idx);

% 加载真值场
tmp = dlmread('Et_x_re.csv'); Etx = tmp(:,4);
tmp = dlmread('Et_x_im.csv'); Etx = Etx + 1i*tmp(:,4);
tmp = dlmread('Et_y_re.csv'); Ety = tmp(:,4);
tmp = dlmread('Et_y_im.csv'); Ety = Ety + 1i*tmp(:,4);
tmp = dlmread('Et_z_re.csv'); Etz = tmp(:,4);
tmp = dlmread('Et_z_im.csv'); Etz = Etz + 1i*tmp(:,4);
E_truth = [Etx, Ety, Etz];

% 当前 eps_r 正演
fprintf('  正演 eps_re=3, eps_im=-1...\n');
[E_hyp,~,~] = solve_forward(model, voxel, p);
F_base = sum(dV .* sum(abs(E_hyp - E_truth).^2, 2));
fprintf('  F_base = %.6e\n', F_base);

% FD re
fd = 0.01;
model.param.set('eps_re_ctrl', '3.1');
[E_p,~,~] = solve_forward(model, voxel, p);
F_p = sum(dV .* sum(abs(E_p - E_truth).^2, 2));

model.param.set('eps_re_ctrl', '2.9');
[E_m,~,~] = solve_forward(model, voxel, p);
F_m = sum(dV .* sum(abs(E_m - E_truth).^2, 2));
g_fd_re = (F_p - F_m) / (2*fd);

% FD im
model.param.set('eps_re_ctrl', '3');
model.param.set('eps_im_ctrl', '-0.9');
[E_p,~,~] = solve_forward(model, voxel, p);
F_p = sum(dV .* sum(abs(E_p - E_truth).^2, 2));

model.param.set('eps_im_ctrl', '-1.1');
[E_m,~,~] = solve_forward(model, voxel, p);
F_m = sum(dV .* sum(abs(E_m - E_truth).^2, 2));
g_fd_im = (F_p - F_m) / (2*fd);

%% 输出
fprintf('\n############################################################\n');
fprintf('  re: sens=%+.6e  FD=%+.6e  ratio=%+.4f\n', sr, g_fd_re, sr/g_fd_re);
fprintf('  im: sens=%+.6e  FD=%+.6e  ratio=%+.4f\n', si, g_fd_im, si/g_fd_im);
fprintf('############################################################\n');

try ModelUtil.remove('Model'); catch; end
end
