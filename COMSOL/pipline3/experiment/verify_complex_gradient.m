function result = verify_complex_gradient(N_sample)
%VERIFY_COMPLEX_GRADIENT 复数 eps_r 的逐体素 FD 验证
%
%   测试 compute_gradient 返回的复数梯度 g = g_re + j*g_im 是否正确：
%     - 对 eps_re 做 ±δ 微扰 → FD 估计 g_re
%     - 对 eps_im 做 ±δ 微扰 → FD 估计 g_im
%     - 与伴随法解析梯度对比
%
%   用法：
%     >> verify_complex_gradient(10)

if nargin < 1, N_sample = 10; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  复数 eps_r 逐体素 FD 验证 (g_re + j*g_im)\n');
fprintf('#  N_sample = %d\n', N_sample);
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[VCG] [FAIL] COMSOL\n'); return; end
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
fprintf('[VCG] N_inner=%d\n', N_inner);

%% 2. 预计算 J_obs（真值 eps_r = 5 - 5j）
fprintf('[VCG] 预计算 J_obs (eps_r=5-5j)...\n');
eps_true_re = 5.0; eps_true_im = -5.0;
eps_true = eps_true_re + 1j * eps_true_im;
voxel.epsilon_r(inner) = eps_true;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

[E_true, ~, ~] = solve_forward(model, voxel, p);
[k_dir, dOmega] = fibonacci_sphere(p.N_k);
k_vec = p.k0 * k_dir;
lc_obs.k_dir = k_dir; lc_obs.k_vec = k_vec; lc_obs.dOmega = dOmega;
lc_obs.J_obs_perp = [];
[~, lc_obs] = born_forward_project(voxel, E_true, p, lc_obs);
J_obs = lc_obs.J_hyp_perp;
dOmega = lc_obs.dOmega;
lc_obs.J_obs_perp = J_obs;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2));
if F_obs < p.F_obs_min, F_obs = 1.0; end
fprintf('[VCG] F_obs=%.4e\n', F_obs);

%% 3. 正演（非均匀复数初值 eps_r = 3-3j + 梯度）
fprintf('[VCG] 正演 (非均匀复数 eps_r)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    re_val = 3.0 + 1.5*xx/p.R_inner;
    im_val = -3.0 - 0.5*xx/p.R_inner;
    voxel.epsilon_r(inner_idx(vi)) = re_val + 1j * im_val;
end
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[VCG] F_data=%.6e\n', F_data);

%% 4. 构建伴随源 + 求解 λ
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);

fprintf('[VCG] 伴随求解...\n');
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[VCG] [FAIL] adjoint\n'); return; end

%% 5. 解析梯度（复数 g = g_re + j*g_im）
fprintf('[VCG] 计算解析梯度...\n');
[g_adj, gd_adj, gi_adj] = compute_gradient(voxel, E_total, S_field, lambda, p, F_obs, true, E_gauss, lambda_gauss);

fprintf('[VCG] |g_re| mean=%.4e, |g_im| mean=%.4e\n', ...
    mean(abs(real(g_adj(inner_idx)))), mean(abs(imag(g_adj(inner_idx)))));

%% 6. FD 采样选择
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);
fd_delta = 0.01;

fprintf('\n[VCG] ===== 逐体素复数 FD (N=%d, delta=%.4f) =====\n', N_s, fd_delta);

g_FD_re = zeros(N_s, 1);
g_FD_im = zeros(N_s, 1);
g_adj_re_s = zeros(N_s, 1);
g_adj_im_s = zeros(N_s, 1);
gd_adj_re_s = zeros(N_s, 1);
gi_adj_re_s = zeros(N_s, 1);
gd_adj_im_s = zeros(N_s, 1);
gi_adj_im_s = zeros(N_s, 1);
vox_pos_s = zeros(N_s, 3);
vox_eps_s = zeros(N_s, 1);
vox_rad_s = zeros(N_s, 1);

