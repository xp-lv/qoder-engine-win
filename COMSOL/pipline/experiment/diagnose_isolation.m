function diagnose_isolation()
%DIAGNOSE_ISOLATION Js-only vs Ms-only 隔离 FD 诊断
%   分别测试 Js（电流核）和 Ms（磁流核）单独作为伴随源时的 FD 对齐情况
%
%   用法（在 pipline 目录下）:
%     >> diagnose_isolation
%
%   输出：三种模式的 FD 对比表
%     模式 A: 双源（Js + Ms）— 基线
%     模式 B: Js-only（Ms = 0）
%     模式 C: Ms-only（Js = 0）

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
addpath(fullfile(pipline_dir,'config'), ...
        fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), ...
        fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), ...
        fullfile(pipline_dir,'algorithm'));

fprintf('\n############################################################\n');
fprintf('#  Js-only vs Ms-only 隔离 FD 诊断\n');
fprintf('############################################################\n\n');

%% 1. 初始化
fprintf('[ISO] 加载 config + 测量网格...\n');
p = config();
grid = build_measurement_grid(p);

fprintf('[ISO] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[ISO] [FAIL] mphstart: %s\n', ME.message);
        return;
    end
end
fprintf('[ISO] 加载模型...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

fprintf('[ISO] 提取 FEM 网格...\n');
R_scatter = p.a_scatter;
voxel = fem_mesh_utils(model, p, R_scatter);

%% 2. 测试点（t=0.5）
eps_r_test = 4.0;
hole_pos_test = [0.015; 0.010; 0.005];
R_hole = 0.03;
N_freq = 1;
freqs = [1.0e9];
delta_sdf = 0.008;
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);

p_init = [3.0; 0; 0; 0];
p_true_vec = [5.0; 0.03; 0.02; 0.01];
dp_true = p_true_vec - p_init;

%% 3. 预计算 J_obs
fprintf('[ISO] 预计算 J_obs...\n');
voxel_truth = voxel;
eps_r_true_val = 5.0;
hole_pos_true = [0.03; 0.02; 0.01];
d_true = sqrt(sum((inner_pos - hole_pos_true').^2, 2));
voxel_truth.epsilon_r(inner_mask) = eps_r_true_val + (1.0 - eps_r_true_val) * 0.5 * (1 - tanh(d_true / delta_sdf));
update_epsilon(model, voxel_truth, p);

J_obs_multi = cell(1, N_freq);
for fi = 1:N_freq
    pf = p;
    pf.freq = freqs(fi); pf.omega = 2*pi*pf.freq;
    pf.k0 = pf.omega / pf.c; pf.lambda = pf.c / pf.freq;
    solve_forward_quiet_local(model, voxel_truth, pf);
    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, pf);
    J_obs_multi{fi} = lc_obs.J_obs_perp;
end

%% 4. 计算 FD 梯度（只算一次，所有模式共用）
fprintf('\n[ISO] 计算 central FD 梯度（8 次 COMSOL 正演）...\n');
delta_eps_r = 0.01;
delta_hole = 1e-3;
params_0 = [eps_r_test; hole_pos_test];
N_param = 4;
g_FD = zeros(N_param, 1);

for i = 1:N_param
    dp = zeros(N_param, 1);
    if i == 1, dp(i) = delta_eps_r; else, dp(i) = delta_hole; end

    p_plus = params_0 + dp;
    er = p_plus(1); hp = p_plus(2:4);
    d_p = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = er + (1.0 - er) * 0.5 * (1 - tanh(d_p / delta_sdf));
    update_epsilon(model, voxel, p);
    pf = p; pf.freq=freqs(1); pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf, pf);
    dJ = J_obs_multi{1} - lc_p.J_obs_perp;
    Jo = sum(abs(J_obs_multi{1}).^2,2); Jos = max(Jo,1e-12);
    F_plus = mean(sum(abs(dJ).^2,2) ./ Jos / 6);

    p_minus = params_0 - dp;
    er = p_minus(1); hp = p_minus(2:4);
    d_m = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = er + (1.0 - er) * 0.5 * (1 - tanh(d_m / delta_sdf));
    update_epsilon(model, voxel, p);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf, pf);
    dJ = J_obs_multi{1} - lc_m.J_obs_perp;
    F_minus = mean(sum(abs(dJ).^2,2) ./ Jos / 6);

    g_FD(i) = (F_plus - F_minus) / (2 * dp(i));
    fprintf('[ISO]   FD g_%d = %.6e\n', i, g_FD(i));
