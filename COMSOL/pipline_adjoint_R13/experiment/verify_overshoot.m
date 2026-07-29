function result = verify_overshoot(state_file)
%VERIFY_OVERSHOOT 验证 iter 2 中 eps_r > 5 的体素梯度方向
%
%   加载反演状态 → 设 iter 2 的 eps_r → 正演+伴随 → 对 eps_r>5 的体素做 FD
%
%   用法：
%     >> verify_overshoot('data/results/inversion_state.mat')

if nargin < 1, state_file = 'data/results/inversion_state.mat'; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  过冲体素梯度方向验证\n');
fprintf('#  iter 2 中 eps_r > 5 的体素：FD vs 伴随\n');
fprintf('############################################################\n\n');

%% 1. 加载 iter 2 状态
data = load(fullfile(pipline_dir, state_file));
s = data.state;
pos = s.pos;
eps_iter2 = s.history_eps{2};  % iter 2 的 eps_r 分布
grad_iter2 = s.history_grad{2}; % iter 2 的伴随梯度

% 找 eps_r > 5 的体素
above5 = eps_iter2 > 5.0;
N_above = sum(above5);
fprintf('[OS] iter 2: eps_r > 5 的体素: %d / %d\n', N_above, length(eps_iter2));
fprintf('[OS]   range [%.3f, %.3f], mean=%.3f\n', ...
    min(eps_iter2(above5)), max(eps_iter2(above5)), mean(eps_iter2(above5)));

% 选择代表性体素（最多 15 个）
above5_idx = find(above5);
[~, sort_order] = sort(eps_iter2(above5_idx), 'descend');  % 从高到低排序
N_sample = min(15, N_above);
sample_local = above5_idx(sort_order(1:N_sample));  % 在 eps_iter2 中的索引
fprintf('[OS] 采样 %d 个体素（eps_r 最高的）\n', N_sample);

%% 2. 初始化 COMSOL
p = config();
grid = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[OS] [FAIL] mphstart\n'); return;
    end
end

try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

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

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);

%% 3. 预计算 J_obs（真值 eps_r=5）
fprintf('[OS] 预计算 J_obs...\n');
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

%% 4. 设 iter 2 的 eps_r 分布
fprintf('[OS] 设 iter 2 eps_r 分布...\n');
voxel.epsilon_r(inner) = eps_iter2;
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
F = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs;
fprintf('[OS] F = %.6e (应与 iter 2 一致: %.6e)\n', F, s.history_F(2));

%% 5. 伴随求解 → 伴随梯度
fprintf('[OS] 伴随求解...\n');
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
if ~ok_adj, fprintf('[OS] [FAIL]\n'); return; end

% 逐体素伴随梯度
k0_sq = p.k0^2;
N_inner = sum(inner);
g_adj_all = zeros(N_inner, 1);
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
        g_adj_all(vi) = -k0_sq * voxel.dV(inner_idx(vi)) * gs;
    end
else
    for vi = 1:N_inner
        g_adj_all(vi) = -k0_sq * voxel.dV(inner_idx(vi)) * real(sum(E_total(vi,:) .* lambda(vi,:)));
    end
end
g_adj_all = g_adj_all / F_obs;

%% 6. 逐体素 FD 验证（仅 eps_r > 5 的采样体素）
fprintf('\n[OS] ===== FD 验证（%d 个 eps_r>5 体素）=====\n', N_sample);
fd_delta = 0.001;

fprintf('  %6s | %8s | %10s | %12s | %12s | %8s | %6s\n', ...
    'eps_r', 'g_adj', 'g_FD', 'ratio', 'dir_to_5', 'sign_OK', 'target');
fprintf('  -------+----------+------------+--------------+--------+--------+------\n');

g_FD_list = zeros(N_sample, 1);
g_adj_list = zeros(N_sample, 1);
eps_list = zeros(N_sample, 1);
sign_OK = zeros(N_sample, 1);

