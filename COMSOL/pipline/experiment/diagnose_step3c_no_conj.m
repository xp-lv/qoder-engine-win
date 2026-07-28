function diagnose_step3c_no_conj()
%DIAGNOSE_STEP3C 直接用 f_adj 作为 COMSOL 源（无 conj, 无 omega*mu0）
%
%   数学推导：
%     正确伴随方程: K·λ = L^H·ΔJ
%     f_adj = coeff_base · L^H · ΔJ  (build_adjoint_source 输出)
%     所以 K·λ = f_adj / coeff_base
%     λ_comsol = λ_true / coeff_base (只差全局标量)
%
%   实现：绕过 solve_adjoint，直接设 Je = f_adj（无 conj, 无缩放）
%   梯度用 -k0^2*dV*Re(conj(λ)*E) (Hermitian, 负号)

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  步骤3c: 直接源注入（无 conj, 无 omega*mu0）\n');
fprintf('#  K·λ = f_adj 直接求解\n');
fprintf('############################################################\n\n');

p = config();
grid = build_measurement_grid(p);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart: %s\n', ME.message); return;
    end
end
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end
voxel = fem_mesh_utils(model, p, p.a_scatter);

eps_r_test = 4.0; hole_pos_test = [0.015; 0.010; 0.005];
delta_sdf = 0.008;
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);
inner_idx = find(inner_mask);

