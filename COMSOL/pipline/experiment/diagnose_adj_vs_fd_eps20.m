function diagnose_adj_vs_fd_eps20()
%DIAGNOSE_ADJ_VS_FD_EPS20 伴随梯度 vs FD 梯度（无空洞，正弦初值）
%   管线1几何 (R=0.13, 1GHz), 均匀球无cavity
%   真值 eps_r=5, 初值 eps_r(x)=5+sin(2πx/L) 范围[4,6]
%   ★ 与管线2算法完全一致，仅几何不同

fprintf('\n=========================================================\n');
fprintf('  伴随梯度 vs FD（无空洞，正弦初值，管线1几何）\n');
fprintf('  R_body=0.13, 1GHz, eps_true=5, eps_init=[4,6] sin\n');
fprintf('=========================================================\n\n');

%% Step 0
setup();
p = config();
if ~isfield(p, 'rel_err_floor'), p.rel_err_floor = 1e-12; end

%% Step 1: COMSOL
try
    comsol_sock = java.net.Socket('localhost', p.comsol_port);
    comsol_sock.close();
catch
    error('COMSOL Server not running');
end
mphstart(p.comsol_port);
model = mphload(p.comsol_model_path);

%% Step 1.5: ★ 修复背景场（与管线2对齐）
% livelink_model.mph 中 BackgroundField.WaveType=GaussianBeam + Eb=0
% 改为 PlaneWave + Eb=[0,0,1]（与 pipline_adjoint/solve_forward.m 一致）
try
    phys = model.physics('emw');
    phys.prop('BackgroundField').set('WaveType', 'PlaneWave');
    phys.prop('BackgroundField').set('Eb', [0 0 1]);
    fprintf('OK BackgroundField fixed: WaveType=PlaneWave, Eb=[0,0,1]\n');
catch ME
    fprintf('[WARN] BackgroundField fix failed: %s\n', ME.message);
end

%% Step 2: Mesh
voxel_struct = fem_mesh_utils(model, p, p.a_scatter);
N_v = length(voxel_struct.epsilon_r);
inner_idx = find(voxel_struct.mask_interior);
N_inner = length(inner_idx);
pos_inner = voxel_struct.pos(inner_idx, :);
fprintf('N_total=%d, N_inner=%d\n', N_v, N_inner);

grid = build_measurement_grid(p);

%% Step 3: 真值正演 → J_obs (eps_r=5 均匀)
fprintf('\n=== 真值正演 (eps_r=5.0 均匀球) ===\n');
voxel_struct.epsilon_r(inner_idx) = 5.0;
voxel_struct.epsilon_r(~voxel_struct.mask_interior) = 1.0;
solve_forward(model, voxel_struct, p);
sf_truth = extract_scattered(model, grid);
lc_truth = lightcone_project(grid, sf_truth, p);
J_obs = lc_truth.J_obs_perp;

dOmega = lc_truth.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2, 2));
if F_obs < p.F_obs_min, F_obs = 1.0; end
fprintf('|J_obs| mean=%.4e, F_obs=%.6e\n', mean(vecnorm(J_obs,2,2)), F_obs);

%% Step 4: 非均匀初值正演 → J_hyp + 残差
% eps_r(x) = 5 + sin(2*pi*x / period), 沿入射波方向(x轴)正弦
% 范围 [4, 6], 均值 5
fprintf('\n=== 非均匀初值正演 ===\n');
L_period = 2 * p.a_scatter / 1.5;  % 周期 ~0.173m, 球内约1.5个周期
eps_init = 5.0 + sin(2 * pi * pos_inner(:,1) / L_period);
fprintf('eps_init range=[%.3f, %.3f] mean=%.3f\n', min(eps_init), max(eps_init), mean(eps_init));

voxel_struct.epsilon_r(inner_idx) = eps_init;
voxel_struct.epsilon_r(~voxel_struct.mask_interior) = 1.0;
[E_eval, ~, E_gauss_eval] = solve_forward(model, voxel_struct, p);
sf_eval = extract_scattered(model, grid);
lc_eval = lightcone_project(grid, sf_eval, p);
J_hyp = lc_eval.J_obs_perp;

