function result = run_inversion_v3(max_iter, mu_init)
%RUN_INVERSION_V3 管线3 复数均匀球反演（mphmatrix + MATLAB backslash 伴随求解）
%
%   核心差异 vs 管线2 run_inversion_complex.m:
%     1. 伴随求解用 solve_adjoint_matlab（mphmatrix + MATLAB backslash）
%     2. K 矩阵 LU 分解缓存，后续迭代仅 O(n) 回带
%     3. 正演仍用 COMSOL runAll（但伴随不再调用 runAll）
%
%   用法：
%     >> run_inversion_v3()          % 默认 15 轮
%     >> run_inversion_v3(20, 0.5)   % 20 轮，初始步长 0.5

if nargin < 1 || isempty(max_iter), max_iter = 15; end
if nargin < 2 || isempty(mu_init), mu_init = 0.5; end

%% 0. 路径初始化
this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
pipline2_dir = fullfile(fileparts(pipline3_dir), 'pipline_adjoint');

cd(pipline3_dir);
addpath('config', 'core_adjoint', 'experiment');
addpath(fullfile(pipline2_dir, 'utils'));
addpath(fullfile(pipeline2_dir, 'core_forward'));
addpath(fullfile(pipeline2_dir, 'core_jhyp'));
addpath(fullfile(pipeline2_dir, 'core_jobs'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

%% 1. 初始化
p = config();
grid = build_measurement_grid(p);

eps_true_re = p.eps_r_true_re;
eps_true_im = p.eps_r_true_im;
eps_init_re = p.eps_r_init_re;
eps_init_im = p.eps_r_init_im;
prior_re = p.eps_r_prior_re;
prior_im = p.eps_r_prior_im;
lambda_prior_re = p.lambda_prior_re;
lambda_prior_im = p.lambda_prior_im;
damping_init = p.damping_init;
damping_recover = p.damping_recover;
max_halvings = p.max_halvings;

fprintf('\n############################################################\n');
fprintf('#  管线3: 复数均匀球反演 (mphmatrix + MATLAB backslash)\n');
fprintf('#  真值: eps_r = %.1f %+.1fj\n', eps_true_re, eps_true_im);
fprintf('#  初值: eps_r = %.1f %+.1fj\n', eps_init_re, eps_init_im);
fprintf('#  max_iter=%d, mu_init=%g\n', max_iter, mu_init);
fprintf('############################################################\n\n');

%% 2. COMSOL 初始化
fprintf('[V3] 连接 COMSOL Server (port %d)...\n', p.comsol_port);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        try mphstop(p.comsol_port); pause(2); mphstart(p.comsol_port); catch, end
    end
end
try; tags = ModelUtil.tags(); for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

fprintf('[V3] 加载模型: %s\n', p.comsol_model_path);
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end

phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0', '0', '0'});
    try phys.feature('vec1').selection().all(); catch; end
end
try model.param.set('adjoint_mode', '1'); catch; end

%% 3. 提取网格
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('[V3] N_inner = %d 体素\n', N_inner);

%% 4. 预计算 J_obs
fprintf('[V3] 预计算 J_obs (eps_r = 20-5j)...\n');
voxel.epsilon_r(~inner) = 1.0;
voxel.epsilon_r(inner) = eps_true_re + 1j * eps_true_im;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs_norm = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs_norm < p.F_obs_min, F_obs_norm = 1.0; end
fprintf('[V3] F_obs_norm = %.6e\n', F_obs_norm);

%% 5. 设置初始猜测
eps_re = eps_init_re;
eps_im = eps_init_im;
fprintf('[V3] 初始猜测: eps_r = %.2f %+.2fj\n', eps_re, eps_im);

%% 6. 迭代循环
k0_sq = p.k0^2;
dV_vec = voxel.dV;

history_F      = zeros(max_iter, 1);
history_eps_re = zeros(max_iter, 1);
history_eps_im = zeros(max_iter, 1);
history_g_re   = zeros(max_iter, 1);
history_g_im   = zeros(max_iter, 1);
adj_solve_time = zeros(max_iter, 1);  % 伴随求解耗时（管线3核心指标）

damping = damping_init;
converged = false;
F_final = 0;
K_cache = [];  % ★ LU 分解缓存（跨迭代复用）

for iter = 1:max_iter
    fprintf('\n[V3] ===== 迭代 %d/%d =====\n', iter, max_iter);

    % --- 正演（COMSOL runAll）---
    voxel.epsilon_r(inner) = eps_re + 1j * eps_im;
    update_epsilon(model, voxel, p);
    [E_total, ~, E_gauss] = solve_forward(model, voxel, p);

    % 残差 + 代价
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, p);
    Delta_J = J_obs - lc.J_obs_perp;
    F_data = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs_norm;

    F_tikh = lambda_prior_re * (eps_re - prior_re)^2 ...
           + lambda_prior_im * (eps_im - prior_im)^2;
    F_total = F_data + F_tikh;
    F_final = F_data;

    history_F(iter)      = sqrt(F_data);
    history_eps_re(iter) = eps_re;
    history_eps_im(iter) = eps_im;

    fprintf('[V3] sqrt(F_data)=%.6e, eps_re=%.4f, eps_im=%.4f\n', ...
        sqrt(F_data), eps_re, eps_im);

    if sqrt(F_data) < p.eps_tol_complex
        fprintf('[V3] *** 收敛! ***\n');
        converged = true;
        break;
    end

    % --- 伴随源构建 ---
    lc.k_vec = p.k0 * lc.k_dir;
    lc.J_obs_perp = J_obs;
    lc.Delta_J_perp = Delta_J;
    [Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);

    % --- ★ 管线3核心：MATLAB backslash 伴随求解 ---
    t_adj_start = tic;
    [lambda, ok_adj, lambda_gauss, K_cache] = solve_adjoint_matlab( ...
        model, voxel, p, Js, source_pos, Ms, K_cache);
    adj_solve_time(iter) = toc(t_adj_start);

    if ~ok_adj
        fprintf('[V3] [FAIL] 伴随求解失败 (iter %d)\n', iter);
        break;
    end

    % --- 复数梯度 ---
    g_complex = zeros(N_inner, 1);
    use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
        && size(E_gauss,1) == size(voxel.gauss_pos,1);

    if use_gauss
        gw = voxel.gauss_w;
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gw(gpi) * sum(E_gauss(gp(gpi),:) .* lambda_gauss(gp(gpi),:));
            end
            g_complex(vi) = -k0_sq * dV_vec(inner_idx(vi)) * gs;
        end
    else
        for vi = 1:N_inner
            g_complex(vi) = -k0_sq * dV_vec(inner_idx(vi)) ...
                * sum(E_total(vi,:) .* lambda(vi,:));
        end
    end
    g_complex = g_complex / F_obs_norm;
    g_total = sum(g_complex);

    % Wirtinger 分离
    g_data_re = 2 * real(g_total);
    g_data_im = -2 * imag(g_total);

    history_g_re(iter) = g_data_re;
    history_g_im(iter) = g_data_im;

    fprintf('[V3] g_data: re=%+.4e, im=%+.4e\n', g_data_re, g_data_im);
    fprintf('[V3] 伴随求解耗时: %.3fs (iter %d, cache=%s)\n', ...
        adj_solve_time(iter), iter, ternary_s(isa(K_cache,'decomposition'),'LU缓存','无缓存'));

    % --- Tikhonov 梯度 ---
    g_tikh_re = 2 * lambda_prior_re * (eps_re - prior_re);
    g_tikh_im = 2 * lambda_prior_im * (eps_im - prior_im);
    g_total_re = g_data_re + g_tikh_re;
    g_total_im = g_data_im + g_tikh_im;

    % --- 步长 + backtracking ---
    eps_re_old = eps_re; eps_im_old = eps_im;
    F_old = F_total;
    alpha_re = mu_init * damping / max(abs(g_total_re), 1e-30);
    alpha_im = mu_init * damping / max(abs(g_total_im), 1e-30);
    accepted = false;
    eps_re_try = eps_re_old; eps_im_try = eps_im_old;

    for halving = 0:max_halvings
        eps_re_try = eps_re_old - alpha_re * g_total_re;
        eps_im_try = eps_im_old - alpha_im * g_total_im;
        eps_re_try = max(1.0, min(50.0, eps_re_try));
        eps_im_try = max(-20.0, min(0.0, eps_im_try));

        voxel.epsilon_r(inner) = eps_re_try + 1j * eps_im_try;
        update_epsilon(model, voxel, p);
        try
            model.sol('sol1').clearSolutionData();
            model.sol('sol1').clearSolution();
            model.sol('sol1').runAll();
        catch
            alpha_re = alpha_re * 0.5; alpha_im = alpha_im * 0.5;
            continue;
        end

        sf_try = extract_scattered(model, grid);
        lc_try = lightcone_project(grid, sf_try, p);
        dJ_try = J_obs - lc_try.J_obs_perp;
        F_try_data = sum(dOmega .* sum(abs(dJ_try).^2, 2)) / F_obs_norm;
        F_try_tikh = lambda_prior_re * (eps_re_try - prior_re)^2 ...
                   + lambda_prior_im * (eps_im_try - prior_im)^2;
        F_try = F_try_data + F_try_tikh;

        if F_try < F_old
            accepted = true;
            F_final = F_try_data;
            fprintf('[V3] OK 步长接受 (halving=%d): eps_re=%.4f, eps_im=%.4f, sqrt(F)=%.6e\n', ...
                halving, eps_re_try, eps_im_try, sqrt(F_try_data));
            break;
        else
            alpha_re = alpha_re * 0.5; alpha_im = alpha_im * 0.5;
        end
    end

    eps_re = eps_re_try; eps_im = eps_im_try;
    damping = min(1.0, damping * damping_recover);
end

%% 7. 结果报告
history_F      = history_F(1:iter);
history_eps_re = history_eps_re(1:iter);
history_eps_im = history_eps_im(1:iter);

eps_re_recovery = (eps_re / eps_true_re) * 100;
eps_im_recovery = (eps_im / eps_true_im) * 100;

fprintf('\n############################################################\n');
fprintf('#  管线3 反演结果\n');
fprintf('############################################################\n');
fprintf('#  真值: eps_r = %.1f %+.1fj\n', eps_true_re, eps_true_im);
fprintf('#  终值: eps_r = %.4f %+.4fj\n', eps_re, eps_im);
fprintf('#  迭代: %d/%d\n', iter, max_iter);
fprintf('#  收敛: %s\n', string(converged));
fprintf('#  最终 sqrt(F): %.6e\n', sqrt(F_final));
fprintf('#  eps_re 恢复率: %.1f%%\n', eps_re_recovery);
fprintf('#  eps_im 恢复率: %.1f%%\n', eps_im_recovery);
fprintf('#  伴随求解平均耗时: %.3fs\n', mean(adj_solve_time(adj_solve_time>0)));
fprintf('############################################################\n');

%% 8. 保存结果
result = struct();
result.pipeline = 'pipline3';
result.method = 'mphmatrix + MATLAB backslash';
result.converged = converged;
result.iteration = iter;
result.residual = sqrt(F_final);
result.eps_re_final = eps_re;
result.eps_im_final = eps_im;
result.eps_re_recovery = eps_re_recovery;
result.eps_im_recovery = eps_im_recovery;
result.history_F = history_F;
result.history_eps_re = history_eps_re;
result.history_eps_im = history_eps_im;
result.adj_solve_time = adj_solve_time(1:iter);

save(fullfile(p.dir_result, 'inversion_v3_result.mat'), 'result');
fprintf('\n[V3] 结果已保存: %s\n', fullfile(p.dir_result, 'inversion_v3_result.mat'));

end

function s = ternary_s(cond, a, b)
    if cond, s = a; else, s = b; end
end
