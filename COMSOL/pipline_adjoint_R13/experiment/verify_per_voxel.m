function result = verify_per_voxel(N_sample)
%VERIFY_PER_VOXEL 逐体素伴随梯度方向验证
%
%   对代表性体素子集独立做 FD，与伴随梯度逐个比较
%
%   核心判据：
%     1. sign 一致率：逐体素 sign(g_FD_i * g_adj_i) > 0 的比例
%     2. cos θ：多参数方向的余弦相似度
%     3. ratio 分布：g_adj_i / g_FD_i 的统计分布（应趋近同一常数）
%
%   采样策略：
%     - 从 1164 个内部体素中均匀采样 N_sample 个（默认 30）
%     - 每个体素独立做 ±delta FD（2 次正演/体素）
%     - 总计 2*N_sample 次额外正演（30 个体素 ≈ 60 次 ≈ 5-10 min）
%
%   用法：
%     >> verify_per_voxel(30)  % 30 个代表性体素
%     >> verify_per_voxel(1164)  % 全量（约 3-4 小时）

if nargin < 1, N_sample = 30; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  逐体素伴随梯度方向验证\n');
fprintf('#  N_sample = %d（从 %d 内部体素中采样）\n', N_sample, 0);
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid = build_measurement_grid(p);

fprintf('[PV] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[PV] [FAIL] mphstart: %s\n', ME.message); return;
    end
end

