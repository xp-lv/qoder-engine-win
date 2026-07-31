function result = run_fd_truth()
%RUN_FD_TRUTH FD 梯度真值采集 + 伴随梯度对比（单参数 eps_r）
%
%   ★ 伴随法验证 Layer 2：参数级 FD vs 伴随对比 ★
%
%   流程：
%     1. 构建 2 层极简 COMSOL 模型 + 体素网格
%     2. 设真值 eps_r → 正演 → J_obs（观测数据）
%     3. 设初始猜测 eps_r_init → 正演 → E_total
%     4. FD: 多步长中心差分 [0.1, 0.01, 0.001] → g_FD（真值梯度）
%     5. 伴随: 精确双源伴随 → g_adjoint
%     6. 对比：cos(g_FD, g_adj), ratio, sign
%
%   判据：
%     cos > 0.95  → 方向正确
%     |ratio-1| < 0.05  → 幅度精确
%     sign > 0    → 符号一致
%
%   用法（需要 COMSOL Server 运行在端口 2036）：
%     >> cd COMSOL/pipline_adjoint
%     >> result = run_fd_truth();

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n');
fprintf('############################################################\n');
fprintf('#  伴随法验证 Layer 2: FD 真值 vs 伴随梯度\n');
fprintf('#  单参数 eps_r，多步长 FD 收敛验证\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid = build_measurement_grid(p);

fprintf('[FD] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FD] [FAIL] mphstart: %s\n', ME.message); return;
    end
end

fprintf('[FD] 加载 2layer.mph...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

% 确保 vec1 (ExternalCurrentDensity) 存在
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end

%% 2. 提取体素网格
fprintf('[FD] 提取 FEM 网格...\n');
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
N_inner = sum(inner);
inner_idx = find(inner);
inner_pos = voxel.pos(inner, :);

fprintf('[FD] 内部体素: %d\n', N_inner);

%% 3. 预计算 J_obs（真值 eps_r_true）
fprintf('\n[FD] ===== 预计算 J_obs（真值 eps_r=%.1f）=====\n', p.eps_r_true);
voxel_truth = voxel;
voxel_truth.epsilon_r(inner) = p.eps_r_true;
update_epsilon(model, voxel_truth, p);

model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
J_obs_sq = sum(abs(J_obs).^2, 2);
J_obs_safe = max(J_obs_sq, 1e-12);

fprintf('[FD] J_obs 预计算完成: |J_obs| mean=%.4e\n', mean(vecnorm(J_obs, 2, 2)));

%% 4. 在初始猜测点做正演 + 提取场
fprintf('\n[FD] ===== 正演（初始猜测 eps_r=%.1f）=====\n', p.eps_r_init);
voxel.epsilon_r(inner) = p.eps_r_init;
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
J_hyp = lc.J_obs_perp;
Delta_J = J_obs - J_hyp;

fprintf('[FD] 正演完成: |E_total| mean=%.4e, |Delta_J| mean=%.4e\n', ...
    mean(vecnorm(E_total, 2, 2)), mean(vecnorm(Delta_J, 2, 2)));

%% 5. 计算伴随梯度（一次正演已做完，接下来求伴随）
fprintf('\n[FD] ===== 精确双源伴随梯度 =====\n');
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;  % ★ ⚠5 修复：不预归一化，F_obs 归一化统一在梯度层面处理

[Js, Ms, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, p);
[lambda, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);

if ~adj_ok
    fprintf('[FD] [FAIL] 伴随求解失败\n');
    result = struct('status', 'fail', 'reason', 'adjoint_solve_failed');
    return;
end

fprintf('[FD] 伴随场提取: |lambda| mean=%.4e\n', mean(vecnorm(lambda, 2, 2)));

% 体素梯度（bilinear 点积）
k0_sq = p.k0^2;
g_voxel = zeros(N_inner, 1);
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
        g_voxel(vi) = -k0_sq * voxel.dV(inner_idx(vi)) * gs;
    end
    fprintf('[FD] 使用 4-pt Gauss 积分\n');
else
    for vi = 1:N_inner
        g_voxel(vi) = -k0_sq * voxel.dV(inner_idx(vi)) * real(sum(E_total(vi,:) .* lambda(vi,:)));
    end
    fprintf('[FD] 使用质心近似\n');
end

% 均匀球：g_eps_r = sum(g_voxel)（deps/deps_r = 1 对所有内部体素）
% ★ ⚠5 修复：伴随梯度统一除以 F_obs，与 FD 定义 A 自洽
g_adjoint = sum(g_voxel) / F_obs;

fprintf('[FD] 伴随梯度 g_adjoint(eps_r) = %+.6e\n', g_adjoint);

%% 6. FD 梯度采集（多步长中心差分）
fprintf('\n[FD] ===== FD 多步长中心差分 =====\n');
deltas = p.fd_deltas_eps;
g_FD_vals = zeros(size(deltas));

for di = 1:length(deltas)
    delta = deltas(di);

    % F(eps_r + delta)
    pp = p.eps_r_init + delta;
    voxel.epsilon_r(inner) = pp;
    update_epsilon(model, voxel, p);
    solve_forward_quiet(model, voxel, p);
    sf_p = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf_p, p);
    dJ_p = J_obs - lc_p.J_obs_perp;
    F_plus = sum(lc_p.dOmega .* sum(abs(dJ_p).^2, 2)) / F_obs;  % ★ ⚠5 修复：统一用定义 A

    % F(eps_r - delta)
    pm = p.eps_r_init - delta;
    voxel.epsilon_r(inner) = pm;
    update_epsilon(model, voxel, p);
    solve_forward_quiet(model, voxel, p);
    sf_m = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf_m, p);
    dJ_m = J_obs - lc_m.J_obs_perp;
    F_minus = sum(lc_m.dOmega .* sum(abs(dJ_m).^2, 2)) / F_obs;  % ★ ⚠5 修复：统一用定义 A

    g_FD_vals(di) = (F_plus - F_minus) / (2 * delta);

    fprintf('  delta=%.4e: F+=%.8e, F-=%.8e, g_FD=%+.8e\n', ...
        delta, F_plus, F_minus, g_FD_vals(di));
