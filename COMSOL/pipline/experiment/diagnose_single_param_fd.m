function diagnose_single_param_fd()
%DIAGNOSE_SINGLE_PARAM_FD 单参数 FD vs 伴随精确对比
%
%   对每个参数独立做 FD 扫描（多步长），同时计算该参数的伴随梯度
%   直接对比 ∂F/∂p_i 的 FD 值和伴随值
%
%   优势：消除多参数耦合，每个参数的 ratio/sign 独立判定

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  单参数 FD vs 伴随精确对比\n');
fprintf('#  每个参数独立扫描，消除多参数耦合\n');
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

%% 配置
eps_r_test = 4.0;
hole_pos_test = [0.015; 0.010; 0.005];
R_hole = 0.03;
N_freq = 1; freqs = [1.0e9];
delta_sdf = 0.008;
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);

%% 预计算 J_obs（真值）
fprintf('[SP] 预计算 J_obs...\n');
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
lc_obs = lightcone_project(grid, sf, pf0);
J_obs = lc_obs.J_obs_perp;

%% 计算伴随梯度（一次正演 + 一次伴随）
fprintf('\n[SP] 计算伴随梯度...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
J_hyp = lc.J_obs_perp;
Delta_J = J_obs - J_hyp;
J_obs_sq = sum(abs(J_obs).^2, 2);
J_obs_safe = max(J_obs_sq, 1e-12);
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J ./ J_obs_safe;

[lambda, adj_ok, lambda_gauss] = setup_exact_adjoint_source(model, voxel, grid, lc, pf);
if ~adj_ok, fprintf('[SP] [FAIL] 伴随求解失败\n'); return; end

% 体素梯度
N_inner = sum(inner_mask);
inner_idx = find(inner_mask);
k0_sq = pf.k0^2; dV_vec = voxel.dV;
g_voxel = zeros(N_inner, 1);
if ~isempty(E_gauss) && ~isempty(lambda_gauss) && size(E_gauss,1)==size(voxel.gauss_pos,1) && size(lambda_gauss,1)==size(voxel.gauss_pos,1)
    gw = voxel.gauss_w;
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gw(gpi) * dot(E_gauss(gp(gpi),:), lambda_gauss(gp(gpi),:));
        end
        g_voxel(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(gs) / N_freq;
    end
    fprintf('[SP] 使用 Gauss 积分\n');
else
    for vi = 1:N_inner
        g_voxel(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(dot(E_total(vi,:), lambda(vi,:))) / N_freq;
    end
    fprintf('[SP] 使用质心近似\n');
end

% 链式法则 → 各参数伴随梯度
g_adj = zeros(4, 1);
% eps_r: deps/deps_r = 0.5*(1+tanh(d/delta))
g_adj(1) = sum(g_voxel .* (0.5*(1+tanh(d_test/delta_sdf))));
% hole x/y/z
diff_v = inner_pos - hole_pos_test';
d_v = sqrt(sum(diff_v.^2, 2));
sech2 = 1./cosh(d_v/delta_sdf).^2;
deps_dd = -(1-eps_r_test)*0.5*sech2/delta_sdf;
for j = 1:3
    dd_dhole = -diff_v(:,j)./(d_v+1e-30);
    g_adj(1+j) = sum(g_voxel .* (deps_dd .* dd_dhole));
end

fprintf('\n[SP] 伴随梯度:\n');
fprintf('  eps_r  g_adj = %+.6e\n', g_adj(1));
fprintf('  hole_x g_adj = %+.6e\n', g_adj(2));
fprintf('  hole_y g_adj = %+.6e\n', g_adj(3));
fprintf('  hole_z g_adj = %+.6e\n', g_adj(4));

%% 单参数 FD 扫描
fprintf('\n[SP] ===== 单参数 FD 扫描 =====\n');

% F(p) 计算函数
params_0 = [eps_r_test; hole_pos_test];
param_names = {'eps_r', 'hole_x', 'hole_y', 'hole_z'};
deltas = {[0.1, 0.01, 0.001], [0.01, 0.001, 0.0001], [0.01, 0.001, 0.0001], [0.01, 0.001, 0.0001]};

all_g_fd = zeros(4, 1);
all_g_fd_ref = zeros(4, 1);  % 最小步长的 FD 值（参考）

for pi_idx = 1:4
    fprintf('\n--- 参数 %d: %s ---\n', pi_idx, param_names{pi_idx});

    for di = 1:length(deltas{pi_idx})
        delta = deltas{pi_idx}(di);

        % F(p + delta)
        pp = params_0; pp(pi_idx) = pp(pi_idx) + delta;
        F_plus = compute_F(model, voxel, grid, p, pf0, pp, inner_pos, inner_mask, ...
            delta_sdf, J_obs, freqs);

        % F(p - delta)
        pm = params_0; pm(pi_idx) = pm(pi_idx) - delta;
        F_minus = compute_F(model, voxel, grid, p, pf0, pm, inner_pos, inner_mask, ...
            delta_sdf, J_obs, freqs);

        g_fd = (F_plus - F_minus) / (2 * delta);
        fprintf('  delta=%.4e: F+=%.8e, F-=%.8e, g_FD=%+.8e\n', delta, F_plus, F_minus, g_fd);

        if di == length(deltas{pi_idx})
            all_g_fd_ref(pi_idx) = g_fd;  % 最小步长作为参考
        end
        all_g_fd(pi_idx) = g_fd;  % 最后一个覆盖
    end

    % 对比
    g_fd_val = all_g_fd_ref(pi_idx);
    g_adj_val = g_adj(pi_idx);
    ratio = g_adj_val / g_fd_val;
    sgn = sign(real(g_fd_val * g_adj_val));
    fprintf('  >>> g_FD=%.6e, g_adj=%.6e, ratio=%.4f, sign=%+d\n', ...
        g_fd_val, g_adj_val, real(ratio), sgn);
end

%% 汇总
fprintf('\n\n############################################################\n');
fprintf('#  单参数对比汇总\n');
fprintf('############################################################\n');
fprintf('#  %-8s  %14s  %14s  %10s  %6s\n', '参数', 'g_FD', 'g_adjoint', 'ratio', 'sign');
fprintf('#  %-8s  %14s  %14s  %10s  %6s\n', '--------', '--------------', '--------------', '----------', '------');
for i = 1:4
    ri = real(g_adj(i) / all_g_fd_ref(i));
    sg = sign(real(all_g_fd_ref(i)) * real(g_adj(i)));
    fprintf('#  %-8s  %+14.6e  %+14.6e  %10.4f  %+d\n', ...
        param_names{i}, all_g_fd_ref(i), g_adj(i), ri, sg);
end

% 向量 cos（供参考，但单参数更准确）
cos_vec = dot(all_g_fd_ref, g_adj) / (norm(all_g_fd_ref) * norm(g_adj));
fprintf('#\n#  向量 cos(g_FD, g_adj) = %.6f（仅供参考）\n', cos_vec);

% 单参数判据
fprintf('#\n#  单参数判定:\n');
n_pass = 0;
for i = 1:4
    ri = real(g_adj(i) / all_g_fd_ref(i));
    sg = sign(real(all_g_fd_ref(i)) * real(g_adj(i)));
    % sign 必须为 +1，ratio 在合理范围（非零非无穷）
    pass_sign = (sg > 0);
    pass_ratio = (abs(ri) > 0.01 && abs(ri) < 100);
    if pass_sign && pass_ratio, n_pass = n_pass + 1; end
    fprintf('#    %-8s: sign=%s ratio=%.4f -> %s\n', ...
        param_names{i}, ternary_s(pass_sign,'OK','WRONG'), ri, ...
        ternary_s(pass_sign && pass_ratio, 'PASS', 'FAIL'));
end
fprintf('#\n#  通过 %d/4 参数\n', n_pass);
fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir,'dir'), mkdir(results_dir); end
save(fullfile(results_dir,'single_param_fd_result.mat'), ...
    'all_g_fd_ref', 'g_adj', 'cos_vec', 'param_names');
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

function s = ternary_s(cond, a, b)
    if cond, s=a; else, s=b; end
end
