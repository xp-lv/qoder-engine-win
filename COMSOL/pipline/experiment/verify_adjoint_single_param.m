function verify_adjoint_single_param()
%VERIFY_ADJOINT_SINGLE_PARAM 单参数（eps_r）伴随法 vs FD 方向验证
%
%   hole 固定在真值位置，只变动 eps_r
%   在凸区域内 eps_r 梯度方向必然指向真值（增大 eps_r 降低 F）
%   这是最干净的验证——排除 hole 参数的干扰

fprintf('\n========== 单参数（eps_r）伴随法验证 ==========\n');

addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'algorithm');

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
inner_idx = find(inner_mask);
N_inner = sum(inner_mask);

% hole 固定在真值位置
hole_fixed = [0.03; 0.02; 0.01];
eps_r_true = 5.0;

fprintf('hole 固定在真值: [%.3f, %.3f, %.3f]\n', hole_fixed);
fprintf('eps_r 真值: %.1f\n', eps_r_true);

% 预计算 J_obs（真值 eps_r=5.0）
d_t = sqrt(sum((inner_pos - hole_fixed').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_true + (1-eps_r_true)*0.5*(1-tanh(d_t/delta_sdf));
update_epsilon(model, voxel, p);
pf = p; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
solve_forward(model, voxel, pf);
sf = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf, pf);
J_obs = lc_obs.J_obs_perp;
Jo = sum(abs(J_obs).^2,2); Jos = max(Jo, 1e-12);

% 测试多个 eps_r 值
eps_r_test_values = [3.0, 3.5, 4.0, 4.5, 4.8];

fprintf('\n| eps_r | F          | g_FD       | g_adjoint  | cos(FD,adj) | FD→  | adj→  |\n');
fprintf('|-------|------------|------------|------------|-------------|------|------|\n');

for ei = 1:length(eps_r_test_values)
    eps_r_test = eps_r_test_values(ei);

    % 设当前 eps_r
    d_cur = sqrt(sum((inner_pos - hole_fixed').^2, 2));
    voxel.epsilon_r(inner_mask) = eps_r_test + (1-eps_r_test)*0.5*(1-tanh(d_cur/delta_sdf));
    update_epsilon(model, voxel, pf);

    % 正演 + F
    [E_total, ~, E_gauss] = solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    F_cur = mean(sum(abs(dJ).^2,2) ./ Jos / 6);

    % FD 梯度（central，δ=0.01）
    delta_fd = 0.01;
    % F+
    er_p = eps_r_test + delta_fd;
    voxel.epsilon_r(inner_mask) = er_p + (1-er_p)*0.5*(1-tanh(d_cur/delta_sdf));
    update_epsilon(model, voxel, pf);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf, pf);
    dJ_p = J_obs - lc_p.J_obs_perp;
    F_p = mean(sum(abs(dJ_p).^2,2) ./ Jos / 6);

    % F-
    er_m = eps_r_test - delta_fd;
    voxel.epsilon_r(inner_mask) = er_m + (1-er_m)*0.5*(1-tanh(d_cur/delta_sdf));
    update_epsilon(model, voxel, pf);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf, pf);
    dJ_m = J_obs - lc_m.J_obs_perp;
    F_m = mean(sum(abs(dJ_m).^2,2) ./ Jos / 6);

    g_FD = (F_p - F_m) / (2*delta_fd);

    % 恢复测试点 eps_r
    voxel.epsilon_r(inner_mask) = eps_r_test + (1-eps_r_test)*0.5*(1-tanh(d_cur/delta_sdf));
    update_epsilon(model, voxel, pf);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    J_hyp = lc.J_obs_perp;
    Delta_J = J_obs - J_hyp;
    J_obs_safe = max(sum(abs(J_obs).^2,2), 1e-12);

    % 伴随梯度
    lc_adj = lc;
    lc_adj.k_vec = pf.k0 * lc.k_dir;
    lc_adj.J_obs_perp = J_obs;
    lc_adj.Delta_J_perp = Delta_J ./ J_obs_safe;

    [lambda_fi, adj_ok, lambda_gauss] = setup_exact_adjoint_source(model, voxel, grid, lc_adj, pf);

    if ~adj_ok
        fprintf('| %.1f   | %.4e  | (adj fail) |            |             |      |      |\n', eps_r_test, F_cur);
        continue;
    end

    % g_voxel = -k0²·Re(λ·E)·ΔV
    k0_sq = pf.k0^2;
    dV_vec = voxel.dV;
    use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
                && size(E_gauss,1) == size(voxel.gauss_pos,1);
    gauss_w = voxel.gauss_w;

    g_voxel = zeros(N_inner, 1);
    if use_gauss
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gauss_w(gpi) * dot(E_gauss(gp(gpi),:), lambda_gauss(gp(gpi),:));
            end
            g_voxel(vi) = -k0_sq * dV_vec(v_idx) * real(gs);
        end
    else
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            g_voxel(vi) = -k0_sq * dV_vec(v_idx) * real(dot(E_total(vi,:), lambda_fi(vi,:)));
        end
    end

    % 链式法则：∂F/∂eps_r = Σ g_voxel · dε/d(eps_r)
    dE_deps = 0.5 * (1 + tanh(d_cur / delta_sdf));  % SDF 链式法则
    g_adjoint = sum(g_voxel .* dE_deps);

    % cos（1D 只有同号/异号）
    if g_FD * g_adjoint > 0
        cos_1d = '+1 (同向)';
    else
        cos_1d = '-1 (反向!)';
    end

    % 方向判定
    % eps_r < true → 正确方向 = 增大 eps_r → g 应 < 0（∂F/∂eps_r < 0 意味着增大 eps_r 降低 F）
    % 注意：g_FD 和 g_adjoint 是 ∂F/∂eps_r（上升方向）
    %   eps_r < true 时 F 随 eps_r 增大而降低 → ∂F/∂eps_r < 0 → g < 0 → 正确
    %   eps_r > true 时 F 随 eps_r 增大而增大 → ∂F/∂eps_r > 0 → g > 0 → 正确
    if eps_r_test < eps_r_true
        fd_dir = ternary(g_FD < 0, '↑eps', '↓eps!');
        adj_dir = ternary(g_adjoint < 0, '↑eps', '↓eps!');
    else
        fd_dir = ternary(g_FD > 0, '↓eps', '↑eps!');
        adj_dir = ternary(g_adjoint > 0, '↓eps', '↑eps!');
    end

    fprintf('| %.1f   | %.4e  | %+.4e | %+.4e | %s  | %s  | %s  |\n', ...
        eps_r_test, F_cur, g_FD, g_adjoint, cos_1d, fd_dir, adj_dir);
end

fprintf('\n========== 结论 ==========\n');
fprintf('如果 FD 和伴随法在所有 eps_r 点都同号（cos=+1）\n');
fprintf('→ 伴随法的 eps_r 梯度方向正确\n');
fprintf('→ 可扩展到多参数验证\n');
fprintf('============================\n\n');

end

function s = ternary(cond, a, b)
if cond, s = a; else, s = b; end
end
