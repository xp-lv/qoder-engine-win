function result = run_inversion_iter(max_iter, mu_init)
%RUN_INVERSION_ITER 伴随梯度下降反演迭代（非均匀初值 → 真值 eps_r=5）
%
%   从非均匀梯度初值 ε_r(r)=3+1.5x/R 出发，逐轮：
%     1. 正演 → 残差 ΔJ
%     2. 伴随求解 → λ
%     3. 逐体素梯度 g(v) = -k0²·ΔV·Re[conj(λ)·E]
%     4. 归一化步长：ε_r_new = ε_r_old - μ·g/||g||
%     5. 监控：残差 F、mean(ε_r)、std(ε_r)
%
%   用法：
%     >> run_inversion_iter(10, 0.5)  % 10 轮，步长 0.5

if nargin < 1, max_iter = 10; end
if nargin < 2, mu_init = 0.5; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  伴随梯度下降反演迭代\n');
fprintf('#  初值：非均匀梯度 ε_r(r)=3+1.5x/R\n');
fprintf('#  真值：均匀 ε_r=5.0\n');
fprintf('#  max_iter=%d, μ=%g\n', max_iter, mu_init);
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid = build_measurement_grid(p);

fprintf('[INV] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[INV] [FAIL] mphstart: %s\n', ME.message); return;
    end
end

% 清理旧模型
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

fprintf('[INV] 加载 2layer.mph...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end

%% 2. 提取网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('[INV] N_inner = %d\n', N_inner);

%% 3. 预计算 J_obs（真值 eps_r=5）
fprintf('[INV] 预计算 J_obs (eps_r=5.0)...\n');
voxel.epsilon_r(inner) = p.eps_r_true;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min, F_obs = 1.0; end

%% 4. 设置非均匀梯度初值
inner_pos = voxel.pos(inner_idx, :);
eps_init = p.eps_r_init + 1.5 * inner_pos(:,1) / p.R_inner;
voxel.epsilon_r(inner) = eps_init;
fprintf('[INV] 初值: eps_r range [%.3f, %.3f], mean=%.3f\n', ...
    min(eps_init), max(eps_init), mean(eps_init));

%% 5. 迭代循环
k0_sq = p.k0^2;
dV_vec = voxel.dV;
mu = mu_init;

history_F = zeros(max_iter, 1);
history_mean = zeros(max_iter, 1);
history_std = zeros(max_iter, 1);

for iter = 1:max_iter
    fprintf('\n[INV] ===== 迭代 %d/%d =====\n', iter, max_iter);
    
    % 正演
    update_epsilon(model, voxel, p);
    [E_total, ~, E_gauss] = solve_forward(model, voxel, p);
    
    % 残差
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, p);
    Delta_J = J_obs - lc.J_obs_perp;
    F = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs;
    
    % 记录
    eps_now = voxel.epsilon_r(inner);
    history_F(iter) = F;
    history_mean(iter) = mean(eps_now);
    history_std(iter) = std(eps_now);
    
    fprintf('[INV] F=%.6e, eps mean=%.4f, std=%.4f, range=[%.3f, %.3f]\n', ...
        F, mean(eps_now), std(eps_now), min(eps_now), max(eps_now));
    
    % 收敛检查
    if F < 0.01
        fprintf('[INV] ★ F < 0.01，收敛！★\n');
        break;
    end
    
    % 伴随源
    lc.k_vec = p.k0 * lc.k_dir;
    lc.J_obs_perp = J_obs;
    lc.Delta_J_perp = Delta_J;
    [Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);
    
    % 伴随求解
    [lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
    if ~ok_adj
        fprintf('[INV] [FAIL] 伴随求解失败\n'); break;
    end
    
    % 逐体素梯度
    g_voxel = zeros(N_inner, 1);
    use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
        && size(E_gauss,1) == size(voxel.gauss_pos,1);
    
    if use_gauss
        gw = voxel.gauss_w;
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gw(gpi) * real(sum(E_gauss(gp(gpi),:) .* lambda_gauss(gp(gpi),:)));
            end
            g_voxel(vi) = -k0_sq * dV_vec(inner_idx(vi)) * gs;
        end
    else
        for vi = 1:N_inner
            g_voxel(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(sum(E_total(vi,:) .* lambda(vi,:)));
        end
    end
    g_voxel = g_voxel / F_obs;
    
    % 归一化梯度方向 + 自适应步长
    g_norm = norm(g_voxel);
    if g_norm < 1e-30
        fprintf('[INV] 梯度范数过小，停止\n'); break;
    end
    
    % 步长：归一化方向 × μ（使每轮 eps_r 变化幅度可控）
    d_eps = mu * g_voxel / g_norm;
    
    % 物理约束：ε_r ∈ [1.0, 50.0]
    eps_new = eps_now - d_eps;  % 梯度下降：减小代价函数
    eps_new(eps_new < 1.0) = 1.0;
    eps_new(eps_new > 50.0) = 50.0;
    
    voxel.epsilon_r(inner) = eps_new;
    
    fprintf('[INV] ||g||=%.4e, ||d_eps||=%.4e, max|d_eps|=%.4f\n', ...
        g_norm, norm(d_eps), max(abs(d_eps)));
    
    % 残差上升时减小步长
    if iter > 1 && F > history_F(iter-1)
        mu = mu * 0.5;
        fprintf('[INV] ⚠ 残差上升，步长 μ→%g\n', mu);
    end
end

%% 6. 最终结果
fprintf('\n############################################################\n');
fprintf('#  反演结果\n');
fprintf('############################################################\n');
fprintf('#  真值: eps_r = %.1f（均匀）\n', p.eps_r_true);
fprintf('#  初值: mean=%.3f, std=%.3f\n', mean(eps_init), std(eps_init));
fprintf('#  终值: mean=%.4f, std=%.4f\n', mean(eps_now), std(eps_now));
fprintf('#  eps_r range: [%.3f, %.3f]\n', min(eps_now), max(eps_now));
fprintf('#  最终残差: F=%.6e\n', F);
fprintf('############################################################\n');

% 残差历史
fprintf('\n残差历史:\n');
for iter = 1:length(history_F)
    if history_F(iter) > 0
        fprintf('  iter %d: F=%.6e, eps mean=%.4f, std=%.4f\n', ...
            iter, history_F(iter), history_mean(iter), history_std(iter));
    end
end

%% 7. 保存
result = struct();
result.max_iter = max_iter;
result.history_F = history_F(1:iter);
result.history_mean = history_mean(1:iter);
result.history_std = history_std(1:iter);
result.eps_final = eps_now;
result.eps_true = p.eps_r_true;
result.eps_init = eps_init;
result.F_final = F;

save(fullfile(p.dir_result, 'inversion_iter_result.mat'), 'result');
fprintf('\n[INV] 结果已保存: data/results/inversion_iter_result.mat\n');

end
