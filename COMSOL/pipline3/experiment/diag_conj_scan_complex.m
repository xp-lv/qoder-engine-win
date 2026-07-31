function result = diag_conj_scan_complex(N_sample)
%DIAG_CONJ_SCAN_COMPLEX  复数 eps_r 的 conj 扫描
%
%   问题：复数 eps_r 下 g_re/g_im 全面失败 (sign 20-30%)
%   根因：复对称矩阵 K≠K̄，需要 conj 源+conj 解
%
%   扫描变量：
%     1. conj_eps:  f_adj 中用 eps_r 还是 conj(eps_r)
%     2. inject:    raw 注入 vs -conj 注入
%     3. conj_lam:  lambda 提取后是否 conj
%     4. gi_im_sgn: g_im indirect 符号 ±1
%
%   只需 4 次 COMSOL 伴随求解 (conj_eps × inject)

if nargin < 1, N_sample = 10; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n========================================================\n');
fprintf('  COMPLEX CONJ SCAN: 定位复数 eps_r 正确符号组合\n');
fprintf('  N_sample = %d\n', N_sample);
fprintf('========================================================\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected')
        fprintf('[DCS] mphstart FAIL: %s\n', ME.message); return;
    end
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
fprintf('[DCS] N_inner=%d\n', N_inner);

%% 2. J_obs (真值 eps_r = 5-5j)
fprintf('[DCS] 预计算 J_obs (eps_r=5-5j)...\n');
voxel.epsilon_r(inner) = 5.0 - 5j;
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

%% 3. 正演 (非均匀复数 eps_r)
fprintf('[DCS] 正演 (非均匀复数 eps_r)...\n');
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

%% 4. 反投影 S_field + 基础 f_adj
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
omega = p.omega(1); eps0 = p.eps0; mu0 = p.mu0;
k0_sq = p.k0^2; dV_vec = voxel.dV;

% 手动计算 S_field (不依赖 build_adjoint_source_volume)
S_field = zeros(N_inner, 3);
for ki = 1:size(k_vec,1)
    phase = exp(1i * voxel.pos(inner_idx,:) * k_vec(ki,:)');
    S_field = S_field + dOmega(ki) * Delta_J(ki,:) .* phase;
end

eps_r_inner = voxel.epsilon_r(inner_idx);
coeff_base = eps0 / mu0;  % = +eps0/mu0

% 两种 f_adj 变体
f_adj_eps    = (coeff_base / F_obs) .* (eps_r_inner - 1) .* S_field;       % 用 eps_r
f_adj_conjep = (coeff_base / F_obs) .* (conj(eps_r_inner) - 1) .* S_field; % 用 conj(eps_r)

source_pos_vol = voxel.pos(inner_idx, :);

%% 5. FD 计算 (对 eps_re 和 eps_im 分别微扰)
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);
fd_delta = 0.01;

g_FD_re = zeros(N_s,1);
g_FD_im = zeros(N_s,1);