Delta_J = J_obs - J_hyp;
F_current = sum(dOmega .* sum(abs(Delta_J).^2, 2)) / F_obs;
fprintf('|Delta_J| mean=%.4e, F(current)=%.6e\n', mean(vecnorm(Delta_J,2,2)), F_current);

%% Step 5: 精确双源伴随
fprintf('\n=== 精确双源伴随 ===\n');
lc_adj = lc_eval;
lc_adj.k_dir = fibonacci_sphere(p.N_k);
lc_adj.k_vec = p.k0 * lc_adj.k_dir;
lc_adj.J_obs_perp = J_obs;
lc_adj.Delta_J_perp = Delta_J;

[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc_adj, p);
[lambda, adj_ok, lambda_gauss] = solve_adjoint(model, voxel_struct, p, Js, source_pos, Ms);
if ~adj_ok, error('Adjoint failed'); end
fprintf('|lambda| mean=%.4e\n', mean(vecnorm(lambda,2,2)));

%% Step 6: 伴随梯度（管线2方式）
k0_sq = p.k0^2;
g_adj_all = zeros(N_inner, 1);
gauss_w = voxel_struct.gauss_w;

use_gauss = ~isempty(E_gauss_eval) && ~isempty(lambda_gauss) ...
    && size(E_gauss_eval,1) == size(voxel_struct.gauss_pos,1) ...
    && size(lambda_gauss,1) == size(voxel_struct.gauss_pos,1);

if use_gauss
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gauss_w(gpi) * real(sum(E_gauss_eval(gp(gpi),:) .* lambda_gauss(gp(gpi),:)));
        end
        g_adj_all(vi) = -k0_sq * voxel_struct.dV(inner_idx(vi)) * gs;
    end
    fprintf('梯度: 4-pt Gauss, bilinear\n');
else
    for vi = 1:N_inner
        g_adj_all(vi) = -k0_sq * voxel_struct.dV(inner_idx(vi)) * ...
            real(sum(E_eval(vi,:) .* lambda(vi,:)));
    end
    fprintf('梯度: 质心近似, bilinear\n');
end
g_adj_all = g_adj_all / F_obs;

fprintf('g_adj: min=%.4e max=%.4e mean=%.4e\n', min(g_adj_all), max(g_adj_all), mean(g_adj_all));

%% Step 7: 采样体素（按距球心均匀分层）
r_inner = vecnorm(pos_inner, 2, 2);
[~, sort_order] = sort(r_inner);
N_sample = 30;
step = floor(N_inner / N_sample);
sample_idx = sort_order(1:step:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);
fprintf('\n采样 %d 个体素（按距球心均匀分层）\n', N_s);

%% Step 8: FD 中心差分（管线2方式）
fd_delta = 0.001;
fprintf('\n--- FD (delta=%.4e) ---\n', fd_delta);

g_FD = zeros(N_s, 1);
g_adj_sel = zeros(N_s, 1);

for si = 1:N_s
    vi = sample_idx(si);
    v_global = inner_idx(vi);
    eps_orig = voxel_struct.epsilon_r(v_global);
    g_adj_sel(si) = g_adj_all(vi);

    % F(eps + delta)
    voxel_struct.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel_struct, p);
    solve_quiet(model, p);
    sf_p = extract_scattered(model, grid);
    lc_p = lightcone_project(grid, sf_p, p);
    dJ_p = J_obs - lc_p.J_obs_perp;
    F_plus = sum(dOmega .* sum(abs(dJ_p).^2, 2)) / F_obs;

    % F(eps - delta)
    voxel_struct.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel_struct, p);
    solve_quiet(model, p);
    sf_m = extract_scattered(model, grid);
    lc_m = lightcone_project(grid, sf_m, p);
    dJ_m = J_obs - lc_m.J_obs_perp;
    F_minus = sum(dOmega .* sum(abs(dJ_m).^2, 2)) / F_obs;

    voxel_struct.epsilon_r(v_global) = eps_orig;

    g_FD(si) = (F_plus - F_minus) / (2 * fd_delta);

    r_v = r_inner(vi);
    sm = sign(g_adj_sel(si)) == sign(g_FD(si));
    r = g_adj_sel(si) / (g_FD(si) + 1e-30);
    if mod(si, 5) == 0 || si == N_s
        fprintf('  [%2d/%2d] r=%.3f: g_adj=%+.4e g_FD=%+.4e ratio=%.4f sign=%s\n', ...
            si, N_s, r_v, g_adj_sel(si), g_FD(si), r, ternary(sm,'OK','XX'));
    end
