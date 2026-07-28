function find_convex_region()
%FIND_CONVEX_REGION 沿初始值→真值直线扫描 F，找到凸区域
%
%   参数化路径：p(t) = p_init + t·(p_true − p_init)，t ∈ [0, 1]
%   t=0 → 初始值，t=1 → 真值
%   在每个 t 点计算 F(p(t))，检查单调性
%
%   凸区域 = F 沿路径单调下降的 t 区间

fprintf('\n========== 凸区域扫描 ==========\n');

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

% 初始值和真值
eps_r_init = 3.0;    hole_init = [0; 0; 0];
eps_r_true = 5.0;    hole_true = [0.03; 0.02; 0.01];

% 参数向量
p_init = [eps_r_init; hole_init];
p_true = [eps_r_true; hole_true];
dp = p_true - p_init;  % 真值方向

fprintf('初始值: eps_r=%.1f, hole=[%.3f,%.3f,%.3f]\n', eps_r_init, hole_init);
fprintf('真值:   eps_r=%.1f, hole=[%.3f,%.3f,%.3f]\n', eps_r_true, hole_true);
fprintf('参数差: deps=%.1f, dhole=[%.3f,%.3f,%.3f]\n', dp(1), dp(2:4));

% 预计算 J_obs（真值）
d_t = sqrt(sum((inner_pos - hole_true').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_true + (1-eps_r_true)*0.5*(1-tanh(d_t/delta_sdf));
update_epsilon(model, voxel, p);
pf = p; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
solve_forward(model, voxel, pf);
sf = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf, pf);
J_obs = lc_obs.J_obs_perp;
Jo = sum(abs(J_obs).^2,2); Jos = max(Jo, 1e-12);

% 沿路径扫描
t_values = linspace(0, 1, 21);  % 21 个点
F_values = zeros(size(t_values));

fprintf('\n| t     | eps_r  | hole_x  | hole_y  | hole_z  | F          | ΔF          |\n');
fprintf('|-------|--------|---------|---------|---------|------------|-------------|\n');

for ti = 1:length(t_values)
    t = t_values(ti);
    pt = p_init + t * dp;

    % 计算F
    d = sqrt(sum((inner_pos - pt(2:4)').^2, 2));
    voxel.epsilon_r(inner_mask) = pt(1) + (1-pt(1))*0.5*(1-tanh(d/delta_sdf));
    update_epsilon(model, voxel, pf);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    F_values(ti) = mean(sum(abs(dJ).^2,2) ./ Jos / 6);

    if ti > 1
        dF = F_values(ti) - F_values(ti-1);
        fprintf('| %.2f  | %.3f  | %.4f  | %.4f  | %.4f  | %.4e  | %+.4e  |\n', ...
            t, pt(1), pt(2), pt(3), pt(4), F_values(ti), dF);
    else
        fprintf('| %.2f  | %.3f  | %.4f  | %.4f  | %.4f  | %.4e  |      —      |\n', ...
            t, pt(1), pt(2), pt(3), pt(4), F_values(ti));
    end
end

% 分析凸区域
fprintf('\n--- 凸区域分析 ---\n');

% 找 F 单调下降的区间
dF = diff(F_values);
monotone_decreasing = all(dF <= 0);

if monotone_decreasing
    fprintf('★★★ F 沿整个路径 [0,1] 单调下降 → 整条路径在凸区域内 ★★★\n');
    fprintf('→ 可以在路径上任意点验证梯度方向\n');
    fprintf('→ 真值方向 = p_true - p_current（梯度应与此同向）\n');
else
    % 找第一个非单调点
    first_up = find(dF > 0, 1);
    fprintf('F 在 t=%.2f 处开始上升 → 凸区域可能在 t ∈ [0, %.2f)\n', ...
        t_values(first_up), t_values(first_up));
    fprintf('凸区域边界: t ≈ %.2f\n', t_values(first_up));
end

% 推荐验证点
fprintf('\n--- 推荐验证点 ---\n');
% 选 t=0.5（路径中点）作为验证点
t_verify = 0.5;
p_verify = p_init + t_verify * dp;
fprintf('验证点 t=%.1f: eps_r=%.2f, hole=[%.4f,%.4f,%.4f]\n', ...
    t_verify, p_verify(1), p_verify(2:4));
fprintf('真值方向: [%.2f, %.4f, %.4f, %.4f]\n', dp);
fprintf('在此点，正确梯度应与 dp 同向（g·dp > 0）\n');

% 保存结果
save('data/results/convex_region_scan.mat', 't_values', 'F_values', 'p_init', 'p_true');
fprintf('\n[结果已保存] data/results/convex_region_scan.mat\n');
fprintf('============================\n\n');

end