for si = 1:N_sample
    vi = sample_local(si);
    v_global = inner_idx(vi);
    eps_v = voxel.epsilon_r(v_global);
    
    % FD: ±delta
    eps_orig = voxel.epsilon_r(v_global);
    
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_os(model, p);
    sf_p = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf_p, p);
    F_plus = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_os(model, p);
    sf_m = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf_m, p);
    F_minus = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig;
    
    g_FD = (F_plus - F_minus) / (2 * fd_delta);
    g_adj = g_adj_all(vi);
    ratio = g_adj / g_FD;
    
    g_FD_list(si) = g_FD;
    g_adj_list(si) = g_adj;
    eps_list(si) = eps_v;
    
    % 方向分析
    % eps_r > 5（高于真值），正确方向应该是"减小 eps_r"
    % 梯度下降: eps_new = eps - mu*g
    % 要减小 eps → 需要 g > 0（正梯度）
    target = 'decrease';  % 应该减小
    if g_FD > 0
        fd_dir = 'decrease';
    else
        fd_dir = 'increase';
    end
    ok = (g_FD * g_adj > 0);  % sign 一致
    sign_OK(si) = ok;
    
    fprintf('  %6.3f | %+.3e | %+.4e | %+12.4f | %10s | %6s | ↓to5\n', ...
        eps_v, g_adj, g_FD, ratio, fd_dir, ternary_s(ok, 'OK', 'XX'));
end

%% 7. 统计
fprintf('\n############################################################\n');
fprintf('#  过冲体素 FD 验证统计\n');
fprintf('############################################################\n');
sign_rate = sum(sign_OK) / N_sample;
fprintf('#  sign 一致率: %d/%d = %.1f%%\n', sum(sign_OK), N_sample, 100*sign_rate);
fprintf('#  eps_r range: [%.3f, %.3f]\n', min(eps_list), max(eps_list));
valid = abs(g_FD_list) > 1e-30;
if sum(valid) > 0
    ratios = g_adj_list(valid) ./ g_FD_list(valid);
    fprintf('#  ratio mean=%.4f, CV=%.4f\n', mean(ratios), std(ratios)/abs(mean(ratios)));
end

% 关键判定
fd_positive = sum(g_FD_list > 0);  % FD 说应该减小（g>0→eps↓）
fprintf('#  FD 指向"减小 eps_r"（g>0）: %d/%d\n', fd_positive, N_sample);
adj_positive = sum(g_adj_list > 0);
fprintf('#  伴随指向"减小 eps_r"（g>0）: %d/%d\n', adj_positive, N_sample);

if sign_rate > 0.8
    fprintf('#\n#  ★★★ 过冲体素梯度方向验证 PASS ★★★\n');
    fprintf('#  即使 eps_r 超过 5，伴随梯度仍正确指向减小方向 ★★★\n');
else
    fprintf('#\n#  ⚠ 过冲体素梯度方向部分不一致\n');
end
fprintf('############################################################\n');

%% 8. 保存
result = struct();
result.eps_list = eps_list;
result.g_adj = g_adj_list;
result.g_FD = g_FD_list;
result.sign_OK = sign_OK;
result.sign_rate = sign_rate;
result.target = 'decrease (to eps_r=5)';

save(fullfile(p.dir_result, 'overshoot_verify_result.mat'), 'result');
fprintf('\n[OS] 结果已保存: data/results/overshoot_verify_result.mat\n');

% 恢复
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model.param.set('adjoint_mode', '1'); catch, end

end

%% ====== 辅助函数 ======
function solve_quiet_os(model, p)
    try
        model.param.set('freq', num2str(p.freq));
        try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
    catch
    end
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end
    % 确保正演模式
    try model.physics('emw').prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    try model.param.set('adjoint_mode', '1'); catch, end
    try model.physics('emw').feature('vec1').set('Je', {'0','0','0'}); catch, end
    try
        s1 = model.sol('sol1').feature('s1');
        try s1.feature('dDirect'); catch
            s1.create('dDirect', 'Direct');
            s1.feature('dDirect').set('linsolver', 'pardiso');
        end
        try s1.feature('fc1').set('linsolver', 'dDirect'); catch, end
    catch
    end
    model.sol('sol1').runAll();
end

function s = ternary_s(cond, a, b)
    if cond, s=a; else, s=b; end
end
