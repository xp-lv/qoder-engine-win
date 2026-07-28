function diagnose_voxel_fd()
%DIAGNOSE_VOXEL_FD 步骤2：体素级 FD 灵敏度验证
%
%   对选定的代表性体素，用 3 个步长计算 ∂F/∂ε_v
%   验证 FD 收敛性和符号一致性
%
%   选体素策略：
%     - 5 个体内体素（远离空洞边界，d > 0.05m）
%     - 5 个边界体素（靠近空洞边界，0.005 < d < 0.02m）
%     - 5 个中间体素（0.02 < d < 0.05m）

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  步骤2: 体素级 FD 灵敏度验证\n');
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

eps_r_test = 4.0; hole_pos_test = [0.015; 0.010; 0.005];
delta_sdf = 0.008;
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);
inner_idx = find(inner_mask);
N_inner = sum(inner_mask);

%% 预计算 J_obs
fprintf('[V2] 预计算 J_obs...\n');
voxel_truth = voxel;
d_true = sqrt(sum((inner_pos - [0.03;0.02;0.01]').^2, 2));
voxel_truth.epsilon_r(inner_mask) = 5.0 + (1.0-5.0)*0.5*(1-tanh(d_true/delta_sdf));
update_epsilon(model, voxel_truth, p);
pf0 = p; pf0.freq=1e9; pf0.omega=2*pi*pf0.freq; pf0.k0=pf0.omega/p.c; pf0.lambda=p.c/pf0.freq;
model.param.set('freq', num2str(pf0.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', pf0.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
sf = extract_scattered(model, grid);
J_obs = lightcone_project(grid, sf, pf0).J_obs_perp;

%% 选体素
d_vox = sqrt(sum((inner_pos - hole_pos_test').^2, 2));

% 体内体素（d > 0.05）
body_candidates = find(d_vox > 0.05);
% 边界体素（0.005 < d < 0.02）
boundary_candidates = find(d_vox > 0.005 & d_vox < 0.02);
% 中间体素（0.02 < d < 0.05）
mid_candidates = find(d_vox > 0.02 & d_vox < 0.05);

% 从每个类别选 5 个（均匀间隔）
pick = @(c, n) c(round(linspace(1, length(c), min(n, length(c)))));

sel_body = pick(body_candidates, 5);
sel_boundary = pick(boundary_candidates, 5);
sel_mid = pick(mid_candidates, 5);

sel_all = unique([sel_body; sel_mid; sel_boundary]);
N_sel = length(sel_all);

fprintf('[V2] 选中 %d 个体素（体内=%d, 中间=%d, 边界=%d）\n', ...
    N_sel, length(sel_body), length(sel_mid), length(sel_boundary));

%% 设测试点 epsilon 分布
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));

%% 体素级 FD（3 个步长）
deltas = [0.01, 0.001, 0.0001];
N_delta = length(deltas);
g_FD_voxel = zeros(N_sel, N_delta);

fprintf('\n[V2] 计算体素级 FD（%d 体素 x %d 步长 = %d 次 COMSOL 正演）...\n', ...
    N_sel, N_delta*2, N_sel*N_delta*2);

for vi = 1:N_sel
    v_inner = sel_all(vi);  % inner 索引
    v_global = inner_idx(v_inner);  % 全局体素索引

    for di = 1:N_delta
        delta_eps = deltas(di);
        eps_orig = voxel.epsilon_r(v_global);

        % ε_v + delta
        voxel.epsilon_r(v_global) = eps_orig + delta_eps;
        try
            F_plus = compute_F_voxel(model, voxel, grid, p, pf0, inner_mask, J_obs);
        catch
            fprintf('[V2]   体素 %d δ=%.0e: F_plus 求解失败，跳过\n', v_inner, delta_eps);
            voxel.epsilon_r(v_global) = eps_orig;
            g_FD_voxel(vi, di) = NaN;
            continue;
        end

        % ε_v - delta
        voxel.epsilon_r(v_global) = eps_orig - delta_eps;
        try
            F_minus = compute_F_voxel(model, voxel, grid, p, pf0, inner_mask, J_obs);
        catch
            fprintf('[V2]   体素 %d δ=%.0e: F_minus 求解失败，跳过\n', v_inner, delta_eps);
            voxel.epsilon_r(v_global) = eps_orig;
            g_FD_voxel(vi, di) = NaN;
            continue;
        end

        % 恢复
        voxel.epsilon_r(v_global) = eps_orig;

        g_FD_voxel(vi, di) = (F_plus - F_minus) / (2 * delta_eps);
    end

    % 输出
    pos_v = inner_pos(v_inner, :);
    d_v = d_vox(v_inner);
    cat_str = 'mid';
    if d_v > 0.05, cat_str = 'body'; elseif d_v < 0.02, cat_str = 'bnd'; end
    fprintf('[V2] 体素 %2d (%s, d=%.3f): ', v_inner, cat_str, d_v);
    for di = 1:N_delta
        fprintf('d=%.0e:%+.4e  ', deltas(di), g_FD_voxel(vi, di));
    end
    % 符号一致性
    signs = sign(g_FD_voxel(vi, :));
    if all(signs > 0)
        fprintf('sign=+ ✓\n');
    elseif all(signs < 0)
        fprintf('sign=- ✓\n');
    else
        fprintf('sign MIXED ✗\n');
    end
end

%% 收敛性分析
fprintf('\n############################################################\n');
fprintf('#  步骤2 结果\n');
fprintf('############################################################\n');
fprintf('#  体素    类别    d(m)      δ=0.1           δ=0.01          δ=0.001         sign   收敛\n');

n_converged = 0;
n_sign_ok = 0;
for vi = 1:N_sel
    v_inner = sel_all(vi);
    pos_v = inner_pos(v_inner, :);
    d_v = d_vox(v_inner);
    cat_str = 'mid';
    if d_v > 0.05, cat_str = 'body'; elseif d_v < 0.02, cat_str = 'bnd'; end

    signs = sign(g_FD_voxel(vi, :));
    sign_str = 'MIXED';
    if all(signs > 0), sign_str = '+ all'; n_sign_ok = n_sign_ok + 1;
    elseif all(signs < 0), sign_str = '- all'; n_sign_ok = n_sign_ok + 1;
    end

    % 收敛性：最小两个步长的相对变化
    if abs(g_FD_voxel(vi, 2)) > 1e-30
        rel_change = abs((g_FD_voxel(vi, 3) - g_FD_voxel(vi, 2)) / g_FD_voxel(vi, 2));
        conv_str = sprintf('%.1f%%', rel_change*100);
        if rel_change < 0.03, n_converged = n_converged + 1; conv_str = [conv_str, ' ✓']; end
    else
        conv_str = 'N/A';
    end

    fprintf('#  %2d      %-4s    %.4f    %+.4e   %+.4e   %+.4e   %-6s  %s\n', ...
        v_inner, cat_str, d_v, g_FD_voxel(vi,1), g_FD_voxel(vi,2), g_FD_voxel(vi,3), sign_str, conv_str);
end

fprintf('#\n#  符号一致: %d/%d\n', n_sign_ok, N_sel);
fprintf('#  收敛 (<3%%): %d/%d\n', n_converged, N_sel);
fprintf('#\n');
if n_sign_ok == N_sel && n_converged >= N_sel * 0.8
    fprintf('#  *** 步骤2 通过：FD 符号一致且收敛 ***\n');
else
    fprintf('#  步骤2 未完全通过\n');
end
fprintf('############################################################\n');

% 保存结果供步骤3使用
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir,'dir'), mkdir(results_dir); end
save(fullfile(results_dir,'voxel_fd_result.mat'), ...
    'sel_all', 'g_FD_voxel', 'deltas', 'inner_pos', 'd_vox', 'inner_idx');
end

function F = compute_F_voxel(model, voxel, grid, p, pf0, inner_mask, J_obs)
    % 更新 epsilon（只改了一个体素，需要 update_epsilon 传播到 COMSOL）
    update_epsilon(model, voxel, p);
    pf = pf0;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    F = mean(sum(abs(dJ).^2, 2)) / 6;  % 非归一化
end