fprintf('[PV] 加载 2layer.mph...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end

% ★ 粗化网格以降低体素数（hmax 0.015→0.028，预计 ~200 内部 tet）
try
    m1 = model.mesh('mesh1');
    % 尝试修改 size features 的 hmax
    ftags = m1.feature().tags();
    for fi = 1:length(ftags)
        fn = char(ftags(fi));
        try
            cur_hmax = char(m1.feature(fn).getString('hmax'));
            if str2double(cur_hmax) < 0.025
                m1.feature(fn).set('hmax', '0.028');
                m1.feature(fn).set('hmin', '0.008');
                fprintf('[PV] 粗化网格: %s hmax %s → 0.028\n', fn, cur_hmax);
            end
        catch
        end
    end
    m1.run;
    fprintf('[PV] 网格已粗化（hmax=0.028）\n');
catch ME
    fprintf('[PV] [WARN] 网格粗化失败: %s，使用原始网格\n', ME.message);
    try model.mesh('mesh1').run; catch, end
end

% vec1 + 初始化
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end

%% 2. 提取网格
fprintf('[PV] 提取 FEM 网格...\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
N_v = length(voxel.epsilon_r);

fprintf('[PV] N_inner = %d\n', N_inner);

%% 3. 采样代表性体素
if N_sample >= N_inner
    sample_idx = 1:N_inner;  % 全量
else
    % 均匀采样 + 按距离球心分层
    r_inner = vecnorm(voxel.pos(inner_idx, :), 2, 2);
    % 按 r 排序后均匀采样，确保覆盖从球心到边界
    [~, sort_order] = sort(r_inner);
    step = floor(N_inner / N_sample);
    sample_idx = sort_order(1:step:N_inner);
    sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
end
N_s = length(sample_idx);
fprintf('[PV] 采样 %d 个体素（从 %d 中）\n', N_s, N_inner);

% 采样体素的全局索引
sample_global = inner_idx(sample_idx);
% 采样体素的坐标
sample_pos = voxel.pos(sample_global, :);
sample_r = vecnorm(sample_pos, 2, 2);

%% 4. 预计算 J_obs（真值 eps_r=5）
fprintf('[PV] 预计算 J_obs (eps_r=5.0)...\n');
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
fprintf('[PV] F_obs = %.6e\n', F_obs);

%% 5. 基准正演（非均匀梯度 eps_r）+ 伴随梯度
% ★ 非均匀初值：ε_r(r) = 3.0 + 1.5·x/R_inner（沿入射波方向线性梯度）
fprintf('\n[PV] 基准正演（非均匀梯度 eps_r）...\n');
inner_pos_all = voxel.pos(inner_idx, :);  % [N_inner x 3]
eps_grad = p.eps_r_init + 1.5 * inner_pos_all(:,1) / p.R_inner;
fprintf('[PV] eps_r 梯度: range [%.3f, %.3f], mean=%.3f\n', min(eps_grad), max(eps_grad), mean(eps_grad));
voxel.epsilon_r(inner) = eps_grad;
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

% 残差
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
J_hyp = lc.J_obs_perp;
Delta_J = J_obs - J_hyp;

fprintf('[PV] |Delta_J| mean = %.4e\n', mean(vecnorm(Delta_J, 2, 2)));

% 伴随源
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;

[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, p);
[lambda, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);

if ~adj_ok
    fprintf('[PV] [FAIL] 伴随求解失败\n');
    result = struct('status', 'fail', 'reason', 'adjoint_failed');
    return;
end

fprintf('[PV] |lambda| mean = %.4e\n', mean(vecnorm(lambda, 2, 2)));

%% 6. 计算逐体素伴随梯度
k0_sq = p.k0^2;
g_adj_all = zeros(N_inner, 1);

% Gauss 积分
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && size(E_gauss,1) == size(voxel.gauss_pos,1) ...
    && size(lambda_gauss,1) == size(voxel.gauss_pos,1);

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
    fprintf('[PV] 伴随梯度使用 4-pt Gauss\n');
else
    for vi = 1:N_inner
        g_adj_all(vi) = -k0_sq * voxel.dV(inner_idx(vi)) * real(sum(E_total(vi,:) .* lambda(vi,:)));
    end
    fprintf('[PV] 伴随梯度使用质心近似\n');
end

% 归一化（与统一 F 定义一致）
g_adj_all = g_adj_all / F_obs;

%% 7. 逐体素 FD 梯度
fprintf('\n[PV] ===== 逐体素 FD 梯度（N_sample=%d）=====\n', N_s);
fd_delta = p.fd_delta_ref;  % 使用最小步长 0.001
fprintf('[PV] FD 步长 delta = %.4e\n', fd_delta);

g_FD_sample = zeros(N_s, 1);
g_adj_sample = zeros(N_s, 1);

for si = 1:N_s
    vi = sample_idx(si);
    v_global = inner_idx(vi);

    % 保存原始 eps_r
    eps_orig = voxel.epsilon_r(v_global);

    % F(eps + delta)
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    sf_p = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf_p, p);
    dJ_p = J_obs - lc_p.J_obs_perp;
    F_plus = sum(dOmega .* sum(abs(dJ_p).^2, 2)) / F_obs;

    % F(eps - delta)
    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    sf_m = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf_m, p);
    dJ_m = J_obs - lc_m.J_obs_perp;
    F_minus = sum(dOmega .* sum(abs(dJ_m).^2, 2)) / F_obs;

    % 恢复
    voxel.epsilon_r(v_global) = eps_orig;

    g_FD = (F_plus - F_minus) / (2 * fd_delta);
    g_FD_sample(si) = g_FD;
    g_adj_sample(si) = g_adj_all(vi);

    r_v = sample_r(si);
    if mod(si, 5) == 0 || si == N_s
        fprintf('  [%3d/%3d] r=%.3f: g_FD=%+.4e, g_adj=%+.4e, ratio=%.4f, sign=%s\n', ...
            si, N_s, r_v, g_FD, g_adj_all(vi), ...
            g_adj_all(vi)/g_FD, ternary_s(g_FD*g_adj_all(vi)>0, 'OK', 'XX'));
    end
end

%% 8. 统计分析
fprintf('\n############################################################\n');
fprintf('#  逐体素统计分析\n');
fprintf('############################################################\n');

% sign 一致率
sign_match = sign(g_FD_sample .* g_adj_sample) > 0;
sign_rate = sum(sign_match) / N_s;

