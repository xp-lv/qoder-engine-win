function state = run_inversion(max_iter, mu_init)
%RUN_INVERSION pipline_adjoint 完整反演循环
%
%   正演 → J_hyp → 残差 → 伴随源 → 伴随求解 → 梯度 → Armijo 线搜索 → 收敛
%
%   用法：
%     >> run_inversion(20, 1.0)  % 20 轮，初始步长 1.0

if nargin < 1, max_iter = 20; end
if nargin < 2, mu_init = 1.0; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  pipline_adjoint 完整反演循环\n');
fprintf('#  初值: eps_r=3.0（均匀）, 真值: eps_r=5.0\n');
fprintf('#  max_iter=%d, mu_init=%.2f\n', max_iter, mu_init);
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
fprintf('[INV] F_obs = %.6e\n', F_obs);

%% 4. 设初值
voxel.epsilon_r(inner) = p.eps_r_init;
fprintf('[INV] 初值: eps_r = %.1f（均匀）\n', p.eps_r_init);

%% 5. 反演迭代循环
k0_sq = p.k0^2;
dV_vec = voxel.dV;
mu = mu_init;
eps_tol = 0.05;  % 收敛阈值 sqrt(F) < 0.05

history_F = zeros(max_iter, 1);
history_mean = zeros(max_iter, 1);
history_std = zeros(max_iter, 1);
history_mu = zeros(max_iter, 1);
history_accepted = zeros(max_iter, 1);
history_eps = cell(max_iter, 1);   % 每轮 eps 分布
history_grad = cell(max_iter, 1);  % 每轮梯度分布
history_pos = [];                  % 体素坐标（第一轮保存）

converged = false;
final_iter = 0;

for iter = 1:max_iter
    fprintf('\n[INV] ===== 迭代 %d/%d =====\n', iter, max_iter);
    
    %% 5a. 正演
    update_epsilon(model, voxel, p);
    [E_total, ~, E_gauss] = solve_forward(model, voxel, p);
    
    %% 5b. 残差 + 代价函数
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, p);
    Delta_J = J_obs - lc.J_obs_perp;
    F = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs;
    residual = sqrt(F);
    
    eps_now = voxel.epsilon_r(inner);
    history_F(iter) = F;
    history_mean(iter) = mean(eps_now);
    history_std(iter) = std(eps_now);
    history_mu(iter) = mu;
    history_eps{iter} = eps_now;  % 保存本轮 eps
    if iter == 1, history_pos = voxel.pos(inner_idx, :); end  % 保存坐标
    
    fprintf('[INV] F=%.6e, sqrt(F)=%.4f, eps mean=%.4f, std=%.4f\n', ...
        F, residual, mean(eps_now), std(eps_now));
    
    %% 5c. 收敛检查
    if residual < eps_tol
        fprintf('[INV] ★★★ 收敛！sqrt(F)=%.4f < %.2f ★★★\n', residual, eps_tol);
        converged = true;
        final_iter = iter;
        break;
    end
    
    %% 5d. 伴随源
    lc.k_vec = p.k0 * lc.k_dir;
    lc.J_obs_perp = J_obs;
    lc.Delta_J_perp = Delta_J;
    [Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);
    
    %% 5e. 伴随求解
    [lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
    if ~ok_adj
        fprintf('[INV] [FAIL] 伴随求解失败，停止\n');
        break;
    end
    
    %% 5f. 逐体素梯度
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
    history_grad{iter} = g_voxel;  % 保存本轮梯度
    
    %% 5g. 线搜索
    fprintf('[INV] 线搜索 (mu=%.4f)...\n', mu);
    [voxel, mu, accepted, F_new] = linesearch_adj(voxel, g_voxel, p, model, grid, J_obs, lc_obs, mu, F);
    history_accepted(iter) = accepted;
    
    if ~accepted
        fprintf('[INV] ⚠ 线搜索全部拒绝\n');
        % 连续 3 轮拒绝则停止
        if iter >= 3 && ~history_accepted(iter-1) && ~history_accepted(iter-2)
            fprintf('[INV] 连续 3 轮拒绝，停止\n');
            break;
        end
    else
        fprintf('[INV] 线搜索接受: F %.6e → %.6e\n', F, F_new);
    end
    
    final_iter = iter;
end

%% 6. 最终正演（获取终态的精确 F）
update_epsilon(model, voxel, p);
solve_forward(model, voxel, p);
sf_final = extract_scattered(model, grid);
lc_final = lightcone_project(grid, sf_final, p);
Delta_J_final = J_obs - lc_final.J_obs_perp;
F_final = sum(dOmega .* sum(abs(Delta_J_final).^2, 2)) / F_obs;
residual_final = sqrt(F_final);

%% 7. 输出结果
fprintf('\n############################################################\n');
fprintf('#  反演结果\n');
fprintf('############################################################\n');
fprintf('#  迭代轮数: %d\n', final_iter);
fprintf('#  收敛: %s\n', string(converged));
fprintf('#  真值: eps_r = %.1f\n', p.eps_r_true);
fprintf('#  初值: eps_r = %.1f\n', p.eps_r_init);
fprintf('#  终值: mean=%.4f, std=%.4f, range=[%.3f, %.3f]\n', ...
    mean(real(voxel.epsilon_r(inner))), std(real(voxel.epsilon_r(inner))), ...
    min(real(voxel.epsilon_r(inner))), max(real(voxel.epsilon_r(inner))));
fprintf('#  最终残差: F=%.6e, sqrt(F)=%.4f\n', F_final, residual_final);
fprintf('############################################################\n');

%% 8. 残差历史
fprintf('\n残差历史:\n');
fprintf('  iter |    F      | sqrt(F) | eps mean | eps std |  mu   | accept\n');
fprintf('  -----+-----------+---------+----------+---------+-------+-------\n');
for iter = 1:final_iter
    fprintf('  %3d  | %.4e |  %.4f |  %.4f  |  %.4f  | %.3f |   %d\n', ...
        iter, history_F(iter), sqrt(history_F(iter)), ...
        history_mean(iter), history_std(iter), ...
        history_mu(iter), history_accepted(iter));
end

%% 9. 保存状态
state = struct();
state.converged = converged;
state.iteration = final_iter;
state.residual = residual_final;
state.F_final = F_final;
state.history_F = history_F(1:final_iter);
state.history_mean = history_mean(1:final_iter);
state.history_std = history_std(1:final_iter);
state.history_mu = history_mu(1:final_iter);
state.history_accepted = history_accepted(1:final_iter);
state.history_eps = history_eps(1:final_iter);
state.history_grad = history_grad(1:final_iter);
state.pos = history_pos;
state.eps_final = voxel.epsilon_r(inner);
state.eps_true = p.eps_r_true;
state.eps_init = p.eps_r_init;

save(fullfile(p.dir_result, 'inversion_state.mat'), 'state');
fprintf('\n[INV] 结果已保存: data/results/inversion_state.mat\n');

% 恢复模型
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model.param.set('adjoint_mode', '1'); catch, end

end
