function verify_fd_convergence()
%VERIFY_FD_CONVERGENCE 验证 FD 方向的步长收敛性（4 参数全量）
%
%   对 eps_r + hole_x/y/z 各用 4 种步长验证 FD 方向稳定性
%   特别关注 hole 分量——如果 FD 在 hole 上方向不稳定，说明 SDF 过渡带导致的数值噪声

fprintf('\n========== FD 步长收敛性验证（4 参数全量）==========\n');

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

% 测试点（iter3 状态）
eps_r_test = 4.0;
hole_pos_test = [0.0003; 0.0089; 0.0046];

% 真值
eps_r_true = 5.0;
hole_true = [0.03; 0.02; 0.01];

% J_obs 预计算（只算一次）
d_t = sqrt(sum((inner_pos - hole_true').^2, 2));
voxel_t = voxel;
voxel_t.epsilon_r(inner_mask) = eps_r_true + (1-eps_r_true)*0.5*(1-tanh(d_t/delta_sdf));
update_epsilon(model, voxel_t, p);
pf = p; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
solve_forward(model, voxel_t, pf);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
J_obs = lc.J_obs_perp;
Jo = sum(abs(J_obs).^2,2); Jos = max(Jo, 1e-12);

% 4 参数 × 4 步长 = 16 次 FD 计算（每次 2 正演 = 32 次正演）
param_names = {'eps_r', 'hole_x', 'hole_y', 'hole_z'};
params_0 = [eps_r_test; hole_pos_test];
deltas_eps = [0.1, 0.01, 0.001, 0.0001];     % eps_r 步长
deltas_hole = [0.01, 0.001, 0.0001, 0.00001]; % hole 步长（物理尺度不同）

fprintf('\n测试点: eps_r=%.4f, hole=[%.4f, %.4f, %.4f]\n', eps_r_test, hole_pos_test);
fprintf('真值:   eps_r=%.4f, hole=[%.4f, %.4f, %.4f]\n', eps_r_true, hole_true);
fprintf('hole_err=%.4fm\n', norm(hole_pos_test - hole_true));

all_stable = true;

for param_i = 1:4
    pname = param_names{param_i};
    if param_i == 1
        deltas = deltas_eps;
    else
        deltas = deltas_hole;
    end
    
    fprintf('\n--- %s FD 步长收敛性 ---\n', pname);
    fprintf('| δ          | g_FD          | sign |\n');
    fprintf('|------------|---------------|------|\n');
    
    g_vals = zeros(size(deltas));
    for di = 1:length(deltas)
        delta = deltas(di);
        pp = params_0; pp(param_i) = pp(param_i) + delta;
        pm = params_0; pm(param_i) = pm(param_i) - delta;
        
        % F+ （★ 内联，避免 struct 值传递 ★）
        d_p = sqrt(sum((inner_pos - pp(2:4)').^2, 2));
        voxel.epsilon_r(inner_mask) = pp(1) + (1-pp(1))*0.5*(1-tanh(d_p/delta_sdf));
        update_epsilon(model, voxel, pf);
        solve_forward(model, voxel, pf);
        sf = extract_scattered(model, grid);
        lc_p = lightcone_project(grid, sf, pf);
        dJ_p = J_obs - lc_p.J_obs_perp;
        F_p = mean(sum(abs(dJ_p).^2,2) ./ Jos / 6);
        
        % F-
        d_m = sqrt(sum((inner_pos - pm(2:4)').^2, 2));
        voxel.epsilon_r(inner_mask) = pm(1) + (1-pm(1))*0.5*(1-tanh(d_m/delta_sdf));
        update_epsilon(model, voxel, pf);
        solve_forward(model, voxel, pf);
        sf = extract_scattered(model, grid);
        lc_m = lightcone_project(grid, sf, pf);
        dJ_m = J_obs - lc_m.J_obs_perp;
        F_m = mean(sum(abs(dJ_m).^2,2) ./ Jos / 6);
        
        g_vals(di) = (F_p - F_m) / (2*delta);
        
        sgn = '+'; if g_vals(di) < 0, sgn = '-'; end
        fprintf('| %.4e   | %+.6e  |  %s   |\n', delta, g_vals(di), sgn);
    end
    
    signs = sign(g_vals);
    stable = (length(unique(signs(signs~=0))) <= 1);
    if stable
        fprintf('→ ★ 方向稳定（所有步长同号）★\n');
    else
        fprintf('→ ⚠ 方向不稳定（步长间符号变化）→ FD 在此参数上不可靠\n');
        all_stable = false;
    end
    
    % 截断误差估计
    if abs(g_vals(2)) > 0 && abs(g_vals(1)) > 0
        rel = abs(g_vals(2)-g_vals(1))/abs(g_vals(1));
        fprintf('  截断误差(δ1→δ2): %.2f%%\n', rel*100);
    end
end

fprintf('\n========== 总结 ==========\n');
if all_stable
    fprintf('★★★ 全部 4 参数 FD 方向在步长范围内稳定 ★★★\n');
else
    fprintf('⚠ 部分参数 FD 方向不稳定——需进一步分析\n');
end
fprintf('============================\n\n');

end