end

% 参考值（最小步长）
g_FD_ref = g_FD_vals(end);

%% 7. 对比分析
fprintf('\n############################################################\n');
fprintf('#  FD 真值 vs 伴随梯度 对比\n');
fprintf('############################################################\n');
fprintf('#  g_FD(δ=%.0e)   = %+.6e\n', deltas(end), g_FD_ref);
fprintf('#  g_adjoint         = %+.6e\n', g_adjoint);

ratio = g_adjoint / g_FD_ref;
sign_val = sign(real(g_FD_ref) * real(g_adjoint));
cos_val = 1.0;  % 单参数时 cos 恒为 ±1

fprintf('#  ratio             = %.6f\n', real(ratio));
fprintf('#  sign              = %+d\n', sign_val);
fprintf('#\n');

% FD 收敛性检查
fprintf('#  FD 步长收敛性:\n');
for di = 1:length(deltas)
    fprintf('#    δ=%.0e: g_FD=%+.6e\n', deltas(di), g_FD_vals(di));
end
fd_stable = all(sign(g_FD_vals) == sign(g_FD_vals(1)));
if fd_stable
    fprintf('#    → ★ FD 方向稳定（所有步长同号）★\n');
else
    fprintf('#    → ⚠ FD 方向不稳定（步长间符号变化）\n');
end
fprintf('############################################################\n');

%% 8. 判定
fprintf('\n========== 判定 ==========\n');
pass_dir = (sign_val > 0);
pass_ratio = (abs(real(ratio) - 1) < 0.05);
pass_fd = fd_stable;

if pass_dir && pass_ratio && pass_fd
    fprintf('★★★ Layer 2 PASS：伴随法参数级精确 ★★★\n');
elseif pass_dir && ~pass_ratio
    fprintf('方向正确，幅度偏差 ratio=%.4f → 需标定 coeff_base\n', real(ratio));
elseif ~pass_dir
    fprintf('★★★ Layer 2 FAIL：梯度方向反向（sign=%+d）★★★\n', sign_val);
    fprintf('  → 检查 coeff_base 符号、共轭约定\n');
else
    fprintf('FD 不可靠，需增大步长或检查数值噪声\n');
end
fprintf('==========================\n');

%% 9. 保存结果
result = struct();
result.g_FD = g_FD_vals;
result.g_FD_ref = g_FD_ref;
result.g_adjoint = g_adjoint;
result.ratio = real(ratio);
result.sign = sign;
result.fd_stable = fd_stable;
result.pass_dir = pass_dir;
result.pass_ratio = pass_ratio;
result.deltas = deltas;
result.eps_r_init = p.eps_r_init;
result.eps_r_true = p.eps_r_true;

save(fullfile(p.dir_result, 'fd_truth_result.mat'), 'result');
fprintf('\n结果已保存: data/results/fd_truth_result.mat\n');

end

%% ====== 辅助函数 ======
function solve_forward_quiet(model, voxel, p)
%安静版正演（抑制日志）
try
    model.param.set('freq', num2str(p.freq));
    try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
catch
end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
try
    s1 = model.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch, s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso'); end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
catch
end
model.sol('sol1').runAll();
end
