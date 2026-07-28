function diagnose_bilinear_dot()
%DIAGNOSE_BILINEAR_DOT 梯度公式修正：bilinear vs Hermitian dot
%
%   数学推导：
%     COMSOL 刚度矩阵 K 复对称 (K = K^T)，非 Hermitian
%     所以伴随梯度用普通转置 T，不是 Hermitian 转置 H
%     g = k0^2 * dV * Re(sum_d lambda_d * E_d)  (bilinear, no conj)
%     不是 g = -k0^2 * dV * Re(conj(E)*lambda)   (Hermitian, wrong)
%
%   本脚本对同一次伴随求解，测试 4 种梯度公式：
%     Mode A: -k0^2 * Re(conj(E)*lambda)  (当前代码)
%     Mode B: +k0^2 * Re(E.*lambda)       (bilinear, 正确符号)
%     Mode C: +k0^2 * Re(conj(E)*lambda)  (Hermitian, 正确符号)
%     Mode D: -k0^2 * Re(E.*lambda)       (bilinear, 保留负号)

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'));
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  bilinear dot vs Hermitian dot 梯度公式对照\n');
fprintf('#  K 复对称 -> 用普通转置 -> bilinear dot (no conj)\n');
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

%% 预计算 J_obs
fprintf('[BD] 预计算 J_obs...\n');
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

%% FD 地面真值
fprintf('\n[BD] 计算单参数 FD...\n');
params_0 = [eps_r_test; hole_pos_test];
fd_steps = [0.001, 0.0001, 0.0001, 0.0001];
g_FD = zeros(4, 1);
for pi_idx = 1:4
    delta = fd_steps(pi_idx);
    pp = params_0; pp(pi_idx) = pp(pi_idx) + delta;
    F_plus = compute_F(model, voxel, grid, p, pf0, pp, inner_pos, inner_mask, delta_sdf, J_obs);
    pm = params_0; pm(pi_idx) = pm(pi_idx) - delta;
    F_minus = compute_F(model, voxel, grid, p, pf0, pm, inner_pos, inner_mask, delta_sdf, J_obs);
    g_FD(pi_idx) = (F_plus - F_minus) / (2 * delta);
end
fprintf('[BD] g_FD = [%.6e, %.6e, %.6e, %.6e]\n', g_FD);

