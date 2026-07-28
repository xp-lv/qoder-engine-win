function diagnose_root_cause()
%DIAGNOSE_ROOT_CAUSE 逐层隔离 lambda 提取/梯度公式的根因
%
%   对同一次伴随求解的 lambda_raw，测试 4 种梯度提取方式：
%     Mode A: g = -k0^2 * dV * Re(conj(lambda_raw) * E)    [当前双源路径]
%     Mode B: g = -k0^2 * dV * Re(lambda_raw * E)          [no conj]
%     Mode C: g = -k0^2 * dV * Im(conj(lambda_raw) * E)    [Im 分量]
%     Mode D: g = -k0^2 * dV * Im(lambda_raw * E)          [Im, no conj]
%
%   如果某种模式给出 ratio 一致（CV < 0.1），则该模式是正确的。

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  根因隔离：lambda 提取 / 梯度公式\n');
fprintf('#  4 种模式 x 4 参数 = 16 个 ratio\n');
fprintf('############################################################\n\n');

%% 初始化
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
R_hole = 0.03; N_freq = 1; freqs = [1.0e9];
delta_sdf = 0.008;
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);

%% 预计算 J_obs
fprintf('[RC] 预计算 J_obs...\n');
voxel_truth = voxel;
d_true = sqrt(sum((inner_pos - [0.03;0.02;0.01]').^2, 2));
voxel_truth.epsilon_r(inner_mask) = 5.0 + (1.0-5.0)*0.5*(1-tanh(d_true/delta_sdf));
update_epsilon(model, voxel_truth, p);
pf0 = p; pf0.freq=freqs(1); pf0.omega=2*pi*pf0.freq; pf0.k0=pf0.omega/pf0.c; pf0.lambda=pf0.c/pf0.freq;
model.param.set('freq', num2str(pf0.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', pf0.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
sf = extract_scattered(model, grid);
J_obs = lightcone_project(grid, sf, pf0).J_obs_perp;

%% FD 地面真值（单参数，最小步长）
fprintf('\n[RC] 计算单参数 FD...\n');
params_0 = [eps_r_test; hole_pos_test];
param_names = {'eps_r', 'hole_x', 'hole_y', 'hole_z'};
fd_steps = [0.001, 0.0001, 0.0001, 0.0001];
g_FD = zeros(4, 1);
for pi_idx = 1:4
    delta = fd_steps(pi_idx);
    pp = params_0; pp(pi_idx) = pp(pi_idx) + delta;
    F_plus = compute_F(model, voxel, grid, p, pf0, pp, inner_pos, inner_mask, delta_sdf, J_obs, freqs);
    pm = params_0; pm(pi_idx) = pm(pi_idx) - delta;
    F_minus = compute_F(model, voxel, grid, p, pf0, pm, inner_pos, inner_mask, delta_sdf, J_obs, freqs);
    g_FD(pi_idx) = (F_plus - F_minus) / (2 * delta);
end
fprintf('[RC] g_FD = [%.6e, %.6e, %.6e, %.6e]\n', g_FD);

%% 正演 + 伴随求解（Ms-only，消除 Js 旋度近似干扰）
fprintf('\n[RC] 正演 + 伴随求解 (Ms-only)...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
J_obs_safe = max(sum(abs(J_obs).^2, 2), 1e-12);
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J ./ J_obs_safe;

% 只用 Ms 路径（Js 设为零），消除旋度近似干扰
[Js_full, Ms_full, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, pf);
Js_zero = zeros(size(Js_full));

% 手动注入 Ms（走双源路径但 Js=0）
% 用 solve_adjoint 但传 Js=0
[lambda_raw, adj_ok, lambda_raw_gauss] = solve_adjoint(model, voxel, pf, Js_zero, source_pos, Ms_full);
if ~adj_ok, fprintf('[RC] [FAIL]\n'); return; end

% 提取原始 lambda_raw（未取共轭）
% solve_adjoint 内部已做 conj，我们需要原始值
% 重新提取一次未共轭的
inner = voxel.mask_interior;
[lambda_raw_direct, ~] = read_field(model, voxel.pos(inner, :));
fprintf('[RC] lambda_raw: |mean|=%.4e\n', mean(vecnorm(lambda_raw_direct, 2, 2)));

% Gauss 点
if ~isempty(voxel.gauss_pos)
    [lambda_raw_gauss_direct, ~] = read_field(model, voxel.gauss_pos);
else
    lambda_raw_gauss_direct = [];
end

%% 4 种梯度模式
N_inner = sum(inner);
inner_idx = find(inner);
k0_sq = pf.k0^2; dV_vec = voxel.dV;
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_raw_gauss_direct) ...
    && size(E_gauss,1)==size(voxel.gauss_pos,1) ...
    && size(lambda_raw_gauss_direct,1)==size(voxel.gauss_pos,1);
gauss_w = voxel.gauss_w;

% 预计算链式法则权重
dE_deps = 0.5*(1+tanh(d_test/delta_sdf));
diff_v = inner_pos - hole_pos_test';
d_v = sqrt(sum(diff_v.^2, 2));
sech2 = 1./cosh(d_v/delta_sdf).^2;
deps_dd = -(1-eps_r_test)*0.5*sech2/delta_sdf;
dE_dhole = zeros(N_inner, 3);
for j = 1:3
    dE_dhole(:, j) = deps_dd .* (-diff_v(:,j)./(d_v+1e-30));
end

modes = {'A: Re(conj(lam)*E)', 'B: Re(lam*E)', 'C: Im(conj(lam)*E)', 'D: Im(lam*E)'};

all_ratios = zeros(4, 4);  % [param x mode]

for mi = 1:4
    g_voxel = zeros(N_inner, 1);

    if use_gauss
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            v_idx = inner_idx(vi);
            gs = 0;
            for gpi = 1:4
                Eg = E_gauss(gp(gpi), :);
                Lg = lambda_raw_gauss_direct(gp(gpi), :);
                switch mi
                    case 1, val = real(conj(Lg) * Eg');     % Re(conj(lam)*E) as scalar
                    case 2, val = real(Lg * Eg');
                    case 3, val = imag(conj(Lg) * Eg');
                    case 4, val = imag(Lg * Eg');
                end
                gs = gs + gauss_w(gpi) * val;
            end
            g_voxel(vi) = -k0_sq * dV_vec(v_idx) * gs / N_freq;
        end
    else
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            Ev = E_total(vi,:);
            Lv = lambda_raw_direct(vi,:);
            switch mi
                case 1, val = real(dot(Ev, Lv));   % dot = conj(E)*Lv = conj(Ev)*Lv
                case 2, val = real(dot(Lv, Ev));   % conj(Lv)*Ev
                case 3, val = imag(dot(Ev, Lv));
                case 4, val = imag(dot(Lv, Ev));
            end
            g_voxel(vi) = -k0_sq * dV_vec(v_idx) * val / N_freq;
        end
    end

    % 链式法则
    g_param = zeros(4, 1);
    g_param(1) = sum(g_voxel .* dE_deps);
    for j = 1:3
        g_param(1+j) = sum(g_voxel .* dE_dhole(:, j));
    end

    % ratio
    for pi_idx = 1:4
        if abs(g_FD(pi_idx)) > 1e-30
            all_ratios(pi_idx, mi) = g_param(pi_idx) / g_FD(pi_idx);
        else
            all_ratios(pi_idx, mi) = NaN;
        end
    end
end

%% 输出
fprintf('\n############################################################\n');
fprintf('#  根因隔离结果\n');
fprintf('############################################################\n');
fprintf('#  %-26s  %10s  %10s  %10s  %10s\n', 'Mode', ...
    'eps_r', 'hole_x', 'hole_y', 'hole_z');
fprintf('#  %-26s  %10s  %10s  %10s  %10s\n', '--------------------------', ...
    '----------', '----------', '----------', '----------');
for mi = 1:4
    fprintf('#  %-26s', modes{mi});
    for pi_idx = 1:4
        fprintf('  %10.4f', all_ratios(pi_idx, mi));
    end
    % CV
    r = all_ratios(:, mi);
    rv = r(isfinite(r) & abs(r) > 1e-20);
    if ~isempty(rv)
        cv = std(rv) / abs(mean(rv));
        fprintf('  CV=%.3f', cv);
    end
    fprintf('\n');
end

fprintf('#\n#  判定：CV < 0.1 的模式是正确的梯度提取方式\n');
best_cv = 1e10; best_mode = 0;
for mi = 1:4
    r = all_ratios(:, mi);
    rv = r(isfinite(r) & abs(r) > 1e-20);
    if ~isempty(rv)
        cv = std(rv) / abs(mean(rv));
        if cv < best_cv
            best_cv = cv;
            best_mode = mi;
        end
    end
end
if best_mode > 0
    fprintf('#  最佳模式: %s (CV=%.4f)\n', modes{best_mode}, best_cv);
    if best_cv < 0.1
        fprintf('#  *** 该模式 ratio 一致，是正确的梯度提取方式 ***\n');
    else
        fprintf('#  所有模式 CV > 0.1，根因可能在更上游（lambda 场本身或背景场残余）\n');
    end
end
fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir,'dir'), mkdir(results_dir); end
save(fullfile(results_dir, 'root_cause_result.mat'), 'all_ratios', 'g_FD', 'modes', 'param_names');
end

%% ====== 辅助函数 ======
function F = compute_F(model, voxel, grid, p, pf0, params, inner_pos, inner_mask, delta_sdf, J_obs, freqs)
    eps_r = params(1); hp = params(2:4);
    d_v = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = eps_r + (1.0-eps_r)*0.5*(1-tanh(d_v/delta_sdf));
    update_epsilon(model, voxel, p);
    pf = pf0; pf.freq=freqs(1); pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    Jo = max(sum(abs(J_obs).^2,2), 1e-12);
    F = mean(sum(abs(dJ).^2,2) ./ Jo / 6);
end
