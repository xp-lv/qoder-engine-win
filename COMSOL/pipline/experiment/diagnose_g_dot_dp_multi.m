function diagnose_g_dot_dp_multi()
%DIAGNOSE_G_DOT_DP_MULTI 多点验证 g_adjoint·dp > 0
%
%   在凸区域路径 p(t) = p_init + t*(p_true - p_init) 上
%   取 t = 0.2, 0.4, 0.6, 0.8 四个点
%   每个点做一次正演+伴随，计算 g_adjoint·dp
%
%   如果所有点 g_adjoint·dp > 0 -> 伴随梯度始终指向真值 -> 正确
%   如果有 g_adjoint·dp < 0 -> 伴随梯度背离真值 -> 有问题

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  多点 g_adjoint·dp 验证\n');
fprintf('#  路径 p(t) = p_init + t*(p_true - p_init)\n');
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

delta_sdf = 0.008;
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);

p_init = [3.0; 0; 0; 0];
p_true = [5.0; 0.03; 0.02; 0.01];
dp = p_true - p_init;

%% 预计算 J_obs（真值）
fprintf('[GP] 预计算 J_obs...\n');
voxel_truth = voxel;
d_true = sqrt(sum((inner_pos - p_true(2:4)').^2, 2));
voxel_truth.epsilon_r(inner_mask) = p_true(1) + (1.0-p_true(1))*0.5*(1-tanh(d_true/delta_sdf));
update_epsilon(model, voxel_truth, p);
pf0 = p; pf0.freq=1e9; pf0.omega=2*pi*pf0.freq; pf0.k0=pf0.omega/p.c; pf0.lambda=p.c/pf0.freq;
model.param.set('freq', num2str(pf0.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', pf0.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
sf = extract_scattered(model, grid);
J_obs = lightcone_project(grid, sf, pf0).J_obs_perp;

%% 多点验证
t_values = [0.2, 0.4, 0.6, 0.8];
results = zeros(length(t_values), 6);  % [t, g_dot_dp_adj, g_dot_dp_FD, F, eps_r, hole]

for ti = 1:length(t_values)
    t = t_values(ti);
    pt = p_init + t * dp;
    fprintf('\n[GP] ====== t=%.1f: eps_r=%.2f, hole=[%.4f, %.4f, %.4f] ======\n', ...
        t, pt(1), pt(2), pt(3), pt(4));

    % 设 epsilon 分布
    d_test = sqrt(sum((inner_pos - pt(2:4)').^2, 2));
    voxel.epsilon_r(inner_mask) = pt(1) + (1.0-pt(1))*0.5*(1-tanh(d_test/delta_sdf));
    update_epsilon(model, voxel, p);
    pf = pf0;

    % 正演
    [E_total, ~, E_gauss] = solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    J_hyp = lc.J_obs_perp;
    Delta_J = J_obs - J_hyp;
    F_val = mean(sum(abs(Delta_J).^2, 2)) / 6;

    % 伴随源（去归一化 + bilinear）
    lc.k_vec = pf.k0 * lc.k_dir;
    lc.J_obs_perp = J_obs;
    lc.Delta_J_perp = Delta_J;
    [Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
    f_adj = Js + Ms;

    [lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
    if ~ok
        fprintf('[GP] [FAIL] 伴随求解失败\n');
        continue;
    end

    % bilinear dot 梯度
    N_inner = sum(inner_mask);
    inner_idx = find(inner_mask);
    k0_sq = pf.k0^2; dV_vec = voxel.dV;
    dE_deps = 0.5*(1+tanh(d_test/delta_sdf));
    diff_v = inner_pos - pt(2:4)';
    d_v = sqrt(sum(diff_v.^2, 2));
    sech2 = 1./cosh(d_v/delta_sdf).^2;
    deps_dd = -(1-pt(1))*0.5*sech2/delta_sdf;
    dE_dhole = zeros(N_inner, 3);
    for j = 1:3
        dE_dhole(:, j) = deps_dd .* (-diff_v(:,j)./(d_v+1e-30));
    end

    g_voxel = zeros(N_inner, 1);
    gauss_w = voxel.gauss_w;
    use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
        && size(E_gauss,1)==size(voxel.gauss_pos,1) ...
        && size(lambda_gauss,1)==size(voxel.gauss_pos,1);

    if use_gauss
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            v_idx = inner_idx(vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gauss_w(gpi) * real(sum(lambda_gauss(gp(gpi),:) .* E_gauss(gp(gpi),:)));
            end
            g_voxel(vi) = k0_sq * dV_vec(v_idx) * gs;
        end
    else
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            g_voxel(vi) = k0_sq * dV_vec(v_idx) * real(sum(lambda(vi,:) .* E_total(vi,:)));
        end
    end

    g_adj = zeros(4, 1);
    g_adj(1) = sum(g_voxel .* dE_deps);
    for j = 1:3
        g_adj(1+j) = sum(g_voxel .* dE_dhole(:,j));
    end

    % g_adjoint · dp
    gdp_adj = dot(g_adj, dp);

    % 单参数 FD（最小步长）
    fd_steps = [0.001, 0.0001, 0.0001, 0.0001];
    g_FD = zeros(4, 1);
    for pi_idx = 1:4
        delta = fd_steps(pi_idx);
        pp = pt; pp(pi_idx) = pp(pi_idx) + delta;
        F_plus = compute_F(model, voxel, grid, p, pf0, pp, inner_pos, inner_mask, delta_sdf, J_obs);
        pm = pt; pm(pi_idx) = pm(pi_idx) - delta;
        F_minus = compute_F(model, voxel, grid, p, pf0, pm, inner_pos, inner_mask, delta_sdf, J_obs);
        g_FD(pi_idx) = (F_plus - F_minus) / (2 * delta);
    end
    gdp_FD = dot(g_FD, dp);

    results(ti, :) = [t, gdp_adj, gdp_FD, F_val, 0, 0];

    fprintf('  g_adj   = [%.4e, %.4e, %.4e, %.4e]\n', g_adj);
    fprintf('  g_FD    = [%.4e, %.4e, %.4e, %.4e]\n', g_FD);
    fprintf('  g_adj·dp  = %+.6e\n', gdp_adj);
    fprintf('  g_FD·dp   = %+.6e\n', gdp_FD);
    fprintf('  F         = %.6e\n', F_val);
    if gdp_adj > 0
        fprintf('  g_adj·dp > 0 -> 伴随指向真值 ✓\n');
    else
        fprintf('  g_adj·dp < 0 -> 伴随背离真值 ✗\n');
    end
    if gdp_FD > 0
        fprintf('  g_FD·dp  > 0 -> FD 指向真值 ✓\n');
    else
        fprintf('  g_FD·dp  < 0 -> FD 背离真值 ✗ (不在凸区域)\n');
    end
end

%% 汇总
fprintf('\n\n############################################################\n');
fprintf('#  多点 g·dp 汇总\n');
fprintf('############################################################\n');
fprintf('#  t     F(t)          g_adj·dp       g_FD·dp        伴随   FD\n');
fprintf('#  ----  ----------    -----------    -----------    ----   ----\n');
for ti = 1:length(t_values)
    adj_ok = '+';
    fd_ok = '+';
    if results(ti, 2) <= 0, adj_ok = 'X'; end
    if results(ti, 3) <= 0, fd_ok = 'X'; end
    fprintf('#  %.1f   %.4e    %+.6e   %+.6e   %-4s   %-4s\n', ...
        results(ti,1), results(ti,4), results(ti,2), results(ti,3), adj_ok, fd_ok);
end
fprintf('#\n');
n_adj_pos = sum(results(:,2) > 0);
n_fd_pos = sum(results(:,3) > 0);
fprintf('#  伴随 g·dp > 0: %d/%d 点\n', n_adj_pos, length(t_values));
fprintf('#  FD g·dp > 0:   %d/%d 点\n', n_fd_pos, length(t_values));
fprintf('#\n');
if n_adj_pos == length(t_values)
    fprintf('#  *** 伴随梯度在所有点都指向真值！伴随法方向正确！***\n');
else
    fprintf('#  伴随梯度在部分点背离真值\n');
end
fprintf('############################################################\n');
end

function F = compute_F(model, voxel, grid, p, pf0, params, inner_pos, inner_mask, delta_sdf, J_obs)
    eps_r = params(1); hp = params(2:4);
    d_v = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = eps_r + (1.0-eps_r)*0.5*(1-tanh(d_v/delta_sdf));
    update_epsilon(model, voxel, p);
    pf = pf0; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/p.c; pf.lambda=p.c/pf.freq;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    F = mean(sum(abs(dJ).^2, 2)) / 6;
end
