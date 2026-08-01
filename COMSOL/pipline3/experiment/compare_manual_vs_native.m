function compare_manual_vs_native()
%COMPARE_MANUAL_VS_NATIVE 手动伴随(体积源注入) vs COMSOL原生fsens 对比
%
%   手动伴随: 体积伴随源注入 → COMSOL runAll → 提取λ → 计算梯度
%   原生伴随: fsens(epsi_re), fsens(epsi_im) 直接提取
%
%   两者都用同一个COMSOL模型、同一个网格、同一个FEM离散化
%   如果结果一致 → 手动伴随是正确的（之前FD验证不准是FD的问题）
%   如果不一致 → 需要排查差异来源

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
p = config();

fprintf('\n############################################################\n');
fprintf('#  手动体积伴随 vs COMSOL原生fsens 直接对比\n');
fprintf('#  两者用同一个FEM网格，不经过FD\n');
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

%% ========== A. COMSOL原生fsens ==========
fprintf('=== A. COMSOL原生fsens ===\n');
model.component('comp1').common('cvf1').selection.all();
model.component('comp1').common('cvf2').selection.all();
model.component('comp1').common('cvf1').set('initialValue', '2');
model.component('comp1').common('cvf2').set('initialValue', '-1');
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'1 + epsi_re + i*epsi_im'});
try model.sol.remove('sol1'); catch; end
model.study('std1').feature('sens').setIndex('optobj', obj_expr, 0);
model.study('std1').run;

g_re_native = mphinterp(model, 'fsens(epsi_re)', 'coord', coord3); g_re_native = g_re_native(:);
g_im_native = mphinterp(model, 'fsens(epsi_im)', 'coord', coord3); g_im_native = g_im_native(:);
fprintf('  fsens(epsi_re): Σ=%+.6e, mean=%.4e\n', sum(g_re_native), mean(abs(g_re_native)));
fprintf('  fsens(epsi_im): Σ=%+.6e, mean=%.4e\n', sum(g_im_native), mean(abs(g_im_native)));

%% ========== B. 手动体积伴随 ==========
fprintf('\n=== B. 手动体积伴随 ===\n');

% B1. 正演：ε_r = 3 - 1j（均匀），用全局参数控制
fprintf('  [B1] 正演 ε_r=3-1j...\n');
phys.feature('wee1').set('epsilonr_mat', 'userdef');
phys.feature('wee1').set('epsilonr', {'3 - 1*i'});
model.param.set('eps_re_ctrl', '3');
model.param.set('eps_im_ctrl', '-1');
model.param.set('adjoint_mode', '1');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end

% 用 study.run 重新求解（保留 sensitivity 节点但会走 freq 路径）
try model.sol.remove('sol1'); catch; end
model.study('std1').run;

% 提取正演场 E_hyp
E_hyp = get_E(model, coord3);
fprintf('  |E_hyp| mean=%.4e\n', mean(vecnorm(E_hyp, 2, 2)));

% 残差
residual = E_hyp - E_truth;
F_norm = sum(dV .* sum(abs(E_truth).^2, 2));
if F_norm < 1e-30, F_norm = 1; end
fprintf('  F_norm=%.4e\n', F_norm);

% B2. 构建伴随源（近场L2的Wirtinger导数）
fprintf('  [B2] 构建伴随源...\n');
% ∂F/∂E(v) = 2*conj(E_hyp - E_truth) / F_norm
dF_dE = (2 / F_norm) .* conj(residual);  % [N_inner × 3]

% 伴随源 Je = dF_dE / (iωμ₀) （COMSOL ExternalCurrentDensity 约定）
omega_mu0 = p.omega * p.mu0;
Je = dF_dE / (1i * omega_mu0);