%% 正演 + 伴随
fprintf('\n[BD] 正演 + 伴随求解...\n');
d_test = sqrt(sum((inner_pos - hole_pos_test').^2, 2));
voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_test/delta_sdf));
update_epsilon(model, voxel, p);
pf = pf0;
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

% 伴随源
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
J_obs_safe = max(sum(abs(J_obs).^2, 2), 1e-12);
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J ./ J_obs_safe;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj = Js + Ms;

% 伴随求解（旧路径 vec1，lambda_raw 不取共轭）
[lambda, adj_ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
if ~adj_ok, fprintf('[BD] [FAIL]\n'); return; end

fprintf('[BD] lambda: |mean|=%.4e (conj=0)\n', mean(vecnorm(lambda, 2, 2)));

%% 链式法则权重
N_inner = sum(inner_mask);
inner_idx = find(inner_mask);
k0_sq = pf.k0^2; dV_vec = voxel.dV;
dE_deps = 0.5*(1+tanh(d_test/delta_sdf));
diff_v = inner_pos - hole_pos_test';
d_v = sqrt(sum(diff_v.^2, 2));
sech2 = 1./cosh(d_v/delta_sdf).^2;
deps_dd = -(1-eps_r_test)*0.5*sech2/delta_sdf;
dE_dhole = zeros(N_inner, 3);
for j = 1:3
    dE_dhole(:, j) = deps_dd .* (-diff_v(:,j)./(d_v+1e-30));
end

gauss_w = voxel.gauss_w;
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && size(E_gauss,1)==size(voxel.gauss_pos,1) ...
    && size(lambda_gauss,1)==size(voxel.gauss_pos,1);

%% 4 种梯度模式
modes = {'A: -Re(conj(E)*lam) [current]', ...
         'B: +Re(E.*lam) [bilinear]', ...
         'C: +Re(conj(E)*lam) [Hermitian+]', ...
         'D: -Re(E.*lam) [bilinear-]'};
all_ratios = zeros(4, 4);  % [mode x param]

for mi = 1:4
    g_voxel = zeros(N_inner, 1);

    if use_gauss
        for vi = 1:N_inner
            gp = (4*(vi-1)+1):(4*vi);
            v_idx = inner_idx(vi);
            gs = 0;
            for gpi = 1:4
                Eg = E_gauss(gp(gpi),:);
                Lg = lambda_gauss(gp(gpi),:);
                switch mi
                    case 1, val = -real(dot(Eg, Lg));     % -Re(conj(E)*lam)
                    case 2, val = real(sum(Lg .* Eg));     % +Re(lam.*E) bilinear
                    case 3, val = real(dot(Eg, Lg));       % +Re(conj(E)*lam)
                    case 4, val = -real(sum(Lg .* Eg));    % -Re(lam.*E)
                end
                gs = gs + gauss_w(gpi) * val;
            end
            g_voxel(vi) = k0_sq * dV_vec(v_idx) * gs;
        end
    else
        for vi = 1:N_inner
            v_idx = inner_idx(vi);
            Ev = E_total(vi,:);
            Lv = lambda(vi,:);
            switch mi
                case 1, val = -real(dot(Ev, Lv));
                case 2, val = real(sum(Lv .* Ev));
                case 3, val = real(dot(Ev, Lv));
                case 4, val = -real(sum(Lv .* Ev));
            end
            g_voxel(vi) = k0_sq * dV_vec(v_idx) * val;
        end
    end

    g_param = zeros(4, 1);
    g_param(1) = sum(g_voxel .* dE_deps);
    for j = 1:3
        g_param(1+j) = sum(g_voxel .* dE_dhole(:,j));
    end

    for pi_idx = 1:4
        if abs(g_FD(pi_idx)) > 1e-30
            all_ratios(pi_idx, mi) = g_param(pi_idx) / g_FD(pi_idx);
        else
            all_ratios(pi_idx, mi) = NaN;
        end
    end
end

%% 输出
fprintf('\n############################################################\n');
fprintf('#  bilinear vs Hermitian 对照结果\n');
fprintf('############################################################\n');
fprintf('#  %-32s  %8s  %8s  %8s  %8s  %6s\n', 'Mode', 'eps_r', 'hole_x', 'hole_y', 'hole_z', 'CV');
fprintf('#  %-32s  %8s  %8s  %8s  %8s  %6s\n', '----', '------', '------', '------', '------', '----');
best_cv = 1e10; best_mode = 0;
for mi = 1:4
    r = all_ratios(:, mi);
    rv = r(isfinite(r) & abs(r) > 1e-20);
    if ~isempty(rv)
        cv = std(rv) / abs(mean(rv));
    else
        cv = NaN;
    end
    fprintf('#  %-32s  %8.4f  %8.4f  %8.4f  %8.4f  %.4f\n', ...
        modes{mi}, r(1), r(2), r(3), r(4), cv);
    if ~isnan(cv) && cv < best_cv
        best_cv = cv; best_mode = mi;
    end
end
fprintf('#\n#  最佳模式: %s (CV=%.4f)\n', modes{best_mode}, best_cv);
if best_cv < 0.1
    fprintf('#  *** CV < 0.1！梯度公式正确！ratio 一致！***\n');
elseif best_cv < 0.3
    fprintf('#  CV < 0.3，接近一致（可能有数值误差残留）\n');
else
    fprintf('#  CV >= 0.3，梯度公式仍不正确\n');
end
fprintf('############################################################\n');

% 保存
results_dir = fullfile(pipline_dir, 'data', 'results');
if ~exist(results_dir,'dir'), mkdir(results_dir); end
save(fullfile(results_dir,'bilinear_dot_result.mat'), 'all_ratios', 'modes', 'g_FD', 'best_cv', 'best_mode');
end

function F = compute_F(model, voxel, grid, p, pf0, params, inner_pos, inner_mask, delta_sdf, J_obs)
    eps_r = params(1); hp = params(2:4);
    d_v = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = eps_r + (1.0-eps_r)*0.5*(1-tanh(d_v/delta_sdf));
    update_epsilon(model, voxel, p);
    pf = pf0; pf.freq=1e9; pf.omega=2*pi*pf.freq; pf.k0=pf.omega/p.c; pf.lambda=p.c/pf.freq;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    Jo = max(sum(abs(J_obs).^2,2), 1e-12);
    F = mean(sum(abs(dJ).^2,2) ./ Jo / 6);
end