end

%% Step 9: 汇总
fprintf('\n############################################################\n');
fprintf('#  方向一致性汇总（无空洞, 正弦初值, R=0.13, 1GHz）\n');
fprintf('############################################################\n');

sign_match = sign(g_FD .* g_adj_sel) > 0;
sign_rate = sum(sign_match) / N_s;
fprintf('#  sign 一致率: %d/%d = %.1f%%\n', sum(sign_match), N_s, 100*sign_rate);

cos_theta = dot(g_adj_sel, g_FD) / (norm(g_adj_sel) * norm(g_FD) + 1e-30);
fprintf('#  cos theta: %.6f\n', cos_theta);

ratios = g_adj_sel ./ (g_FD + 1e-30);
valid = abs(g_FD) > 1e-30;
if any(valid)
    rv = ratios(valid);
    fprintf('#  ratio: mean=%.6f median=%.6f std=%.6f CV=%.4f\n', ...
        mean(rv), median(rv), std(rv), std(rv)/abs(mean(rv)));
    fprintf('#  ratio range: [%.6f, %.6f]\n', min(rv), max(rv));
end
fprintf('############################################################\n');

% 按距离分bin
fprintf('\n#  按距球心距离分 bin:\n');
r_bins = [0, 0.03, 0.06, 0.09, 0.12, 0.14];
for bi = 1:length(r_bins)-1
    mask = r_inner(sample_idx) >= r_bins(bi) & r_inner(sample_idx) < r_bins(bi+1);
    if sum(mask) > 0
        sm_bin = sum(sign_match(mask));
        n_bin = sum(mask);
        fprintf('#    r in [%.2f,%.2f): %d 体素, sign OK=%d/%d', ...
            r_bins(bi), r_bins(bi+1), n_bin, sm_bin, n_bin);
        if sum(valid(mask)) > 0
            rv_bin = ratios(sample_idx(mask) > 0);  % fix
            rv_bin = ratios(mask & valid);
            if ~isempty(rv_bin)
                fprintf(', ratio mean=%.4f', mean(rv_bin));
            end
        end
        fprintf('\n');
    end
end

% 综合判定
fprintf('\n========== 综合判定 ==========\n');
if sign_rate >= 0.9 && cos_theta > 0.8
    fprintf('★★★ PASS ★★★ sign %.1f%% > 90%%, cos %.3f > 0.8\n', 100*sign_rate, cos_theta);
else
    fprintf('★★★ FAIL ★★★ sign %.1f%%, cos %.3f\n', 100*sign_rate, cos_theta);
end
fprintf('==============================\n');

% Save
results.eps_true = 5.0;
results.eps_init_type = 'sin_x_range_4_6';
results.freq = p.freq;
results.R_body = p.a_scatter;
results.N_sample = N_s;
results.g_adj = g_adj_sel;
results.g_FD = g_FD;
results.sign_rate = sign_rate;
results.cos_theta = cos_theta;
results.ratios = ratios;
save(fullfile('data','results','adj_vs_fd_nocavity_sine.mat'), 'results', '-v7.3');
fprintf('\nSaved: data/results/adj_vs_fd_nocavity_sine.mat\n');
end

%% ====== 安静求解 ======
function solve_quiet(model, p)
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
% ★ 确保背景场
try model.physics('emw').prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
end

function s = ternary(cond, a, b)
if cond, s = a; else, s = b; end
end
