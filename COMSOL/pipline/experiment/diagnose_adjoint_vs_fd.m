function result = diagnose_adjoint_vs_fd(eps_r_test_opt, hole_pos_test_opt)
%DIAGNOSE_ADJOINT_VS_FD FD 地面真值 vs 精确双源伴随梯度 对齐诊断
%
%   ★ 增强版 2026-07-27：支持多测试点 + coeff_base 自动标定 + CV 统计 ★
%
%   result = diagnose_adjoint_vs_fd()                           % 默认 t=0.5
%   result = diagnose_adjoint_vs_fd(4.0, [0.015;0.010;0.005])   % 指定点
%
%   返回 result 结构体，含 g_FD, g_adjoint, cos_vec, ratio_mean, ratio_cv, coeff_base_rec
%
%   ★ 用途：用 central FD 作为地面真值，标定精确双源伴随法的推导是否正确 ★
%
%   方法：
%     1. 在 cavity 4 参数（eps_r + hole x/y/z）的当前点做 central FD
%        g_FD_i = [F(p+δe_i) - F(p-δe_i)] / (2δ)   （8 次 COMSOL 正演）
%     2. 同时用精确双源伴随计算梯度
%        g_adjoint_i = dF/dp_i（经 build_adjoint_source + solve_adjoint + 链式法则）
%     3. 对比：cos(g_FD, g_adjoint) + ratio(g_adjoint/g_FD)
%
%   目标函数（与 C01_cavity_inversion_loop 完全一致）：
%     F(p) = mean_k [ |ΔJ(k)|² / (|J_obs(k)|² + floor) / 6 ]
%     其中 ΔJ = J_obs - J_hyp，J_hyp = lightcone_project(forward(p))
%
%   诊断模式：
%     cos ≈ 1, ratio ≈ 1 → 伴随正确
%     cos ≈ 1, ratio = c  → 方向对，幅度错（标量系数 bug）
%     cos ≈ 0             → 方向错（转置核推导 bug 或共轭约定错）
%     cos ≈ -1            → 方向反（Wirtinger 共轭符号错）

fprintf('\n========== FD vs 精确双源伴随 对齐诊断 ==========\n');

addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'algorithm');

%% 1. 初始化（复用 run_experiment 的设置流程）
fprintf('[DIAG] 加载 config + 测量网格...\n');
p = config();
grid = build_measurement_grid(p);

fprintf('[DIAG] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[DIAG] [FAIL] mphstart: %s\n', ME.message);
        return;
    end
