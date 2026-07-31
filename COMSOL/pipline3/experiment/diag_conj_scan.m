function result = diag_conj_scan(N_sample)
%DIAG_CONJ_SCAN  系统性 conj 扫描：自动定位伴随源正确的符号组合
%
%   问题：FD 验证 50% 方向错误 → 存在系统性符号 bug
%   方法：穷举测试 8 种 g_indirect conj 组合 × 2 种 g_direct 符号
%   原理：
%     梯度 g = g_direct + g_indirect
%     g_direct 依赖 S_field, E_total（不受 conj 影响）
%     g_indirect 依赖 λ（受注入方式和后处理 conj 影响）
%     只有 2 个 COMSOL 伴随求解（raw 注入 + -conj 注入）
%     其余组合在 MATLAB 后处理中枚举
%
%   用法：
%     >> diag_conj_scan(10)   % 测试 10 个体素

if nargin < 1, N_sample = 10; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n========================================================\n');
fprintf('  CONJ SCAN: 8 x 2 = 16 组合自动定位正确符号\n');
fprintf('  N_sample = %d\n', N_sample);
fprintf('========================================================\n\n');

%% ========== 1. 初始化 ==========
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected')
        fprintf('[DIAG] mphstart FAIL: %s\n', ME.message); return;
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
fprintf('[DIAG] N_inner=%d\n', N_inner);

%% ========== 2. 预计算 J_obs（真值 eps_r=5）==========
fprintf('[DIAG] 预计算 J_obs (eps_r=5)...\n');
voxel.epsilon_r(inner) = 5.0;
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
fprintf('[DIAG] F_obs=%.4e\n', F_obs);

%% ========== 3. 正演 eps_r=3（梯度初值）==========
fprintf('[DIAG] 正演 (非均匀 eps_r)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = 3.0 + 1.5*xx/p.R_inner;
end
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[DIAG] F_data=%.6e\n', F_data);

%% ========== 4. 构建伴随源 ==========
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj_orig, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);

fprintf('[DIAG] |f_adj| mean=%.4e, |S_field| mean=%.4e\n', ...
    mean(vecnorm(f_adj_orig,2,2)), mean(vecnorm(S_field,2,2)));

%% ========== 5. FD 计算 ==========
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);
fd_delta = 0.001;
g_FD = zeros(N_s,1);

fprintf('\n[DIAG] ===== FD 计算 (N=%d, delta=%.4f) =====\n', N_s, fd_delta);
for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi);
    eps_orig = voxel.epsilon_r(v_global);

    % +delta
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    [E_p,~,~] = solve_forward(model, voxel, p);
    [~, lc_p] = born_forward_project(voxel, E_p, p, lc_obs);
    F_plus = sum(dOmega .* sum(abs(J_obs - lc_p.J_hyp_perp).^2,2)) / F_obs;

    % -delta
    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    [E_m,~,~] = solve_forward(model, voxel, p);
    [~, lc_m] = born_forward_project(voxel, E_m, p, lc_obs);
    F_minus = sum(dOmega .* sum(abs(J_obs - lc_m.J_hyp_perp).^2,2)) / F_obs;

    voxel.epsilon_r(v_global) = eps_orig;
    g_FD(si) = (F_plus - F_minus) / (2*fd_delta);

    if mod(si,5)==0 || si==N_s
        fprintf('  [%2d/%d] g_FD=%+.4e\n', si, N_s, g_FD(si));
    end
end

%% ========== 6. 两个 COMSOL 伴随求解 ==========
fprintf('\n[DIAG] ===== 伴随求解 =====\n');

% --- Solve A: raw 注入 (pipline3 风格) ---
fprintf('[DIAG] Solve A: raw 注入 (Je = f_adj)...\n');
lambda_A = solve_adjoint_raw(model, voxel, p, f_adj_orig, source_pos_vol);