% B3. 注入伴随源到 COMSOL
fprintf('  [B3] 注入伴随源...\n');
adj_func_names = {'adj_x_re','adj_x_im','adj_y_re','adj_y_im','adj_z_re','adj_z_im'};
for d = 1:3
    for part = 1:2
        idx_fn = (d-1)*2 + part;
        fn = adj_func_names{idx_fn};
        try model.component('comp1').func(fn); catch
            model.component('comp1').func.create(fn, 'Interpolation');
        end
        model.component('comp1').func(fn).set('nargs', '3');
        model.component('comp1').func(fn).set('source', 'table');
        try model.component('comp1').func(fn).set('extrap', 'specific'); catch; end
        try model.component('comp1').func(fn).set('constval', '0'); catch; end
        if part == 1
            vals = real(Je(:, d));
        else
            vals = imag(Je(:, d));
        end
        tmp_csv = [tempname, '.csv'];
        dlmwrite(tmp_csv, [inner_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp_csv);
        delete(tmp_csv);
    end
end

% 配置 ExternalCurrentDensity
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    try phys.feature('vec1').selection().all(); catch; end
end
phys.feature('vec1').set('Je', ...
    {'(adj_x_re(x,y,z) + i*adj_x_im(x,y,z))', ...
     '(adj_y_re(x,y,z) + i*adj_y_im(x,y,z))', ...
     '(adj_z_re(x,y,z) + i*adj_z_im(x,y,z))'});

% B4. 伴随求解（归零背景场，只求解伴随源产生的场）
fprintf('  [B4] 伴随求解...\n');
model.param.set('adjoint_mode', '0');
try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch; end

try model.sol.remove('sol1'); catch; end
model.study('std1').run;

% 提取伴随场 λ
lambda = get_E(model, coord3);
fprintf('  |lambda| mean=%.4e\n', mean(vecnorm(lambda, 2, 2)));

% B5. 计算手动梯度
fprintf('  [B5] 手动梯度...\n');
% g = -k₀² · Re[∫ E·λ dV]（逐体素）
k0_sq = p.k0^2;
g_re_manual = zeros(N_inner, 1);
g_im_manual = zeros(N_inner, 1);
for vi = 1:N_inner
    Ev = E_hyp(vi, :);
    Lv = lambda(vi, :);
    dV_v = dV(vi);
    EL = sum(conj(Ev) .* Lv);  % Hermitian内积
    g_re_manual(vi) = -k0_sq * dV_v * real(EL);
    g_im_manual(vi) = -k0_sq * dV_v * imag(EL);
end

fprintf('  g_re_manual: Σ=%+.6e, mean=%.4e\n', sum(g_re_manual), mean(abs(g_re_manual)));
fprintf('  g_im_manual: Σ=%+.6e, mean=%.4e\n', sum(g_im_manual), mean(abs(g_im_manual)));

%% ========== C. 直接对比 ==========
fprintf('\n=== C. 直接对比（不经过FD）===\n');

% 全局ratio
ratio_re_global = sum(g_re_native) / max(abs(sum(g_re_manual)), 1e-30);
ratio_im_global = sum(g_im_native) / max(abs(sum(g_im_manual)), 1e-30);
fprintf('  全局: Σ(native_re)/Σ(manual_re) = %+.4f\n', ratio_re_global);
fprintf('  全局: Σ(native_im)/Σ(manual_im) = %+.4f\n', ratio_im_global);

% 分区ratio
N_zones = 5;
r_inner = vecnorm(inner_pos, 2, 2);
r_bins = linspace(0, p.R_inner, N_zones+1);
zone_id = discretize(r_inner, r_bins);

fprintf('\n  === 分区对比: native vs manual ===\n');
fprintf('  zone  r_mid   n_vox   Σnative_re       Σmanual_re       ratio_re    sign_re   Σnative_im       Σmanual_im       ratio_im    sign_im\n');

for zi = 1:N_zones
    mask = (zone_id == zi);
    n_vox = sum(mask);
    if n_vox == 0, continue; end
    r_mid = (r_bins(zi) + r_bins(zi+1)) / 2;
    
    nr = sum(g_re_native(mask));
    mr = sum(g_re_manual(mask));
    rr = nr / max(abs(mr), 1e-30);
    sr = 'OK'; if nr*mr < 0, sr = 'XX'; end
    
    ni = sum(g_im_native(mask));
    mi = sum(g_im_manual(mask));
    ri = ni / max(abs(mi), 1e-30);
    si = 'OK'; if ni*mi < 0, si = 'XX'; end
    
    fprintf('  %d    %.4f  %4d   %+.6e   %+.6e   %+.4f  %s   %+.6e   %+.6e   %+.4f  %s\n', ...
        zi, r_mid, n_vox, nr, mr, rr, sr, ni, mi, ri, si);
end

% 相关系数
corr_re = corr(g_re_native, g_re_manual);
corr_im = corr(g_im_native, g_im_manual);
fprintf('\n  相关系数:\n');
fprintf('    corr(native_re, manual_re) = %.6f\n', corr_re);
fprintf('    corr(native_im, manual_im) = %.6f\n', corr_im);

% cosθ
cos_re = dot(g_re_native, g_re_manual) / (norm(g_re_native) * norm(g_re_manual));
cos_im = dot(g_im_native, g_im_manual) / (norm(g_im_native) * norm(g_im_manual));
fprintf('    cosθ(native_re, manual_re) = %.6f\n', cos_re);
fprintf('    cosθ(native_im, manual_im) = %.6f\n', cos_im);

fprintf('\n############################################################\n');

% 恢复
model.param.set('adjoint_mode', '1');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end
try phys.feature('vec1').set('Je', {'0','0','0'}); catch; end
try model.study('std1').feature('sens').active(true); catch; end

try ModelUtil.remove('Model'); catch; end
end

function E = get_E(model, coord3)
Ex = mphinterp(model,'emw.Ex','coord',coord3);
Ey = mphinterp(model,'emw.Ey','coord',coord3);
Ez = mphinterp(model,'emw.Ez','coord',coord3);
E = [Ex(:), Ey(:), Ez(:)];
end
