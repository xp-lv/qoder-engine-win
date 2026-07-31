function state = run_inversion_tv(max_iter, mu_init, alpha_tv)
%RUN_INVERSION_TV 带 TV 正则化的反演（自适应 lambda）
%
%   每轮 lambda_tv_adaptive = alpha_tv * ||g_data|| / ||g_tv||
%   alpha_tv=0 表示无 TV；alpha_tv=0.1 表示 TV 力度为数据梯度的 10%
%
%   用法：
%     >> run_inversion_tv(15, 1.0, 0)     % 无 TV
%     >> run_inversion_tv(15, 1.0, 0.1)   % 自适应 TV，相对强度 10%

if nargin < 1, max_iter = 15; end
if nargin < 2, mu_init = 1.0; end
if nargin < 3, alpha_tv = 0.1; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  TV 自适应正则化 (alpha_tv=%.4f)\n', alpha_tv);
fprintf('#  初值: eps_r=3.0, 真值: eps_r=5.0\n');
fprintf('#  max_iter=%d, mu_init=%.2f\n', max_iter, mu_init);
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[INV] [FAIL] mphstart\n'); return;
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
fprintf('[INV] N_inner = %d\n', N_inner);

%% 1b. 预计算 TV 邻居列表（基于空间距离）
fprintf('[INV] 构建 TV 邻居列表...\n');
inner_pos = voxel.pos(inner_idx, :);  % [N_inner x 3]
neighbor_list = cell(N_inner, 1);
n_neighbors_avg = 0;
for vi = 1:N_inner
    % 找距离最近的 8 个体素作为邻居
    dists = vecnorm(inner_pos - inner_pos(vi,:), 2, 2);
    dists(vi) = inf;  % 排除自己
    [~, sort_idx] = sort(dists);
    neighbor_list{vi} = sort_idx(1:min(8, N_inner))';  % 最多8个邻居
    n_neighbors_avg = n_neighbors_avg + length(neighbor_list{vi});
end
fprintf('[INV] TV 邻居: 平均 %.1f 个/体素\n', n_neighbors_avg / N_inner);

%% 2. 预计算 J_obs
fprintf('[INV] 预计算 J_obs (eps_r=5)...\n');
voxel.epsilon_r(inner) = p.eps_r_true;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp; dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end

%% 3. 设初值
voxel.epsilon_r(inner) = p.eps_r_init;

%% 4. 迭代循环
k0_sq = p.k0^2; dV_vec = voxel.dV; mu = mu_init; eps_tol = 0.05;
history_F = zeros(max_iter,1); history_mean = zeros(max_iter,1);
history_std = zeros(max_iter,1); history_tv = zeros(max_iter,1);
history_eps = cell(max_iter,1); history_pos = [];
converged = false; final_iter = 0;

for iter = 1:max_iter
    fprintf('\n[INV] ===== 迭代 %d/%d =====\n', iter, max_iter);
    
    %% 正演
    update_epsilon(model, voxel, p);
    [E_total,~,E_gauss] = solve_forward(model, voxel, p);
    
    %% 残差
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, p);
    Delta_J = J_obs - lc.J_obs_perp;
    F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
    
    %% TV 正则项
    eps_now = voxel.epsilon_r(inner);
    tv_val = 0;
    for vi = 1:N_inner
        nb = neighbor_list{vi};
        tv_val = tv_val + sum(abs(eps_now(vi) - eps_now(nb)));
    end
    tv_val = tv_val / 2;  % 每对计两次
    F_total = F_data + alpha_tv * tv_val;  % 显示用，实际梯度在下面自适应
    
    history_F(iter) = F_data;  % 只记录数据项 F 用于收敛判断
    history_mean(iter) = mean(eps_now);
    history_std(iter) = std(eps_now);
    history_tv(iter) = tv_val;
    history_eps{iter} = eps_now;
    if iter == 1, history_pos = voxel.pos(inner_idx, :); end
    
    fprintf('[INV] F_data=%.6e, F_total=%.6e, TV=%.2e\n', F_data, F_total, tv_val);
    fprintf('[INV] eps mean=%.4f, std=%.4f, range=[%.2f, %.2f]\n', ...
        mean(eps_now), std(eps_now), min(eps_now), max(eps_now));
    
    if sqrt(F_data) < eps_tol
        fprintf('[INV] ★★★ 收敛！sqrt(F_data)=%.4f ★★★\n', sqrt(F_data));
        converged = true; final_iter = iter; break;
    end
    
    %% 伴随
    lc.k_vec = p.k0 * lc.k_dir; lc.J_obs_perp = J_obs; lc.Delta_J_perp = Delta_J;
    [Js,Ms,source_pos,~] = build_adjoint_source_fullmaxwell(grid, lc, p);
    [lambda,ok_adj,lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
    if ~ok_adj, fprintf('[INV] [FAIL]\n'); break; end
    
    %% 数据项梯度（伴随法，不变）
    g_data = zeros(N_inner,1);
    use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) && size(E_gauss,1)==size(voxel.gauss_pos,1);
    if use_gauss
        gw = voxel.gauss_w;
        for vi=1:N_inner
            gp=(4*(vi-1)+1):(4*vi); gs=0;
            for gpi=1:4, gs=gs+gw(gpi)*real(sum(E_gauss(gp(gpi),:).*lambda_gauss(gp(gpi),:))); end
            g_data(vi) = -k0_sq*dV_vec(inner_idx(vi))*gs;
        end
    else
        for vi=1:N_inner, g_data(vi)=-k0_sq*dV_vec(inner_idx(vi))*real(sum(E_total(vi,:).*lambda(vi,:))); end
    end
    g_data = g_data / F_obs;
    
    %% TV 正则项梯度（解析，不依赖伴随）
    g_tv = zeros(N_inner,1);
    for vi = 1:N_inner
        nb = neighbor_list{vi};
        diffs = eps_now(vi) - eps_now(nb);
        g_tv(vi) = sum(diffs ./ (abs(diffs) + 1e-30));  % sign(d) 平滑化
    end
    g_tv = g_tv / 2;  % 每对计两次
    
    %% 自适应 lambda_tv：使 TV 梯度与数据梯度量级匹配
    norm_g_data = norm(g_data);
    norm_g_tv = norm(g_tv);
    if alpha_tv > 0 && norm_g_tv > 1e-30
        lambda_tv_adaptive = alpha_tv * norm_g_data / norm_g_tv;
    else
        lambda_tv_adaptive = 0;
    end
    
    %% 总梯度 = 数据梯度 + λ_TV_adaptive × TV梯度
    g_total = g_data + lambda_tv_adaptive * g_tv;
    
    fprintf('[INV] ||g_data||=%.4e, ||g_tv||=%.4e, λ_adaptive=%.4e, ||g_total||=%.4e\n', ...
        norm_g_data, norm_g_tv, lambda_tv_adaptive, norm(g_total));
    
    %% 线搜索（用数据项 F_data 判断接受）
    [voxel, mu, accepted, F_new] = linesearch_adj_tv(voxel, g_total, p, model, grid, ...
        J_obs, lc_obs, mu, F_data, inner, inner_idx, N_inner);
    
    if accepted
        fprintf('[INV] 线搜索接受: F_data %.6e -> %.6e\n', F_data, F_new);
    else
        fprintf('[INV] 线搜索拒绝\n');
        if iter >= 3, fprintf('[INV] 连续拒绝，停止\n'); break; end
    end
    final_iter = iter;