for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi);
    eps_orig = voxel.epsilon_r(v_global);
    eps_re_orig = real(eps_orig);
    eps_im_orig = imag(eps_orig);

    vox_pos_s(si,:) = voxel.pos(v_global,:);
    vox_eps_s(si) = eps_orig;
    vox_rad_s(si) = vecnorm(voxel.pos(v_global,:),2,2);

    % --- FD for g_re: 微扰 eps_re ---
    voxel.epsilon_r(v_global) = (eps_re_orig + fd_delta) + 1j * eps_im_orig;
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    [E_p,~,~] = solve_forward(model, voxel, p);
    [~, lc_p] = born_forward_project(voxel, E_p, p, lc_obs);
    F_plus_re = sum(dOmega .* sum(abs(J_obs - lc_p.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = (eps_re_orig - fd_delta) + 1j * eps_im_orig;
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    [E_m,~,~] = solve_forward(model, voxel, p);
    [~, lc_m] = born_forward_project(voxel, E_m, p, lc_obs);
    F_minus_re = sum(dOmega .* sum(abs(J_obs - lc_m.J_hyp_perp).^2,2)) / F_obs;

    g_FD_re(si) = (F_plus_re - F_minus_re) / (2*fd_delta);

    % --- FD for g_im: 微扰 eps_im ---
    voxel.epsilon_r(v_global) = eps_re_orig + 1j * (eps_im_orig + fd_delta);
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    [E_p2,~,~] = solve_forward(model, voxel, p);
    [~, lc_p2] = born_forward_project(voxel, E_p2, p, lc_obs);
    F_plus_im = sum(dOmega .* sum(abs(J_obs - lc_p2.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = eps_re_orig + 1j * (eps_im_orig - fd_delta);
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    [E_m2,~,~] = solve_forward(model, voxel, p);
    [~, lc_m2] = born_forward_project(voxel, E_m2, p, lc_obs);
    F_minus_im = sum(dOmega .* sum(abs(J_obs - lc_m2.J_hyp_perp).^2,2)) / F_obs;

    g_FD_im(si) = (F_plus_im - F_minus_im) / (2*fd_delta);

    % 恢复
    voxel.epsilon_r(v_global) = eps_orig;

    % 解析梯度
    g_adj_re_s(si) = real(g_adj(v_global));
    g_adj_im_s(si) = imag(g_adj(v_global));
    gd_adj_re_s(si) = real(gd_adj(v_global));
    gi_adj_re_s(si) = real(gi_adj(v_global));
    gd_adj_im_s(si) = imag(gd_adj(v_global));
    gi_adj_im_s(si) = imag(gi_adj(v_global));

    if mod(si,5)==0 || si==N_s
        sr_re = sign(g_FD_re(si)*g_adj_re_s(si)) > 0;
        sr_im = sign(g_FD_im(si)*g_adj_im_s(si)) > 0;
        fprintf('  [%2d/%d] g_FD_re=%+.2e g_adj_re=%+.2e [%s]  g_FD_im=%+.2e g_adj_im=%+.2e [%s]\n', ...
            si, N_s, g_FD_re(si), g_adj_re_s(si), tn(sr_re), ...
            g_FD_im(si), g_adj_im_s(si), tn(sr_im));
    end
end

%% 7. 统计
sign_re = sign(g_FD_re .* g_adj_re_s) > 0;
sign_im = sign(g_FD_im .* g_adj_im_s) > 0;
rate_re = sum(sign_re) / N_s;
rate_im = sum(sign_im) / N_s;

% cos theta for re and im separately
ct_re = dot(g_FD_re, g_adj_re_s) / (norm(g_FD_re)*norm(g_adj_re_s) + 1e-30);
ct_im = dot(g_FD_im, g_adj_im_s) / (norm(g_FD_im)*norm(g_adj_im_s) + 1e-30);

% ratio
valid_re = abs(g_FD_re) > 1e-30;
valid_im = abs(g_FD_im) > 1e-30;
if sum(valid_re) > 0
    ratio_re = mean(g_adj_re_s(valid_re) ./ g_FD_re(valid_re));
else, ratio_re = NaN; end
if sum(valid_im) > 0
    ratio_im = mean(g_adj_im_s(valid_im) ./ g_FD_im(valid_im));
else, ratio_im = NaN; end

fprintf('\n############################################################\n');
fprintf('#  复数 eps_r 梯度验证结果\n');
fprintf('############################################################\n');
fprintf('#  g_re: sign %d/%d = %.1f%%, cos_th=%.4f, ratio=%.4f\n', ...
    sum(sign_re), N_s, 100*rate_re, ct_re, ratio_re);
fprintf('#  g_im: sign %d/%d = %.1f%%, cos_th=%.4f, ratio=%.4f\n', ...
    sum(sign_im), N_s, 100*rate_im, ct_im, ratio_im);
fprintf('#\n');
if rate_re > 0.9 && rate_im > 0.9 && ct_re > 0.8 && ct_im > 0.8
    fprintf('#  *** PASS *** (re 和 im 双通道都通过)\n');
else
    fprintf('#  ! FAIL 或部分通过\n');
    if rate_re <= 0.9
        fprintf('#    -> g_re 通道失败 (sign=%.1f%%)\n', 100*rate_re);
    end
    if rate_im <= 0.9
        fprintf('#    -> g_im 通道失败 (sign=%.1f%%)\n', 100*rate_im);
    end
end
fprintf('############################################################\n');

%% 8. 逐体素详细分析
dump_voxel_detail(N_s, sign_re, sign_im, vox_pos_s, vox_rad_s, vox_eps_s, ...
    g_FD_re, g_adj_re_s, gd_adj_re_s, gi_adj_re_s, ...
    g_FD_im, g_adj_im_s, gd_adj_im_s, gi_adj_im_s);

result = struct('g_FD_re',g_FD_re,'g_FD_im',g_FD_im, ...
    'g_adj_re',g_adj_re_s,'g_adj_im',g_adj_im_s, ...
    'gd_adj_re',gd_adj_re_s,'gi_adj_re',gi_adj_re_s, ...
    'gd_adj_im',gd_adj_im_s,'gi_adj_im',gi_adj_im_s, ...
    'vox_pos',vox_pos_s,'vox_rad',vox_rad_s,'vox_eps',vox_eps_s, ...
    'sign_re',sign_re,'sign_im',sign_im, ...
    'rate_re',rate_re,'rate_im',rate_im, ...
    'ct_re',ct_re,'ct_im',ct_im, ...
    'ratio_re',ratio_re,'ratio_im',ratio_im);
save(fullfile(p.dir_result,'verify_complex_gradient_result.mat'),'result');
fprintf('\n[VCG] 结果已保存 (含逐体素明细)\n');

end

function solve_quiet(model, p)
    try model.param.set('freq',num2str(p.freq));
        try model.study('std1').feature('freq').set('plist',sprintf('%g[Hz]',p.freq)); catch; end
    catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    try model.physics('emw').prop('BackgroundField').set('Eb',[0 0 1]); catch; end
    try model.param.set('adjoint_mode','1'); catch; end
    try model.physics('emw').feature('vec1').set('Je',{'0','0','0'}); catch; end
    try; s1=model.sol('sol1').feature('s1');
        try s1.feature('dDirect'); catch;
            s1.create('dDirect','Direct');
            s1.feature('dDirect').set('linsolver','pardiso');
        end;
        try s1.feature('fc1').set('linsolver','dDirect'); catch; end;
    catch; end
    model.sol('sol1').runAll();
end

function s = tn(c), if c, s='OK'; else, s='XX'; end, end

function dump_voxel_detail(N_s, sign_re, sign_im, pos, rad, eps_v, ...
    fd_re, adj_re, gd_re, gi_re, fd_im, adj_im, gd_im, gi_im)

    fprintf('\n===== 逐体素明细 (g_re) =====\n');
    fprintf('%3s | %5s | %8s | %11s %11s | %11s %11s | %5s\n', ...
        '#','r/R','eps_re', 'FD_re','adj_re', 'gd_re','gi_re','ok?');
    fprintf('%s\n', repmat('-',1,82));
    for si=1:N_s
        fprintf('%3d | %5.2f | %8.3f | %+11.3e %+11.3e | %+11.3e %+11.3e |  %s\n', ...
            si, rad(si)/0.06, real(eps_v(si)), fd_re(si), adj_re(si), ...
            gd_re(si), gi_re(si), tn(sign_re(si)));
    end

    fprintf('\n===== 逐体素明细 (g_im) =====\n');
    fprintf('%3s | %5s | %8s | %11s %11s | %11s %11s | %5s\n', ...
        '#','r/R','eps_im', 'FD_im','adj_im', 'gd_im','gi_im','ok?');
    fprintf('%s\n', repmat('-',1,82));
    for si=1:N_s
        fprintf('%3d | %5.2f | %8.3f | %+11.3e %+11.3e | %+11.3e %+11.3e |  %s\n', ...
            si, rad(si)/0.06, imag(eps_v(si)), fd_im(si), adj_im(si), ...
            gd_im(si), gi_im(si), tn(sign_im(si)));
    end

    fail_im = ~sign_im;
    n_fail_im = sum(fail_im);
    if n_fail_im > 0
        fprintf('\n===== g_im 失败模式分析 (%d/%d 失败) =====\n', n_fail_im, N_s);
        fd_mag = abs(fd_im);
        fprintf('  |FD_im| 范围: [%.3e, %.3e], 均值=%.3e\n', ...
            min(fd_mag), max(fd_mag), mean(fd_mag));

        fprintf('\n  失败体素明细:\n');
        fprintf('  %3s | %5s | %11s %11s | %11s %11s | %5s %5s | %8s\n', ...
            '#','r/R','FD_im','adj_im','gd_im','gi_im','gd_ok','gi_ok','ratio');
        for si=1:N_s
            if fail_im(si)
                gd_ok = sign(fd_im(si)*gd_im(si)) > 0;
                gi_ok = sign(fd_im(si)*gi_im(si)) > 0;
                ratio = adj_im(si) / (fd_im(si)+1e-30);
                fprintf('  %3d | %5.2f | %+11.3e %+11.3e | %+11.3e %+11.3e |  %s   %s | %8.2f\n', ...
                    si, rad(si)/0.06, fd_im(si), adj_im(si), ...
                    gd_im(si), gi_im(si), tn(gd_ok), tn(gi_ok), ratio);
            end
        end

        frac_gi = abs(gi_im(fail_im)) ./ (abs(gd_im(fail_im)) + abs(gi_im(fail_im)) + 1e-30);
        fprintf('\n  失败体素中 |gi_im|/(|gd_im|+|gi_im|) 均值=%.2f (>0.5=indirect主导)\n', mean(frac_gi));

        alt_sign = sign(fd_im .* (gd_im - gi_im)) > 0;
        fprintf('  假设 gi_im 取反: sign rate = %.0f%%\n', 100*sum(alt_sign)/N_s);

        gd_only_sign = sign(fd_im .* gd_im) > 0;
        fprintf('  只保留 gd_im (去掉 gi): sign rate = %.0f%%\n', 100*sum(gd_only_sign)/N_s);
    end

    fail_re = ~sign_re;
    n_fail_re = sum(fail_re);
    if n_fail_re > 0
        fprintf('\n===== g_re 失败模式分析 (%d/%d 失败) =====\n', n_fail_re, N_s);
        for si=1:N_s
            if fail_re(si)
                fprintf('  #%d r/R=%.2f FD=%+.3e adj=%+.3e gd=%+.3e gi=%+.3e\n', ...
                    si, rad(si)/0.06, fd_re(si), adj_re(si), gd_re(si), gi_re(si));
            end
        end
    end
end