% ratio 统计
ratios = g_adj_sample ./ g_FD_sample;
valid = abs(g_FD_sample) > 1e-30;  % 排除 FD ≈ 0 的体素
ratios_valid = ratios(valid);

fprintf('#  sign 一致率: %d/%d = %.1f%%\n', sum(sign_match), N_s, 100*sign_rate);
fprintf('#  ratio 统计 (|g_FD| > 1e-30 的 %d 个体素):\n', sum(valid));
if ~isempty(ratios_valid)
    fprintf('#    mean   = %.6f\n', mean(ratios_valid));
    fprintf('#    median = %.6f\n', median(ratios_valid));
    fprintf('#    std    = %.6f\n', std(ratios_valid));
    fprintf('#    CV     = %.6f\n', std(ratios_valid)/abs(mean(ratios_valid)));
    fprintf('#    min    = %.6f\n', min(ratios_valid));
    fprintf('#    max    = %.6f\n', max(ratios_valid));
end

% cos θ（多参数方向）
if N_s >= 2
    cos_theta = dot(g_FD_sample, g_adj_sample) / (norm(g_FD_sample) * norm(g_adj_sample));
    fprintf('#  cos θ (多参数方向): %.6f\n', cos_theta);
else
    cos_theta = NaN;
end

fprintf('############################################################\n');

%% 9. 按距离分 bin 统计
fprintf('\n#  按距球心距离分 bin:\n');
r_bins = [0, 0.02, 0.04, 0.06];
for bi = 1:length(r_bins)-1
    mask = sample_r >= r_bins(bi) & sample_r < r_bins(bi+1);
    if sum(mask) > 0
        sign_bin = sum(sign(g_FD_sample(mask) .* g_adj_sample(mask)) > 0);
        fprintf('#    r∈[%.2f,%.2f): %d 体素, sign OK=%d/%d (%.0f%%)\n', ...
            r_bins(bi), r_bins(bi+1), sum(mask), sign_bin, sum(mask), ...
            100*sign_bin/sum(mask));
    end
end

%% 10. 判定
fprintf('\n========== 综合判定 ==========\n');
if sign_rate > 0.9 && cos_theta > 0.8
    fprintf('★★★ 逐体素方向验证 PASS ★★★\n');
    fprintf('  sign 一致率 %.1f%% > 90%%, cos θ=%.4f > 0.8\n', 100*sign_rate, cos_theta);
    verdict = 'pass';
elseif sign_rate > 0.7
    fprintf('⚠ 逐体素方向部分通过\n');
    fprintf('  sign 一致率 %.1f%%, cos θ=%.4f\n', 100*sign_rate, cos_theta);
    verdict = 'partial';
else
    fprintf('★★★ 逐体素方向验证 FAIL ★★★\n');
    fprintf('  sign 一致率仅 %.1f%%\n', 100*sign_rate);
    verdict = 'fail';
end
fprintf('==============================\n');

%% 11. 保存
result = struct();
result.N_sample = N_s;
result.N_inner = N_inner;
result.sample_idx = sample_idx;
result.sample_pos = sample_pos;
result.sample_r = sample_r;
result.g_FD = g_FD_sample;
result.g_adj = g_adj_sample;
result.ratios = ratios;
result.sign_match = sign_match;
result.sign_rate = sign_rate;
result.cos_theta = cos_theta;
result.verdict = verdict;
result.fd_delta = fd_delta;
result.eps_r_init = p.eps_r_init;
result.eps_r_true = p.eps_r_true;

% 全量伴随梯度也保存
result.g_adj_all = g_adj_all;

save(fullfile(p.dir_result, 'per_voxel_result.mat'), 'result');
fprintf('\n[PV] 结果已保存: data/results/per_voxel_result.mat\n');

end

%% ====== 辅助函数 ======
function solve_quiet(model, p)
    try
        model.param.set('freq', num2str(p.freq));
        try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
    catch
    end
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end
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
    if cond, s = a; else, s = b; end
end