% --- Solve B: -conj 注入 (B03 风格) ---
fprintf('[DIAG] Solve B: -conj 注入 (Je = -i*conj(f_adj))...\n');
lambda_B = solve_adjoint_b03(model, voxel, p, f_adj_orig, source_pos_vol);

%% ========== 7. 枚举 16 种组合 ==========
fprintf('\n[DIAG] ===== 枚举 16 种组合 =====\n\n');

omega = p.omega(1); eps0 = p.eps0; mu0 = p.mu0;
k0_sq = p.k0^2; dV_vec = voxel.dV;

% g_direct 基础值（正确公式：+2*dV*omega*eps0*Im(conj(E)*S)/F_obs）
gd_base = zeros(N_inner, 1);
for vi=1:N_inner
    gd_base(vi) = 2 * voxel.dV(inner_idx(vi)) * omega * eps0 ...
        * imag(sum(conj(E_total(vi,:)).*S_field(vi,:))) / F_obs;
end

% g_indirect 8 种组合
% combo: (inject_style, coeff_sign, conj_lambda)
%   inject_style: 'A'=raw, 'B'=-conj
%   coeff_sign: +1 or -1
%   conj_lambda: 0=raw, 1=conj
combo_labels = {
    'A  +1  raw ', 'A  +1  conj', 'A  -1  raw ', 'A  -1  conj', ...
    'B  +1  raw ', 'B  +1  conj', 'B  -1  raw ', 'B  -1  conj'};
combo_cfg = struct('style',{'A','A','A','A','B','B','B','B'}, ...
                   'cs',{+1,+1,-1,-1,+1,+1,-1,-1}, ...
                   'cj',{0,1,0,1,0,1,0,1});
n_ind = length(combo_labels);

% 预计算每种 g_indirect
gi_all = zeros(n_ind, N_inner);
for ci = 1:n_ind
    if strcmp(combo_cfg(ci).style, 'A')
        lam = lambda_A;
    else
        lam = lambda_B;
    end
    if combo_cfg(ci).cj, lam = conj(lam); end
    lam = combo_cfg(ci).cs * lam;

    for vi=1:N_inner
        gi_all(ci, vi) = -k0_sq * dV_vec(inner_idx(vi)) ...
            * real(sum(conj(E_total(vi,:)).*lam(vi,:)));
    end
end

% 打印结果表头
fprintf('| #  | inject  cs  cj_l | gd_sgn | sign%%  | cos_th  | mean_ratio | status    |\n');
fprintf('|----|-------------------|--------|--------|---------|------------|-----------|\n');

results = [];
best_sign = 0; best_id = 0;

for ci = 1:n_ind
    for gds = [1, 2]  % 1=+1, 2=-1
        if gds == 1, gd_sign = +1; else, gd_sign = -1; end
        combo_num = (ci-1)*2 + gds;

        % 提取采样点的梯度
        g_adj_s = zeros(N_s, 1);
        for si=1:N_s
            vi = sample_idx(si);
            g_adj_s(si) = gd_sign * gd_base(vi) + gi_all(ci, vi);
        end

        % 统计
        sign_match = sign(g_FD .* g_adj_s) > 0;
        sign_rate = sum(sign_match) / N_s;
        cos_theta = dot(g_FD, g_adj_s) / (norm(g_FD)*norm(g_adj_s) + 1e-30);
        valid = abs(g_FD) > 1e-30;
        if sum(valid) > 0
            ratios = g_adj_s(valid) ./ g_FD(valid);
            mean_ratio = mean(ratios);
        else
            mean_ratio = NaN;
        end

        if sign_rate > best_sign
            best_sign = sign_rate; best_id = combo_num;
        end

        cs_str = sprintf('%+d', combo_cfg(ci).cs);
        cj_str = sprintf('%d', combo_cfg(ci).cj);
        gd_str = sprintf('%+d', gd_sign);

        if sign_rate > 0.9 && cos_theta > 0.8
            status_str = '*** PASS ***';
        elseif sign_rate > 0.7
            status_str = '** good **';
        elseif sign_rate > 0.5
            status_str = '* marginal *';
        else
            status_str = 'FAIL';
        end

        fprintf('| %2d | %s   %s   %s    |  %s    | %5.1f  | %7.4f  | %10.4f | %s |\n', ...
            combo_num, combo_cfg(ci).style, cs_str, cj_str, gd_str, ...
            100*sign_rate, cos_theta, mean_ratio, status_str);

        results = [results; struct(...
            'combo_num', combo_num, ...
            'style', combo_cfg(ci).style, ...
            'coeff_sign', combo_cfg(ci).cs, ...
            'conj_lambda', combo_cfg(ci).cj, ...
            'gd_sign', gd_sign, ...
            'sign_rate', sign_rate, 'cos_theta', cos_theta, ...
            'mean_ratio', mean_ratio)];
    end