end

%% 5. 计算伴随源（只构建一次）
fprintf('\n[ISO] 构建伴随源...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0 - eps_r_test) * 0.5 * (1 - tanh(d_test / delta_sdf));
update_epsilon(model, voxel, p);

pf = p; pf.freq=freqs(1); pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);
sf = extract_scattered(model, grid);
lc_new = lightcone_project(grid, sf, pf);
J_hyp = lc_new.J_obs_perp;
J_obs_fi = J_obs_multi{1};
Delta_J = J_obs_fi - J_hyp;
J_obs_sq = sum(abs(J_obs_fi).^2, 2);
J_obs_safe = max(J_obs_sq, 1e-12);

lc_new.k_vec = pf.k0 * lc_new.k_dir;
lc_new.J_obs_perp = J_obs_fi;
lc_new.Delta_J_perp = Delta_J ./ J_obs_safe;

[Js_full, Ms_full, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc_new, pf);

fprintf('[ISO] |Js| mean=%.4e, |Ms| mean=%.4e\n', ...
    mean(vecnorm(Js_full,2,2)), mean(vecnorm(Ms_full,2,2)));

%% 6. 三种模式分别求解伴随并计算梯度
N_inner = sum(inner_mask);
inner_idx = find(inner_mask);
k0_sq = pf.k0^2;
dV_vec = voxel.dV;
use_gauss = ~isempty(E_gauss) && ~isempty(voxel.gauss_pos) && size(E_gauss,1)==size(voxel.gauss_pos,1);
gauss_w = voxel.gauss_w;

modes = {'dual (Js+Ms)', 'Js-only', 'Ms-only'};
Js_modes = {Js_full, Js_full, zeros(size(Js_full))};
Ms_modes = {Ms_full, zeros(size(Ms_full)), Ms_full};

all_g_adj = zeros(N_param, 3);

for mi = 1:3
    fprintf('\n[ISO] ===== 模式 %d: %s =====\n', mi, modes{mi});

    Js_mi = Js_modes{mi};
    Ms_mi = Ms_modes{mi};

    % 调用 solve_adjoint（Ms 非空走双源路径，Ms 空=[]走旧路径）
    % Js-only 和 Ms-only 都传零矩阵（非空），让双源路径在源为零时自然不起作用
    if isempty(Ms_mi)
        Ms_mi = zeros(size(Ms_full));
    end

    [lambda_fi, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, pf, Js_mi, source_pos, Ms_mi);

    if ~adj_ok
        fprintf('[ISO]   伴随求解失败\n');
        continue;
    end

    % 体素梯度
    g_voxel = zeros(N_inner, 1);
    if use_gauss
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gauss_w(gpi) * dot(E_gauss(gp(gpi),:), lambda_gauss(gp(gpi),:));
            end
            g_voxel(vi) = -k0_sq * dV_vec(v_idx) * real(gs) / N_freq;
        end
    else
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            g_voxel(vi) = -k0_sq * dV_vec(v_idx) * real(dot(E_total(vi,:), lambda_fi(vi,:))) / N_freq;
        end
    end

    % 链式法则 → g_param
    dE_deps = compute_dE_deps_sdf(voxel, hole_pos_test, R_hole, eps_r_test);
    all_g_adj(1, mi) = sum(g_voxel .* dE_deps);
    for j = 1:3
        dE_dhole_j = compute_dE_dhole_sdf(voxel, hole_pos_test, R_hole, eps_r_test, j);
        all_g_adj(1+j, mi) = sum(g_voxel .* dE_dhole_j);
    end

    % 输出
    names = {'eps_r','hole_x','hole_y','hole_z'};
    fprintf('[ISO]   | 参数      | g_FD         | g_adjoint    | ratio  | sign |\n');
    for i = 1:N_param
        if abs(g_FD(i)) > 1e-30
            ri = all_g_adj(i,mi) / g_FD(i);
        else
            ri = NaN;
        end
        sg = sign(g_FD(i) * all_g_adj(i,mi));
        fprintf('[ISO]   | %-9s | %.4e | %.4e | %6.3f | %+d |\n', ...
            names{i}, g_FD(i), all_g_adj(i,mi), ri, sg);
    end
    cv_g = dot(g_FD, all_g_adj(:,mi)) / (norm(g_FD) * norm(all_g_adj(:,mi)));
    fprintf('[ISO]   cos(g_FD, g_adj) = %.6f\n', cv_g);