end
fprintf('[DIAG] 加载模型...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

%% 2. 提取体素网格
fprintf('[DIAG] 提取 FEM 网格...\n');
R_scatter = p.a_scatter;
voxel = fem_mesh_utils(model, p, R_scatter);

%% 3. 设置 cavity 参数（★ 支持外部传入测试点 ★）
% 路径 p(t) = p_init + t·(p_true − p_init)
if nargin < 1 || isempty(eps_r_test_opt)
    eps_r_test = 4.0;            % t=0.5: 3.0 + 0.5×2.0 = 4.0
else
    eps_r_test = eps_r_test_opt;
end
if nargin < 2 || isempty(hole_pos_test_opt)
    hole_pos_test = [0.015; 0.010; 0.005];  % t=0.5
else
    hole_pos_test = hole_pos_test_opt(:);
end
R_hole = 0.03;
N_freq = 1;
freqs = [1.0e9];

% 凸区域真值方向（梯度应与此同向：g·dp > 0）
p_init = [3.0; 0; 0; 0];
p_true_vec = [5.0; 0.03; 0.02; 0.01];
dp_true = p_true_vec - p_init;  % [2.0, 0.03, 0.02, 0.01]

fprintf('[DIAG] 测试点: eps_r=%.2f, hole=[%.3f,%.3f,%.3f], R_hole=%.3f\n', ...
    eps_r_test, hole_pos_test, R_hole);

%% 3.5 预计算公共变量（★ 提前定义，供 FD 和伴随共用 ★）
delta_sdf = 0.008;  % SDF 半宽
inner_mask = voxel.mask_interior;
inner_pos = voxel.pos(inner_mask, :);

%% 4. 预计算 J_obs（默认真值：eps_r=5.0, hole=[0.03,0.02,0.01]）
fprintf('[DIAG] 预计算 J_obs（真值 eps_r=5.0, hole=[0.03,0.02,0.01]）...\n');
voxel_truth = voxel;
eps_r_true_val = 5.0;
hole_pos_true = [0.03; 0.02; 0.01];
d_true = sqrt(sum((inner_pos - hole_pos_true').^2, 2));
voxel_truth.epsilon_r(inner_mask) = eps_r_true_val + (1.0 - eps_r_true_val) * 0.5 * (1 - tanh(d_true / delta_sdf));
update_epsilon(model, voxel_truth, p);

J_obs_multi = cell(1, N_freq);
for fi = 1:N_freq
    pf = p;
    pf.freq = freqs(fi);
    pf.omega = 2*pi*pf.freq;
    pf.k0 = pf.omega / pf.c;
    pf.lambda = pf.c / pf.freq;
    solve_forward_quiet(model, voxel_truth, pf);
    sf = extract_scattered(model, grid);
    lc_obs = lightcone_project(grid, sf, pf);
    J_obs_multi{fi} = lc_obs.J_obs_perp;
end

%% 5. FD 梯度计算（内联，避免 struct 值传递问题）

%% 6. 计算 FD 梯度（central difference）
fprintf('\n[DIAG] 计算 central FD 梯度（8 次 COMSOL 正演）...\n');

% 步长
delta_eps_r = 0.01;
delta_hole = 1e-3;

params_0 = [eps_r_test; hole_pos_test];
N_param = 4;

g_FD = zeros(N_param, 1);

for i = 1:N_param
    dp = zeros(N_param, 1);
    if i == 1
        dp(i) = delta_eps_r;
    else
        dp(i) = delta_hole;
    end

    % p+
    p_plus = params_0 + dp;
    er = p_plus(1); hp = p_plus(2:4);
    d_p = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = er + (1.0 - er) * 0.5 * (1 - tanh(d_p / delta_sdf));
    update_epsilon(model, voxel, p);
    pf = p; pf.freq=freqs(1); pf.omega=2*pi*pf.freq; pf.k0=pf.omega/pf.c; pf.lambda=pf.c/pf.freq;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf, pf);
    J_hyp_p = lc_p.J_obs_perp;
    dJ = J_obs_multi{1} - J_hyp_p;
    Jo = sum(abs(J_obs_multi{1}).^2,2); Jos = max(Jo,1e-12);
    F_plus = mean(sum(abs(dJ).^2,2) ./ Jos / 6);
    fprintf('[DIAG]   FD [%d/4] p+ done (F=%.6e)\n', i, F_plus);

    % p-
    p_minus = params_0 - dp;
    er = p_minus(1); hp = p_minus(2:4);
    d_m = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = er + (1.0 - er) * 0.5 * (1 - tanh(d_m / delta_sdf));
    update_epsilon(model, voxel, p);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf, pf);
    J_hyp_m = lc_m.J_obs_perp;
    dJ = J_obs_multi{1} - J_hyp_m;
    F_minus = mean(sum(abs(dJ).^2,2) ./ Jos / 6);
    fprintf('[DIAG]   FD [%d/4] p- done (F=%.6e)\n', i, F_minus);

    g_FD(i) = (F_plus - F_minus) / (2 * dp(i));
    fprintf('[DIAG]   FD g_%d = %.6e\n', i, g_FD(i));
end

%% 7. 计算精确双源伴随梯度
fprintf('\n[DIAG] 计算精确双源伴随梯度...\n');

% 设测试点 ε 分布（★ 内联，避免值传递 ★）
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0 - eps_r_test) * 0.5 * (1 - tanh(d_test / delta_sdf));
update_epsilon(model, voxel, p);

g_adjoint = zeros(N_param, 1);
g_voxel_adjoint = zeros(sum(voxel.mask_interior), 1);  % 体素级 ∂F/∂ε

% 与 inversion_loop 同口径
N_inner = sum(voxel.mask_interior);
inner_idx = find(voxel.mask_interior);

for fi = 1:N_freq
    pf = p;
    pf.freq = freqs(fi);
    pf.omega = 2*pi*pf.freq;
    pf.k0 = pf.omega / pf.c;
    pf.lambda = pf.c / pf.freq;

    fprintf('[DIAG]   正演 freq=%d...\n', fi);
    [E_total, ~, E_gauss] = solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc_new = lightcone_project(grid, sf, pf);
    J_hyp = lc_new.J_obs_perp;

    J_obs_fi = J_obs_multi{fi};
    Delta_J = J_obs_fi - J_hyp;
    J_obs_sq = sum(abs(J_obs_fi).^2, 2);
    J_obs_safe = max(J_obs_sq, 1e-12);  % rel_err_floor 底

    % 伴随
    lc_new.k_vec = pf.k0 * lc_new.k_dir;
    lc_new.J_obs_perp = J_obs_fi;
    lc_new.Delta_J_perp = Delta_J ./ J_obs_safe;

    fprintf('[DIAG]   setup_exact_adjoint_source...\n');
    [lambda_fi, adj_ok, lambda_gauss] = setup_exact_adjoint_source(model, voxel, grid, lc_new, pf);

    if ~adj_ok
        fprintf('[DIAG] [WARN] 伴随求解失败，跳过\n');
        continue;
    end

    % 体素梯度 g_voxel = -k0²·Re(λ·E)·ΔV / N_freq
    k0_sq = pf.k0^2;
    dV_vec = voxel.dV;
    use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
                && size(E_gauss,1) == size(voxel.gauss_pos,1);
    gauss_w = voxel.gauss_w;

    if use_gauss
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            gp = (4*(vi-1)+1):(4*vi);
            gs = 0;
            for gpi = 1:4
                gs = gs + gauss_w(gpi) * dot(E_gauss(gp(gpi),:), lambda_gauss(gp(gpi),:));
            end
            g_voxel_adjoint(vi) = g_voxel_adjoint(vi) - k0_sq * dV_vec(v_idx) * real(gs) / N_freq;
        end
    else
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            g_voxel_adjoint(vi) = g_voxel_adjoint(vi) - k0_sq * dV_vec(v_idx) ...
                * real(dot(E_total(vi,:), lambda_fi(vi,:))) / N_freq;
        end
    end
end

%% 8. 从 g_voxel 到 g_param 的链式法则（dF/dp_i = Σ_v (∂F/∂ε_v)·(dε_v/dp_i)）
fprintf('\n[DIAG] 链式法则：g_voxel → g_param...\n');

% 参数 1: eps_r
% dε_v/d(eps_r) = 1 对 body 体素（SDF tanh 体内）
dE_deps = compute_dE_deps_sdf(voxel, hole_pos_test, R_hole, eps_r_test);  % 已是 inner 长度
g_adjoint(1) = sum(g_voxel_adjoint .* dE_deps);

% 参数 2-4: hole_pos (x,y,z)
% dε_v/d(hole_pos_j) = SDF-aware 链式法则
for j = 1:3
    dE_dhole_j = compute_dE_dhole_sdf(voxel, hole_pos_test, R_hole, eps_r_test, j);  % 已是 inner 长度
    g_adjoint(1+j) = sum(g_voxel_adjoint .* dE_dhole_j);
end

%% 9. 对比
fprintf('\n========== 对比结果 ==========\n');
fprintf('| 参数          | g_FD         | g_adjoint    | ratio(adj/FD) | cos    |\n');
fprintf('|---------------|--------------|--------------|---------------|--------|\n');

for i = 1:N_param
    names = {'eps_r', 'hole_x', 'hole_y', 'hole_z'};
    if abs(g_FD(i)) > 1e-30
        ratio_i = g_adjoint(i) / g_FD(i);
    else
        ratio_i = NaN;
    end
    fprintf('| %-13s | %.4e | %.4e | %14.4f | %6.3f |\n', ...
        names{i}, g_FD(i), g_adjoint(i), ratio_i, sign(g_FD(i)*g_adjoint(i)));
end

% 向量级 cos
if norm(g_FD) > 0 && norm(g_adjoint) > 0
    cos_vec = dot(g_FD, g_adjoint) / (norm(g_FD) * norm(g_adjoint));
    fprintf('\n向量 cos(g_FD, g_adjoint) = %.6f\n', cos_vec);
end

% ★ 凸区域判据：g·dp 应 > 0（梯度与真值方向同向）
fprintf('\n--- 凸区域真值方向判据 ---\n');
fprintf('真值方向 dp = [%.2f, %.4f, %.4f, %.4f]\n', dp_true);
gFD_dot_dp = dot(g_FD, dp_true);
gAdj_dot_dp = dot(g_adjoint, dp_true);
fprintf('g_FD · dp     = %+.4e → %s\n', gFD_dot_dp, ternary(gFD_dot_dp>0, '正确（指向真值）', '错误（背离真值）'));
fprintf('g_adjoint · dp = %+.4e → %s\n', gAdj_dot_dp, ternary(gAdj_dot_dp>0, '正确（指向真值）', '错误（背离真值）'));

%% 诊断（★ 增强版：CV 统计 + coeff_base 自动标定 + 结构化判定 ★）
ratios_all = g_adjoint ./ g_FD;
ratios_valid = ratios_all(isfinite(ratios_all) & abs(g_FD) > 1e-20);

if ~isempty(ratios_valid)
    ratio_mean = mean(ratios_valid);
    ratio_std = std(ratios_valid);
    ratio_cv = ratio_std / abs(ratio_mean);  % 变异系数
else
    ratio_mean = NaN; ratio_std = NaN; ratio_cv = NaN;
end

fprintf('\n========== 诊断结论 ==========\n');
fprintf('--- 梯度对齐指标 ---\n');
if exist('cos_vec', 'var')
    fprintf('  cos(g_FD, g_adjoint) = %.6f  (阈值 >0.95)  %s\n', ...
        cos_vec, ternary(cos_vec>0.95, '[PASS]', '[FAIL]'));
end
if ~isnan(ratio_mean)
    fprintf('  ratio mean            = %.6f  (阈值 1±0.05) %s\n', ...
        ratio_mean, ternary(abs(ratio_mean-1)<0.05, '[PASS]', '[FAIL]'));
    fprintf('  ratio CV (std/|mean|) = %.6f  (阈值 <0.1)   %s\n', ...
        ratio_cv, ternary(ratio_cv<0.1, '[PASS]', '[FAIL]'));
end
fprintf('  g_adjoint·dp          = %+.4e  (阈值 >0)     %s\n', ...
    gAdj_dot_dp, ternary(gAdj_dot_dp>0, '[PASS]', '[FAIL]'));

fprintf('\n--- coeff_base 自动标定 ---\n');
if ~isnan(ratio_mean) && abs(ratio_mean) > 1e-30
    % 当前 coeff_base 在 build_adjoint_source_fullmaxwell.m 中为 0.5i*omega*eps0
    omega_cur = p.omega(1); eps0_cur = p.eps0;
    coeff_current = 0.5i * omega_cur * eps0_cur;
    coeff_base_rec = coeff_current / ratio_mean;
    fprintf('  当前 coeff_base        = %.6e\n', coeff_current);
    fprintf('  ratio_mean             = %.6f\n', ratio_mean);
    fprintf('  推荐 coeff_base_final  = %.6e\n', coeff_base_rec);
    fprintf('  (填入 build_adjoint_source_fullmaxwell.m 第 61 行)\n');
else
    coeff_base_rec = NaN;
    fprintf('  ratio 无效，无法标定 coeff_base\n');
end

% 结构化判定
fprintf('\n--- 总判定 ---\n');
criteria_pass = 0; criteria_total = 0;
if exist('cos_vec', 'var')
    criteria_total = criteria_total + 1;
    if cos_vec > 0.95, criteria_pass = criteria_pass + 1; end
end
if ~isnan(ratio_mean)
    criteria_total = criteria_total + 1;
    if abs(ratio_mean - 1) < 0.05, criteria_pass = criteria_pass + 1; end
    criteria_total = criteria_total + 1;
    if ratio_cv < 0.1, criteria_pass = criteria_pass + 1; end
end
criteria_total = criteria_total + 1;
if gAdj_dot_dp > 0, criteria_pass = criteria_pass + 1; end

if criteria_total > 0
    fprintf('  通过 %d/%d 项判据\n', criteria_pass, criteria_total);
    if criteria_pass == criteria_total
        fprintf('  ★★★ 伴随法验证通过 ★★★\n');
    elseif cos_vec > 0.95 && ratio_cv < 0.1 && abs(ratio_mean-1) > 0.05
        fprintf('  结构正确（CV<0.1），仅需填入推荐 coeff_base_final 即可\n');
    elseif cos_vec > 0.95
        fprintf('  方向正确但 ratio 不恒定（CV=%.4f）→ 检查权重/共轭约定\n', ratio_cv);
    elseif cos_vec < -0.95
        fprintf('  ★★★ 方向反向（cos<-0.95）→ Wirtinger 共轭符号错 ★★★\n');
    elseif abs(cos_vec) < 0.3
        fprintf('  ★★★ 方向完全错（|cos|<0.3）→ 转置核推导或权重有 bug ★★★\n');
    else
        fprintf('  方向部分正确（cos=%.3f）→ 需逐层隔离定位\n', cos_vec);
    end
end
fprintf('=================================\n\n');

%% 保存结果 + 返回值
result = struct();
result.g_FD = g_FD;
result.g_adjoint = g_adjoint;
result.params_0 = params_0;
if exist('cos_vec', 'var'), result.cos_vec = cos_vec; else, result.cos_vec = NaN; end
result.ratio_mean = ratio_mean;
result.ratio_cv = ratio_cv;
result.coeff_base_rec = coeff_base_rec;
result.criteria_pass = criteria_pass;
result.criteria_total = criteria_total;
result.gAdj_dot_dp = gAdj_dot_dp;

save(fullfile('data', 'results', 'diagnose_adjoint_vs_fd.mat'), '-struct', 'result');
fprintf('[DIAG] 结果已保存: data/results/diagnose_adjoint_vs_fd.mat\n');

end

%% ====== 辅助函数 ======

function F = compute_objective(model, voxel, grid, p, freqs, hole_pos, R_hole, eps_r_val, J_obs_multi)
%计算目标函数 F(p)（与 C01_cavity_inversion_loop 同口径）
N_freq = length(freqs);
F_k_total = 0;

% 设 ε 分布（★ 直接修改 voxel.epsilon_r，避免值传递问题 ★）
delta = 0.008;
inner = voxel.mask_interior;
pos_inner = voxel.pos(inner, :);
d = sqrt(sum((pos_inner - hole_pos').^2, 2));
eps_inner = eps_r_val + (1.0 - eps_r_val) * 0.5 * (1 - tanh(d / delta));
voxel.epsilon_r(inner) = eps_inner;

% 调用 update_epsilon 更新模型
update_epsilon(model, voxel, p);

for fi = 1:N_freq
    pf = p;
    pf.freq = freqs(fi);
    pf.omega = 2*pi*pf.freq;
    pf.k0 = pf.omega / pf.c;
    pf.lambda = pf.c / pf.freq;

    % ★ 对齐：用标准 solve_forward（与伴随路径同口径）★
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    J_hyp = lc.J_obs_perp;

    J_obs_fi = J_obs_multi{fi};
    Delta_J = J_obs_fi - J_hyp;
    J_obs_sq = sum(abs(J_obs_fi).^2, 2);
    J_obs_safe = max(J_obs_sq, 1e-12);  % rel_err_floor 底
    Delta_sq = sum(abs(Delta_J).^2, 2);
    F_k_fi = Delta_sq ./ J_obs_safe / 6;
    F_k_total = F_k_total + mean(F_k_fi) / N_freq;
end

F = F_k_total;
end

function solve_forward_quiet(model, voxel, p)
%安静版正演（抑制日志）
original_freq = p.freq;
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

function set_epsilon_cavity(voxel, hole_pos, R_hole, eps_r_body, model, p)
%设 cavity epsilon 分布（SDF tanh 软边界）
delta = 0.008;  % SDF 半宽
inner = voxel.mask_interior;
pos = voxel.pos(inner, :);

% 计算每个体素到空洞中心的距离
d = sqrt(sum((pos - hole_pos').^2, 2));

% SDF tanh 软边界
eps_inner = eps_r_body + (1.0 - eps_r_body) * 0.5 * (1 - tanh(d / delta));

voxel.epsilon_r(inner) = eps_inner;

% 调用 update_epsilon 更新模型
update_epsilon(model, voxel, p);
end

function dE_deps = compute_dE_deps_sdf(voxel, hole_pos, R_hole, eps_r_body)
%∂ε_v/∂(eps_r) — SDF tanh 软边界
delta = 0.008;
inner = voxel.mask_interior;
pos = voxel.pos(inner, :);
d = sqrt(sum((pos - hole_pos').^2, 2));
% ε_v = eps_r + (1-eps_r)·0.5·(1-tanh(d/δ))
% dε/d(eps_r) = 1 - 0.5·(1-tanh(d/δ)) = 0.5·(1+tanh(d/δ))
dE_deps = zeros(size(pos,1), 1);
dE_deps = 0.5 * (1 + tanh(d / delta));
end

function dE_dhole = compute_dE_dhole_sdf(voxel, hole_pos, R_hole, eps_r_body, j)
%∂ε_v/∂(hole_pos_j) — SDF-aware 链式法则（H023）
delta = 0.008;
inner = voxel.mask_interior;
pos = voxel.pos(inner, :);

% d_i = |r_v - r_hole|
diff = pos - hole_pos';
d = sqrt(sum(diff.^2, 2));

% dε/d(d_i) = (1-eps_r) · 0.5 · (-sech²(d/δ)) / δ = -(1-eps_r)·0.5·sech²(d/δ)/δ
sech2 = 1 ./ cosh(d / delta).^2;
deps_dd = -(1 - eps_r_body) * 0.5 * sech2 / delta;

% dd/d(hole_j) = -(r_v,j - hole_j) / |r_v - hole_hole| = -diff(:,j)/d
dd_dhole = -diff(:, j) ./ (d + 1e-30);

% 链式法则：dε/d(hole_j) = (dε/d_d) · (d_d/d_hole_j)
dE_dhole = deps_dd .* dd_dhole;
end
