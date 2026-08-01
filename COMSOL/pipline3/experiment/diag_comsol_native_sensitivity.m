function diag_comsol_native_sensitivity(N_sample)
%DIAG_COMSOL_NATIVE_SENSITIVITY COMSOL原生伴随灵敏度分析
%   使用 COMSOL 内置的 Sensitivity 节点 + Adjoint 方法
%   COMSOL 自动用 (∂L/∂u)^T 求解——精确的伴随方程
%
%   目标函数: Q = ∫_V |E_hyp - E_truth|² dV (近场L2)
%   控制变量: eps_re, eps_im (全局参数)
%   方法: Adjoint

if nargin < 1, N_sample = 4; end

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

p = config();
grid_meas = build_measurement_grid(p);

fprintf('\n############################################################\n');
fprintf('#  COMSOL 原生伴随灵敏度分析 (N=%d)\n', N_sample);
fprintf('############################################################\n\n');

%% 1. 初始化
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[FAIL] mphstart\n'); return; end
end
try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1','ExternalCurrentDensity',3);
    phys.feature('vec1').set('Je',{'0','0','0'});
    try phys.feature('vec1').selection().all(); catch; end
end
try model.param.set('adjoint_mode','1'); catch; end

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);

%% 2. 预计算真值场（eps_r=true，作为参考场）
fprintf('预计算真值场 (eps_r=5-3j)...\n');
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 提取真值场在内部体素中心（作为目标函数参考）
[E_truth, ~, ~] = solve_forward(model, voxel, p);
fprintf('  |E_truth| mean=%.4e\n\n', mean(vecnorm(E_truth,2,2)));