end

%% 结果
fprintf('\n############################################################\n');
fprintf('#  TV 正则化反演结果\n');
fprintf('#  迭代: %d, 收敛: %s\n', final_iter, string(converged));
fprintf('#  终值: mean=%.4f, std=%.4f, range=[%.3f, %.3f]\n', ...
    mean(real(voxel.epsilon_r(inner))), std(real(voxel.epsilon_r(inner))), ...
    min(real(voxel.epsilon_r(inner))), max(real(voxel.epsilon_r(inner))));
fprintf('#  alpha_tv=%.4f\n', alpha_tv);
fprintf('############################################################\n');

fprintf('\n残差历史:\n');
for iter = 1:final_iter
    fprintf('  iter %d: F_data=%.4e, eps mean=%.4f, std=%.4f, TV=%.2e\n', ...
        iter, history_F(iter), history_mean(iter), history_std(iter), history_tv(iter));
end

state = struct();
state.converged = converged;
state.iteration = final_iter;
state.history_F = history_F(1:final_iter);
state.history_mean = history_mean(1:final_iter);
state.history_std = history_std(1:final_iter);
state.history_tv = history_tv(1:final_iter);
state.history_eps = history_eps(1:final_iter);
state.pos = history_pos;
state.alpha_tv = alpha_tv;
state.eps_final = voxel.epsilon_r(inner);

save(fullfile(p.dir_result, 'inversion_tv_state.mat'), 'state');
fprintf('\n[INV] 结果已保存\n');

try phys.feature('vec1').set('Je',{'0','0','0'}); catch; end
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try model.param.set('adjoint_mode','1'); catch; end

end

%% ====== TV 版线搜索 ======
function [voxel, mu_next, accepted, F_data_new] = linesearch_adj_tv(voxel, g, p, model, grid, ...
    J_obs, lc_obs, mu_init, F_old, inner, inner_idx, N_inner)
    
inner2 = inner; inner_idx2 = inner_idx;
eps_old_inner = voxel.epsilon_r(inner);
mu = mu_init;
g_rms = sqrt(mean(g.^2));
if g_rms > 0, g_normed = g / g_rms; else, g_normed = g; end
g_norm_sq = sum(g.^2);

dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end

accepted = false; F_data_new = F_old;
c_armijo = 0.01; ls_decay = 0.5; ls_max_trials = 8;

fprintf('  [LS] F_old=%.6e ||g||²=%.4e mu=%.4f\n', F_old, g_norm_sq, mu);

for trial = 1:ls_max_trials
    eps_try = eps_old_inner - mu * g_normed;
    eps_try = max(1.0, min(50.0, eps_try));
    
    eps_full = voxel.epsilon_r;
    eps_full(inner) = eps_try;
    voxel_try = voxel; voxel_try.epsilon_r = eps_full;
    
    update_epsilon(model, voxel_try, p);
    try model.physics('emw').prop('BackgroundField').set('Eb',[0 0 1]); catch; end
    try model.param.set('adjoint_mode','1'); catch; end
    try model.physics('emw').feature('vec1').set('Je',{'0','0','0'}); catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    model.sol('sol1').runAll();
    
    sf_try = extract_scattered(model, grid);
    lc_try = lightcone_project(grid, sf_try, p);
    F_data_new = sum(dOmega .* sum(abs(J_obs - lc_try.J_obs_perp).^2,2)) / F_obs;
    
    armijo_rhs = F_old - c_armijo * mu * g_norm_sq;
    fprintf('  [LS t%d] mu=%.6f F_try=%.6e armijo=%.6e', trial, mu, F_data_new, armijo_rhs);
    
    if F_data_new <= armijo_rhs
        fprintf(' ACCEPT\n');
        voxel.epsilon_r(inner) = eps_try;
        accepted = true; break;
    else
        fprintf(' reject\n');
        mu = mu * ls_decay;
    end
end

if ~accepted
    F_data_new = F_old; mu_next = mu_init * 0.5;
else
    mu_next = min(mu * 1.5, 5.0);
end
end