fprintf('\n[DCS] ===== FD 计算 (N=%d, delta=%.4f) =====\n', N_s, fd_delta);
for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi);
    eps_orig = voxel.epsilon_r(v_global);
    eps_re_orig = real(eps_orig); eps_im_orig = imag(eps_orig);

    % FD for g_re
    voxel.epsilon_r(v_global) = (eps_re_orig + fd_delta) + 1j*eps_im_orig;
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [E_p,~,~] = solve_forward(model, voxel, p);
    [~, lc_p] = born_forward_project(voxel, E_p, p, lc_obs);
    Fp = sum(dOmega .* sum(abs(J_obs - lc_p.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = (eps_re_orig - fd_delta) + 1j*eps_im_orig;
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [E_m,~,~] = solve_forward(model, voxel, p);
    [~, lc_m] = born_forward_project(voxel, E_m, p, lc_obs);
    Fm = sum(dOmega .* sum(abs(J_obs - lc_m.J_hyp_perp).^2,2)) / F_obs;

    g_FD_re(si) = (Fp - Fm) / (2*fd_delta);

    % FD for g_im
    voxel.epsilon_r(v_global) = eps_re_orig + 1j*(eps_im_orig + fd_delta);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [E_p2,~,~] = solve_forward(model, voxel, p);
    [~, lc_p2] = born_forward_project(voxel, E_p2, p, lc_obs);
    Fp2 = sum(dOmega .* sum(abs(J_obs - lc_p2.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = eps_re_orig + 1j*(eps_im_orig - fd_delta);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [E_m2,~,~] = solve_forward(model, voxel, p);
    [~, lc_m2] = born_forward_project(voxel, E_m2, p, lc_obs);
    Fm2 = sum(dOmega .* sum(abs(J_obs - lc_m2.J_hyp_perp).^2,2)) / F_obs;

    g_FD_im(si) = (Fp2 - Fm2) / (2*fd_delta);
    voxel.epsilon_r(v_global) = eps_orig;

    if mod(si,5)==0 || si==N_s
        fprintf('  [%2d/%d] g_FD_re=%+.2e g_FD_im=%+.2e\n', si, N_s, g_FD_re(si), g_FD_im(si));
    end
end

%% 6. 4 次 COMSOL 伴随求解
fprintf('\n[DCS] ===== 4 次伴随求解 =====\n');

% (eps, raw), (eps, -conj), (conj_eps, raw), (conj_eps, -conj)
lambda_table = struct();
solve_configs = {
    'eps_raw',    f_adj_eps,    'raw';
    'eps_conj',   f_adj_eps,    'conj';
    'cep_raw',    f_adj_conjep, 'raw';
    'cep_conj',   f_adj_conjep, 'conj';
};

for ci = 1:4
    name = solve_configs{ci,1};
    f_in = solve_configs{ci,2};
    style = solve_configs{ci,3};
    fprintf('[DCS] Solve %s (%s injection)...\n', name, style);
    lambda_table.(name) = solve_adjoint_variant(model, voxel, p, f_in, source_pos_vol, style);
end

%% 7. 枚举组合
fprintf('\n[DCS] ===== 枚举组合 =====\n\n');

% g_direct 是固定的（不依赖 lambda）
gd_re_base = zeros(N_inner, 1);
gd_im_base = zeros(N_inner, 1);
for vi=1:N_inner
    ES = dot(E_total(vi,:), S_field(vi,:));  % conj(E)*S
    gd_re_base(vi) = +2*omega*eps0*dV_vec(inner_idx(vi))*imag(ES)/F_obs;
    gd_im_base(vi) = +2*omega*eps0*dV_vec(inner_idx(vi))*real(ES)/F_obs;
end

% 对每种 lambda 变体，计算 g_indirect 的 re/im
gi_re_table = struct();
gi_im_table = struct();

solve_names = {'eps_raw','eps_conj','cep_raw','cep_conj'};
for si = 1:4
    name = solve_names{si};
    lam = lambda_table.(name);

    % 不取 conj
    gi_re_table.([name '_nc']) = compute_gi_re(E_total, lam, inner_idx, k0_sq, dV_vec);
    gi_im_table.([name '_nc']) = compute_gi_im(E_total, lam, inner_idx, k0_sq, dV_vec, +1);

    % 取 conj
    gi_re_table.([name '_cj']) = compute_gi_re(E_total, conj(lam), inner_idx, k0_sq, dV_vec);
    gi_im_table.([name '_cj']) = compute_gi_im(E_total, conj(lam), inner_idx, k0_sq, dV_vec, +1);
end

% 对 gi_im 还要测试 -1 符号
gi_im_neg = struct();
for si = 1:4
    name = solve_names{si};
    lam = lambda_table.(name);
    gi_im_neg.([name '_nc']) = compute_gi_im(E_total, lam, inner_idx, k0_sq, dV_vec, -1);
    gi_im_neg.([name '_cj']) = compute_gi_im(E_total, conj(lam), inner_idx, k0_sq, dV_vec, -1);
end

% 枚举：8 种 lambda 变体 × 2 种 gi_im 符号 × 2 种 gd_im 符号 = 32 种 g_im 组合
fprintf('| #  | lambda_var       | gim gdi | re_s%% | re_cos | im_s%% | im_cos | status  |\n');
fprintf('|----|------------------|---------|-------|--------|-------|--------|---------|\n');

lam_keys = fieldnames(gi_re_table);
n_lam = length(lam_keys);
results = [];
best_score = -1; best_id = 0;
combo_num = 0;

for li = 1:n_lam
    lk = lam_keys{li};
    gi_re_vals = gi_re_table.(lk);

    for gim_sign = [+1, -1]
        if gim_sign == +1
            gi_im_vals = gi_im_table.(lk);
        else
            gi_im_vals = gi_im_neg.(lk);
        end

        for gdi_sign = [+1, -1]
            combo_num = combo_num + 1;

            % 提取采样点
            g_adj_re_s = zeros(N_s,1); g_adj_im_s = zeros(N_s,1);
            for si=1:N_s
                vi = sample_idx(si);
                g_adj_re_s(si) = gd_re_base(vi) + gi_re_vals(vi);
                g_adj_im_s(si) = gdi_sign * gd_im_base(vi) + gi_im_vals(vi);
            end

            % 统计
            sr_re = sum(sign(g_FD_re .* g_adj_re_s) > 0) / N_s;
            sr_im = sum(sign(g_FD_im .* g_adj_im_s) > 0) / N_s;
            ct_re = dot(g_FD_re, g_adj_re_s) / (norm(g_FD_re)*norm(g_adj_re_s)+1e-30);
            ct_im = dot(g_FD_im, g_adj_im_s) / (norm(g_FD_im)*norm(g_adj_im_s)+1e-30);

            score = sr_re + sr_im + max(0,ct_re) + max(0,ct_im);
            if score > best_score, best_score = score; best_id = combo_num; end

            if sr_re > 0.9 && sr_im > 0.9 && ct_re > 0.8 && ct_im > 0.8
                status_str = '*** PASS ***';
            elseif sr_re > 0.7 && sr_im > 0.7
                status_str = '** good **';
            else
                status_str = 'FAIL';
            end

            % 只打印有希望的组合（im sign > 50%）或前几个
            if sr_im > 0.5 || combo_num <= 4 || status_str(1) == '*'
                fprintf('| %2d | %-16s | %+d  %+d  | %5.0f | %6.3f | %5.0f | %6.3f | %s |\n', ...
                    combo_num, lk, gim_sign, gdi_sign, ...
                    100*sr_re, ct_re, 100*sr_im, ct_im, status_str);
            end

            results = [results; struct('id',combo_num,'lam',lk,'gim_sgn',gim_sign,'gdi_sgn',gdi_sign, ...
                'sr_re',sr_re,'sr_im',sr_im,'ct_re',ct_re,'ct_im',ct_im)];
        end
    end
end

fprintf('\n========================================================\n');
fprintf('  最佳组合: #%d (score=%.2f)\n', best_id, best_score);
fprintf('========================================================\n');
br = results(best_id);
fprintf('  lambda_variant = %s\n', br.lam);
fprintf('  gi_im_sign     = %+d  (g_indirect 虚部符号)\n', br.gim_sgn);
fprintf('  gd_im_sign     = %+d  (g_direct 虚部符号)\n', br.gdi_sgn);
fprintf('  g_re: sign=%.0f%%, cos=%.3f\n', 100*br.sr_re, br.ct_re);
fprintf('  g_im: sign=%.0f%%, cos=%.3f\n', 100*br.sr_im, br.ct_im);

if br.sr_re > 0.9 && br.sr_im > 0.9
    fprintf('\n  *** PASS *** 修复方案已定位！\n');
    if contains(br.lam, 'conj')
        fprintf('  -> 注入方式: -conj (B03 风格)\n');
    else
        fprintf('  -> 注入方式: raw\n');
    end
    if contains(br.lam, 'cep')
        fprintf('  -> f_adj 系数: conj(eps_r)-1\n');
    else
        fprintf('  -> f_adj 系数: eps_r-1\n');
    end
    if contains(br.lam, '_cj')
        fprintf('  -> lambda 提取: 需要 conj\n');
    else
        fprintf('  -> lambda 提取: 不需要 conj\n');
    end
    fprintf('  -> g_direct_im 符号: %+d\n', br.gdi_sgn);
    fprintf('  -> g_indirect_im 符号: %+d\n', br.gim_sgn);
else
    fprintf('\n  没有组合 PASS。可能需要从 Wirtinger 变分原理重新推导。\n');
end
fprintf('========================================================\n');

result = struct('results',{results}, 'g_FD_re',g_FD_re, 'g_FD_im',g_FD_im, 'best_id',best_id);
save(fullfile(p.dir_result,'diag_conj_scan_complex_result.mat'),'result');
fprintf('[DCS] 结果已保存\n');

end

%% ====== 辅助函数 ======
function val = compute_gi_re(E, lam, inner_idx, k0_sq, dV)
    N = length(inner_idx);
    val = zeros(N,1);
    for vi=1:N
        EL = dot(E(vi,:), lam(vi,:));  % conj(E)*lambda
        val(vi) = -k0_sq * dV(inner_idx(vi)) * real(EL);
    end
end

function val = compute_gi_im(E, lam, inner_idx, k0_sq, dV, sign)
    N = length(inner_idx);
    val = zeros(N,1);
    for vi=1:N
        EL = dot(E(vi,:), lam(vi,:));  % conj(E)*lambda
        val(vi) = sign * k0_sq * dV(inner_idx(vi)) * imag(EL);
    end
end

function lambda = solve_adjoint_variant(model, voxel, p, f_adj, source_pos, style)
    phys = model.physics('emw');
    inner = voxel.mask_interior; inner_idx = find(inner);

    func_names = {'int_adj_x_re','int_adj_x_im','int_adj_y_re','int_adj_y_im','int_adj_z_re','int_adj_z_im'};

    for d = 1:3
        for part = 1:2
            idx = (d-1)*2 + part; fn = func_names{idx};
            try model.component('comp1').func(fn);
            catch
                model.component('comp1').func.create(fn, 'Interpolation');
                model.component('comp1').func(fn).set('nargs', '3');
                model.component('comp1').func(fn).set('source', 'table');
            end
            if strcmp(style, 'raw')
                if part == 1, vals = real(f_adj(:,d)); else, vals = imag(f_adj(:,d)); end
            else  % conj: store -Re, +Im
                if part == 1, vals = -real(f_adj(:,d)); else, vals = imag(f_adj(:,d)); end
            end
            tmp = [tempname, '.csv'];
            dlmwrite(tmp, [source_pos, vals(:)]);
            model.component('comp1').func(fn).importData(tmp);
            delete(tmp);
        end
    end

    try phys.feature('vec1'); catch
        phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
        try phys.feature('vec1').selection().all(); catch; end
    end

    if strcmp(style, 'raw')
        Je_x = '(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))';
        Je_y = '(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))';
        Je_z = '(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))';
    else  % conj: (-im + i*re) = -i*conj(f)
        Je_x = '(-int_adj_x_im(x,y,z) + i*int_adj_x_re(x,y,z))';
        Je_y = '(-int_adj_y_im(x,y,z) + i*int_adj_y_re(x,y,z))';
        Je_z = '(-int_adj_z_im(x,y,z) + i*int_adj_z_re(x,y,z))';
    end
    phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});

    model.param.set('adjoint_mode', '0');
    try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch; end
    model.sol('sol1').runAll();

    [lambda, ~] = read_field(model, voxel.pos(inner_idx, :));

    model.param.set('adjoint_mode', '1');
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end
    try phys.feature('vec1').set('Je', {'0','0','0'}); catch; end
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
            s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso');
        end;
        try s1.feature('fc1').set('linsolver','dDirect'); catch; end;
    catch; end
    model.sol('sol1').runAll();
end