%% 3. 设置初值正演（eps_r=3-1j 非均匀）
fprintf('初值正演 (eps_r=3-1j)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_init, ~, ~] = solve_forward(model, voxel, p);
fprintf('  |E_init| mean=%.4e\n\n', mean(vecnorm(E_init,2,2)));

%% 4. 设置 COMSOL 原生灵敏度分析
fprintf('配置 COMSOL 原生灵敏度分析...\n');

% 4a. 定义目标函数变量（近场L2: |E - E_truth|² 积分）
% 需要将 E_truth 存为插值函数
fprintf('  存储真值场为插值函数...\n');
func_truth_names = {'int_Et_x_re','int_Et_x_im','int_Et_y_re','int_Et_y_im','int_Et_z_re','int_Et_z_im'};
truth_pos = voxel.pos(inner_idx, :);
for d = 1:3
    for part = 1:2
        idx_fn = (d-1)*2 + part;
        fn = func_truth_names{idx_fn};
        try model.component('comp1').func(fn); catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        try model.component('comp1').func(fn).set('extrap', 'specific'); catch; end
        try model.component('comp1').func(fn).set('constval', '0'); catch; end
        if part == 1
            vals = real(E_truth(:, d));
        else
            vals = imag(E_truth(:, d));
        end
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [truth_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp);
        delete(tmp);
    end
end

% 4b. 定义积分算子（用于目标函数）
% 用 component.cpl.create 创建 Integration 算子
try
    model.component('comp1').cpl.create('intop1', 'Integration', 3);
    model.component('comp1').cpl('intop1').selection.set(find(inner));
    fprintf('  OK intop1 created\n');
catch ME
    fprintf('  intop1: %s\n', ME.message);
end

% 目标函数表达式
obj_expr = 'intop1((emw.Ex-(int_Et_x_re(x,y,z)+i*int_Et_x_im(x,y,z)))^2 + (emw.Ey-(int_Et_y_re(x,y,z)+i*int_Et_y_im(x,y,z)))^2 + (emw.Ez-(int_Et_z_re(x,y,z)+i*int_Et_z_im(x,y,z)))^2)';

% 4c. 创建全局参数作为控制变量
model.param.set('eps_re_ctrl', '3.0');
model.param.set('eps_im_ctrl', '-1.0');

% 4d. 更新 epsilon_r 使用控制变量
% 需要让内部域的 epsilon_r = eps_re_ctrl + i*eps_im_ctrl
% 但当前用插值函数... 需要改为用参数
% 简化: 先做均匀 eps_r 的灵敏度验证
fprintf('  设置均匀 eps_r = eps_re_ctrl + i*eps_im_ctrl...\n');
voxel.epsilon_r(inner) = 3.0 - 1.0i;  % 均匀初值
update_epsilon(model, voxel, p);
model.sol('sol1').runAll();
[E_init_uniform, ~, ~] = solve_forward(model, voxel, p);

%% 5. 添加 Sensitivity Study 节点
fprintf('  添加 Sensitivity 节点...\n');
study = model.study('std1');

% 删除已有的 freq step（如果有），重新设置
try study.feature().remove('sens'); catch; end

% 创建 Sensitivity study step
try
    study.feature().create('sens', 'Sensitivity');
    study.feature('sens').set('useadj', true);  % Adjoint 方法
    study.feature('sens').set('ctrlw', {'eps_re_ctrl', 'eps_im_ctrl'});
    study.feature('sens').set('objf', {obj_expr});
    fprintf('  OK Sensitivity 节点已创建\n');
catch ME
    fprintf('  FAIL 创建 Sensitivity: %s\n', ME.message);
    % 尝试备用方式
    try
        study.feature().create('sens', 'Sensitivity');
        fprintf('  OK Sensitivity 创建（基本）\n');
    catch ME2
        fprintf('  FAIL: %s\n', ME2.message);
        return;
    end
end

% intop1 已在 §4b 中创建

%% 6. 求解灵敏度
fprintf('\n求解灵敏度...\n');
try
    model.sol('sol1').clearSolution();
    model.sol('sol1').clearSolutionData();
    model.study('std1').run;
    fprintf('  OK 灵敏度求解完成\n');
catch ME
    fprintf('  FAIL: %s\n', ME.message);
    return;
end

%% 7. 提取灵敏度值
fprintf('\n提取灵敏度...\n');
try
    % fsens() 函数返回灵敏度
    sens_re = mphglobal(model, 'fsens(eps_re_ctrl)');
    sens_im = mphglobal(model, 'fsens(eps_im_ctrl)');
    fprintf('  ∂Q/∂ε_re = %+.6e\n', sens_re);
    fprintf('  ∂Q/∂ε_im = %+.6e\n', sens_im);
catch ME
    fprintf('  FAIL 提取灵敏度: %s\n', ME.message);
    % 尝试直接从解中提取
    try
        sens_re = mphinterp(model, 'fsens(eps_re_ctrl)', 'coord', [0;0;0]);
        fprintf('  fsens(eps_re) at origin = %+.6e\n', sens_re(1));
    catch ME2
        fprintf('  2nd attempt failed: %s\n', ME2.message);
    end
end

%% 8. FD 对比
fprintf('\nFD 对比...\n');
fd_delta = 0.01;

% FD 实部
voxel.epsilon_r(inner) = (3.0 + fd_delta) - 1.0i;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[Ep,~,~] = solve_forward(model, voxel, p);
F_re_p = sum(voxel.dV(inner) .* sum(abs(Ep - E_truth).^2, 2));

voxel.epsilon_r(inner) = (3.0 - fd_delta) - 1.0i;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[Em,~,~] = solve_forward(model, voxel, p);
F_re_m = sum(voxel.dV(inner) .* sum(abs(Em - E_truth).^2, 2));

g_FD_re = (F_re_p - F_re_m) / (2*fd_delta);

% FD 虚部
voxel.epsilon_r(inner) = 3.0 + (-1.0 + fd_delta)*1i;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[Ep,~,~] = solve_forward(model, voxel, p);
F_im_p = sum(voxel.dV(inner) .* sum(abs(Ep - E_truth).^2, 2));

voxel.epsilon_r(inner) = 3.0 + (-1.0 - fd_delta)*1i;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[Em,~,~] = solve_forward(model, voxel, p);
F_im_m = sum(voxel.dV(inner) .* sum(abs(Em - E_truth).^2, 2));

g_FD_im = (F_im_p - F_im_m) / (2*fd_delta);

%% 9. 输出对比
fprintf('\n############################################################\n');
fprintf('#  COMSOL 原生灵敏度 vs FD（均匀 eps_r=3-1j）\n');
fprintf('############################################################\n');
fprintf('  --- 实部 ε_re ---\n');
fprintf('    COMSOL adjoint = %+.6e\n', sens_re);
fprintf('    FD (δ=0.01)    = %+.6e\n', g_FD_re);
fprintf('    ratio           = %+.4f\n', sens_re / g_FD_re);
fprintf('    sign            = %s\n', ternary_s(sens_re*g_FD_re>0,'OK','XX'));
fprintf('  --- 虚部 ε_im ---\n');
fprintf('    COMSOL adjoint = %+.6e\n', sens_im);
fprintf('    FD (δ=0.01)    = %+.6e\n', g_FD_im);
fprintf('    ratio           = %+.4f\n', sens_im / g_FD_im);
fprintf('    sign            = %s\n', ternary_s(sens_im*g_FD_im>0,'OK','XX'));
fprintf('############################################################\n');

%% 恢复
model.param.set('adjoint_mode','1');
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try phys.feature('vec1').set('Je',{'0','0','0'}); catch; end
try study.feature().remove('sens'); catch; end

end

function s = ternary_s(cond, a, b), if cond, s=a; else, s=b; end, end