end

fprintf('\n========================================================\n');
fprintf('  最佳组合: #%d  (sign=%.1f%%)\n', best_id, 100*best_sign);
fprintf('========================================================\n');

% 打印最佳组合详情
br = results(best_id);
fprintf('  inject_style = %s   (A=raw注入, B=-conj注入)\n', br.style);
fprintf('  coeff_sign   = %+d  (build_adjoint_source_volume 系数符号)\n', br.coeff_sign);
fprintf('  conj_lambda  = %d   (lambda 提取后是否取 conj)\n', br.conj_lambda);
fprintf('  gd_sign      = %+d  (g_direct 公式符号)\n', br.gd_sign);
fprintf('  sign_rate    = %.1f%%\n', 100*br.sign_rate);
fprintf('  cos_theta    = %.4f\n', br.cos_theta);
fprintf('  mean_ratio   = %.4f  (理想值接近 1.0)\n', br.mean_ratio);

% 判断 g_direct 和 g_indirect 哪个有问题
fprintf('\n--- 诊断结论 ---\n');
% 找纯 g_direct 最佳（所有 g_indirect 组合中 sign 最高的 gd_sign）
best_gd_only = 0;
for ci=1:n_ind
    for gds=[1,2]
        cn = (ci-1)*2+gds;
        if results(cn).sign_rate > best_gd_only
            best_gd_only = results(cn).sign_rate;
        end
    end
end
if best_sign > 0.9
    fprintf('  找到 PASS 组合！问题已定位。\n');
    fprintf('  修复建议:\n');
    if strcmp(br.style, 'B')
        fprintf('    1. solve_adjoint.m: 恢复 B03 -conj 写入约定\n');
    else
        fprintf('    1. solve_adjoint.m: 保持 raw 注入\n');
    end
    if br.coeff_sign < 0
        fprintf('    2. build_adjoint_source_volume.m: coeff 改为 -eps0/mu0\n');
    else
        fprintf('    2. build_adjoint_source_volume.m: coeff 保持 +eps0/mu0\n');
    end
    if br.conj_lambda == 1
        fprintf('    3. lambda 提取后需要 conj\n');
    else
        fprintf('    3. lambda 提取后不需要 conj\n');
    end
    if br.gd_sign < 0
        fprintf('    4. g_direct 公式符号应为负\n');
    else
        fprintf('    4. g_direct 公式符号应为正\n');
    end
else
    fprintf('  没有组合达到 PASS (>90%%)，可能存在更深层次问题。\n');
    fprintf('  建议：\n');
    fprintf('    a. 检查 build_adjoint_source_volume 的反向投影 S_field 是否正确\n');
    fprintf('    b. 检查 born_forward_project 与 FD 使用的代价函数是否一致\n');
    fprintf('    c. 检查 COMSOL 模型网格精度和 PML 设置\n');
end
fprintf('========================================================\n\n');