%% 预计算 J_obs
fprintf('[S3c] 预计算 J_obs...\n');
voxel_truth = voxel;
d_true = sqrt(sum((inner_pos - [0.03;0.02;0.01]').^2, 2));
voxel_truth.epsilon_r(inner_mask) = 5.0 + (1.0-5.0)*0.5*(1-tanh(d_true/delta_sdf));
update_epsilon(model, voxel_truth, p);
pf0 = p; pf0.freq=1e9; pf0.omega=2*pi*pf0.freq; pf0.k0=pf0.omega/p.c; pf0.lambda=p.c/pf0.freq;
model.param.set('freq', num2str(pf0.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', pf0.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
sf = extract_scattered(model, grid);
J_obs = lightcone_project(grid, sf, pf0).J_obs_perp;

%% 步骤2 体素 FD 值
g_FD_data = [
    1,   -3.7168e-12;  161, -6.2773e-12;
    200, -5.0570e-12;  279, -6.3642e-11;
    285, -3.9691e-11;  326, -1.4808e-11;
    338, -1.8900e-11;  415, -2.4140e-11;
    426, -1.5098e-11;  502, -3.7414e-11;
    513, -7.8376e-12;  673, +1.7544e-13;
];
N_sel = size(g_FD_data, 1);
sel_voxels = g_FD_data(:, 1);
g_FD_vals = g_FD_data(:, 2);

%% 正演
fprintf('\n[S3c] 正演...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

%% 伴随源
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj = Js + Ms;
fprintf('[S3c] |f_adj| mean=%.4e\n', mean(vecnorm(f_adj, 2, 2)));

%% ★ 手动设置 COMSOL 源（绕过 solve_adjoint 的 conj 约定）★
fprintf('[S3c] 手动注入源（无 conj, 无 omega*mu0）...\n');
phys = model.physics('emw');
inner = voxel.mask_interior;

% 写入 f_adj 作为 ExternalCurrentDensity 的 Je
% 旧路径写入的是 -real + i*imag = -conj 约定
% 新路径直接写入 real + i*imag = f_adj 本身（无 conj）

func_names = {'int_adj_x_re','int_adj_x_im', ...
              'int_adj_y_re','int_adj_y_im', ...
              'int_adj_z_re','int_adj_z_im'};

for d = 1:3
    for part = 1:2
        fn = func_names{(d-1)*2+part};
        try model.component('comp1').func(fn);
        catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        if part == 1
            vals = real(f_adj(:, d));     % 直接用 real（不加负号）
        else
            vals = imag(f_adj(:, d));     % 直接用 imag
        end
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [source_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp);
        delete(tmp);
    end
end

% Je 表达式：(int_adj_re + i*int_adj_im)，无 /(omega*mu0)
try phys.feature('vec1');
catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
end
try phys.feature('vec1').selection().all(); catch, end

% 归零 sc_adj 和 ms_adj（如果存在）
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end

Je_x = '(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))';
Je_y = '(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))';
Je_z = '(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))';
phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});

% 零背景场
model.param.set('adjoint_mode', '0');
fprintf('  OK vec1 set to f_adj directly (no conj, no omega*mu0)\n');

% 求解
try
    model.sol('sol1').runAll();
    fprintf('  OK solve completed\n');
catch ME
    fprintf('  FAIL solve: %s\n', ME.message); return;
end

% 提取 lambda（不取共轭！）
[lambda, ~] = read_field(model, voxel.pos(inner, :));
fprintf('[S3c] lambda: |mean|=%.4e\n', mean(vecnorm(lambda, 2, 2)));

% Gauss 点
if ~isempty(voxel.gauss_pos)
    [lambda_gauss, ~] = read_field(model, voxel.gauss_pos);
else
    lambda_gauss = [];
end

% 恢复模型
model.param.set('adjoint_mode', '1');
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end

%% 梯度公式：-k0^2*dV*Re(conj(lambda)*E)（数学推导的正确公式）
k0_sq = pf.k0^2; dV_vec = voxel.dV;
E_sel = E_total(sel_voxels, :);
lambda_sel = lambda(sel_voxels, :);
dV_sel = dV_vec(inner_idx(sel_voxels));

% Hermitian: Re(conj(lambda)*E) = Re(dot(E,lambda)) in MATLAB
g_herm_neg = -k0_sq .* dV_sel .* real(sum(conj(lambda_sel) .* E_sel, 2));
% Bilinear: Re(lambda.*E)
g_bil_neg = -k0_sq .* dV_sel .* real(sum(lambda_sel .* E_sel, 2));
% Im forms
g_im_herm_neg = -k0_sq .* dV_sel .* imag(sum(conj(lambda_sel) .* E_sel, 2));
g_im_bil_neg = -k0_sq .* dV_sel .* imag(sum(lambda_sel .* E_sel, 2));

signs_FD = sign(g_FD_vals);

% 测试所有 4 种
all_g = [g_herm_neg, g_bil_neg, g_im_herm_neg, g_im_bil_neg];
modes = {'-Re(her)', '-Re(bil)', '-Im(her)', '-Im(bil)'};

fprintf('\n############################################################\n');
fprintf('#  步骤3c 结果\n');
fprintf('############################################################\n');
fprintf('#  体素  g_FD          -Re(her)   -Re(bil)   -Im(her)   -Im(bil)\n');
for vi = 1:N_sel
    fprintf('#  %3d   %+.2e  ', sel_voxels(vi), g_FD_vals(vi));
    for mi = 1:4
        s = sign(all_g(vi, mi));
        match = 'Y'; if s ~= signs_FD(vi), match = 'N'; end
        fprintf(' %+.1e(%s)', all_g(vi, mi), match);
    end
    fprintf('\n');
end

fprintf('#\n#  sign 匹配数:\n');
for mi = 1:4
    n = sum(sign(all_g(:, mi)) == signs_FD);
    fprintf('#    %s: %d/%d\n', modes{mi}, n, N_sel);
end

best_n = 0; best_mode = '';
for mi = 1:4
    n = sum(sign(all_g(:, mi)) == signs_FD);
    if n > best_n, best_n = n; best_mode = modes{mi}; end
end
fprintf('#\n#  最佳: %s (%d/%d)\n', best_mode, best_n, N_sel);
if best_n == N_sel
    fprintf('#  *** 全部 12 个体素 sign 一致！伴随场正确！***\n');
else
    fprintf('#  部分不一致\n');
end
fprintf('############################################################\n');
end