end

%% 7. 汇总
fprintf('\n\n############################################################\n');
fprintf('#  隔离诊断汇总\n');
fprintf('############################################################\n');
fprintf('#  %-18s  cos(g_FD,g_adj)  eps_r sign  hole sign  ratio范围\n', '模式');
for mi = 1:3
    cv_g = dot(g_FD, all_g_adj(:,mi)) / (norm(g_FD) * norm(all_g_adj(:,mi)));
    eps_sign = sign(g_FD(1) * all_g_adj(1,mi));
    hole_signs = sign(g_FD(2:4) .* all_g_adj(2:4,mi));
    hole_consistent = all(hole_signs == eps_sign);
    ratios = all_g_adj(:,mi) ./ g_FD;
    ratios_valid = ratios(isfinite(ratios) & abs(g_FD)>1e-20);
    if isempty(ratios_valid)
        ratio_range_str = 'N/A';
    else
        ratio_range_str = sprintf('[%.4f, %.4f]', min(abs(ratios_valid)), max(abs(ratios_valid)));
    end
    fprintf('#  %-18s  %+8.4f        %+d         %s     %s\n', ...
        modes{mi}, cv_g, eps_sign, ...
        ternary_str(hole_consistent, '一致', '分裂'), ratio_range_str);
end
fprintf('#\n');
fprintf('#  判定：\n');
fprintf('#    若 Js-only cos≈1 → Ms 弱形式权重有问题\n');
fprintf('#    若 Ms-only cos≈1 → Js 弱形式权重有问题\n');
fprintf('#    若两者都 cos<0.95 → 共轭约定或 lambda 提取有问题\n');
fprintf('############################################################\n');

% 保存
save(fullfile('data','results','isolation_diag.mat'), 'g_FD', 'all_g_adj', 'modes');

%% ====== 辅助函数 ======
function solve_forward_quiet_local(model, voxel, p)
    original_freq = p.freq;
    try
        model.param.set('freq', num2str(p.freq));
        try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
    catch
    end
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end
    try
        s1 = model.sol('sol1').feature('s1');
        try s1.feature('dDirect'); catch, s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso'); end
        try s1.feature('fc1').set('linsolver','dDirect'); catch, end
    catch
    end
    model.sol('sol1').runAll();
end

function dE_deps = compute_dE_deps_sdf(voxel, hole_pos, R_hole, eps_r_body)
    delta = 0.008;
    inner = voxel.mask_interior;
    pos = voxel.pos(inner, :);
    d = sqrt(sum((pos - hole_pos').^2, 2));
    dE_deps = 0.5 * (1 + tanh(d / delta));
end

function dE_dhole = compute_dE_dhole_sdf(voxel, hole_pos, R_hole, eps_r_body, j)
    delta = 0.008;
    inner = voxel.mask_interior;
    pos = voxel.pos(inner, :);
    diff = pos - hole_pos';
    d = sqrt(sum(diff.^2, 2));
    sech2 = 1 ./ cosh(d / delta).^2;
    deps_dd = -(1 - eps_r_body) * 0.5 * sech2 / delta;
    dd_dhole = -diff(:, j) ./ (d + 1e-30);
    dE_dhole = deps_dd .* dd_dhole;
end

function s = ternary_str(cond, a, b)
    if cond, s = a; else, s = b; end
end
end