% 保存结果
result = struct('results', {results}, 'g_FD', g_FD, 'best_id', best_id);
save(fullfile(p.dir_result, 'diag_conj_scan_result.mat'), 'result');
fprintf('[DIAG] 结果已保存到 diag_conj_scan_result.mat\n');

end

%% ===================== 辅助函数 =====================

%--- raw 注入 (pipline3 风格: Je = f_adj 直接存 Re/Im) ---
function lambda = solve_adjoint_raw(model, voxel, p, f_adj, source_pos)
    phys = model.physics('emw');
    inner = voxel.mask_interior; inner_idx = find(inner);

    func_names = {'int_adj_x_re','int_adj_x_im', ...
                  'int_adj_y_re','int_adj_y_im', ...
                  'int_adj_z_re','int_adj_z_im'};

    for d = 1:3
        for part = 1:2
            idx = (d-1)*2 + part;
            fn = func_names{idx};
            try model.component('comp1').func(fn);
            catch
                model.component('comp1').func.create(fn, 'Interpolation');
                model.component('comp1').func(fn).set('nargs', '3');
                model.component('comp1').func(fn).set('source', 'table');
            end
            if part == 1
                vals = real(f_adj(:, d));
            else
                vals = imag(f_adj(:, d));
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

    Je_x = '(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))';
    Je_y = '(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))';
    Je_z = '(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))';
    phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});

    % 归零背景场
    model.param.set('adjoint_mode', '0');
    try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch; end

    % 求解
    model.sol('sol1').runAll();
    fprintf('  [raw] adjoint solve OK\n');

    % 提取 lambda
    [lambda, ~] = read_field(model, voxel.pos(inner_idx, :));

    % 恢复
    model.param.set('adjoint_mode', '1');
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end
    try phys.feature('vec1').set('Je', {'0','0','0'}); catch; end
end

%--- B03 -conj 注入 (存 -Re, +Im, 表达式重构 -i*conj(f_adj)) ---
function lambda = solve_adjoint_b03(model, voxel, p, f_adj, source_pos)
    phys = model.physics('emw');
    inner = voxel.mask_interior; inner_idx = find(inner);

    func_names = {'int_adj_x_re','int_adj_x_im', ...
                  'int_adj_y_re','int_adj_y_im', ...
                  'int_adj_z_re','int_adj_z_im'};

    for d = 1:3
        for part = 1:2
            idx = (d-1)*2 + part;
            fn = func_names{idx};
            try model.component('comp1').func(fn);
            catch
                model.component('comp1').func.create(fn, 'Interpolation');
                model.component('comp1').func(fn).set('nargs', '3');
                model.component('comp1').func(fn).set('source', 'table');
            end
            % B03 约定: re 存 -Re(f_adj), im 存 +Im(f_adj)
            if part == 1
                vals = -real(f_adj(:, d));   % -Re
            else
                vals = imag(f_adj(:, d));     % +Im
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

    % B03 Je 表达式: (-int_im + i*int_re)
    % int_re=-Re(f), int_im=+Im(f) => (-Im+i*(-Re)) = -i*conj(f)
    Je_x = '(-int_adj_x_im(x,y,z) + i*int_adj_x_re(x,y,z))';
    Je_y = '(-int_adj_y_im(x,y,z) + i*int_adj_y_re(x,y,z))';
    Je_z = '(-int_adj_z_im(x,y,z) + i*int_adj_z_re(x,y,z))';
    phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});

    % 归零背景场
    model.param.set('adjoint_mode', '0');
    try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch; end

    % 求解
    model.sol('sol1').runAll();
    fprintf('  [B03] adjoint solve OK\n');

    % 提取 lambda
    [lambda, ~] = read_field(model, voxel.pos(inner_idx, :));

    % 恢复
    model.param.set('adjoint_mode', '1');
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end
    try phys.feature('vec1').set('Je', {'0','0','0'}); catch; end
end

%--- 安静求解 ---
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
