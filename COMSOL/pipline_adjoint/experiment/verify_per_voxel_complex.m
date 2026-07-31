function result = verify_per_voxel_complex(N_sample)
%VERIFY_PER_VOXEL_COMPLEX 复数 eps_r 的逐体素 FD vs 伴随方向验证
%
%   真值: eps_r = 5.0 - 3.0j (复介电常数)
%   初值: eps_r = 3.0 - 1.0j
%
%   验证：FD 和伴随法对复数 eps_r 的梯度方向是否一致
%   注意：FD 扰动只扰动实部（deps_re），梯度也只看实部

if nargin < 1, N_sample = 30; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  复数 eps_r 逐体素 FD vs 伴随方向验证\n');
fprintf('#  真值: eps_r = 5.0 - 3.0j\n');
fprintf('#  初值: eps_r = 3.0 - 1.0j\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);

fprintf('[PVC] 连接 COMSOL Server...\n');
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[PVC] [FAIL] mphstart\n'); return;
    end
end

try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

fprintf('[PVC] 加载 2layer.mph...\n');
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
inner = voxel.mask_interior;
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('[PVC] N_inner = %d\n', N_inner);

%% 2. 预计算 J_obs（真值 eps_r = 5-3j）
fprintf('[PVC] 预计算 J_obs (eps_r=5-3j)...\n');
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

sf_obs = extract_scattered(model, grid_meas);
lc_obs = lightcone_project(grid_meas, sf_obs, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2));
if F_obs < p.F_obs_min, F_obs = 1.0; end
fprintf('[PVC] F_obs = %.6e\n', F_obs);

%% 3. 设复数初值 eps_r = 3-1j
fprintf('[PVC] 设初值 eps_r = 3.0 - 1.0j...\n');
voxel.epsilon_r(inner) = 3.0 - 1.0i;
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);

sf = extract_scattered(model, grid_meas);
lc = lightcone_project(grid_meas, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
F = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[PVC] F_data = %.6e\n', F);

%% 4. 伴随求解
lc.k_vec = p.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid_meas, lc, p);
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
if ~ok_adj
    fprintf('[PVC] [FAIL] 伴随求解失败\n'); return;
end
fprintf('[PVC] |lambda| mean = %.4e\n', mean(vecnorm(lambda,2,2)));

%% 5. 伴随梯度（只取实部 eps_r 的梯度）
% g_real(v) = dF/d(Re(eps_r(v)))
% 对复数 eps_r = a + bi, 扰动 Re → 扰动 a
% 梯度公式不变：g(v) = -k0^2 * dV * Re[E · conj(lambda)]
% 但现在 E 和 lambda 都在复数 eps_r 下求解
k0_sq = p.k0^2;
dV_vec = voxel.dV;
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
        g_adj_all(vi) = -k0_sq * dV_vec(inner_idx(vi)) * gs;
    end
else
    for vi = 1:N_inner
        g_adj_all(vi) = -k0_sq * dV_vec(inner_idx(vi)) * real(sum(E_total(vi,:) .* lambda(vi,:)));
    end
end
g_adj_all = g_adj_all / F_obs;

%% 6. 逐体素 FD（只扰动实部）
fprintf('\n[PVC] ===== 复数 eps_r 逐体素 FD (N=%d) =====\n', N_sample);

r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step = floor(N_inner / N_sample);
sample_idx = sort_order(1:step:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fd_delta = 0.001;
g_FD_sample = zeros(N_s, 1);
g_adj_sample = zeros(N_s, 1);

for si = 1:N_s
    vi = sample_idx(si);
    v_global = inner_idx(vi);
    eps_orig = voxel.epsilon_r(v_global);  % 复数
    
    % 只扰动实部：eps_r + delta + i*Im(eps_r)
    voxel.epsilon_r(v_global) = (real(eps_orig) + fd_delta) + 1i * imag(eps_orig);
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_p = extract_scattered(model, grid_meas);
    lc_p = lightcone_project(grid_meas, sf_p, p);
    F_plus = sum(dOmega .* sum(abs(J_obs - lc_p.J_obs_perp).^2, 2)) / F_obs;
    
    voxel.epsilon_r(v_global) = (real(eps_orig) - fd_delta) + 1i * imag(eps_orig);
    update_epsilon(model, voxel, p);
    solve_quiet_c(model, p);
    sf_m = extract_scattered(model, grid_meas);
    lc_m = lightcone_project(grid_meas, sf_m, p);
    F_minus = sum(dOmega .* sum(abs(J_obs - lc_m.J_obs_perp).^2, 2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig;  % 恢复
    
    g_FD = (F_plus - F_minus) / (2 * fd_delta);
    g_FD_sample(si) = g_FD;
    g_adj_sample(si) = g_adj_all(vi);
    
    if mod(si, 5) == 0 || si == N_s
        fprintf('  [%3d/%3d] r=%.3f: g_FD=%+.2e g_adj=%+.2e ratio=%.4f sign=%s\n', ...
            si, N_s, r_inner(vi), g_FD, g_adj_sample(si), g_adj_sample(si)/g_FD, ...
            ternary_s(g_FD*g_adj_sample(si)>0, 'OK', 'XX'));
    end
end

%% 7. 统计
sign_match = sign(g_FD_sample .* g_adj_sample) > 0;
sign_rate = sum(sign_match) / N_s;
ratios = g_adj_sample ./ g_FD_sample;
valid = abs(g_FD_sample) > 1e-30;
ratios_v = ratios(valid);
cos_theta = dot(g_FD_sample, g_adj_sample) / (norm(g_FD_sample) * norm(g_adj_sample));

fprintf('\n############################################################\n');
fprintf('#  复数 eps_r (5-3j → 3-1j) 逐体素验证结果\n');
fprintf('############################################################\n');
fprintf('#  sign 一致率: %d/%d = %.1f%%\n', sum(sign_match), N_s, 100*sign_rate);
if ~isempty(ratios_v)
    fprintf('#  ratio mean=%.6f median=%.6f CV=%.6f\n', ...
        mean(ratios_v), median(ratios_v), std(ratios_v)/abs(mean(ratios_v)));
    fprintf('#  ratio range: [%.6f, %.6f]\n', min(ratios_v), max(ratios_v));
end
fprintf('#  cos θ = %.6f\n', cos_theta);
if sign_rate > 0.9 && cos_theta > 0.8
    fprintf('#  ★★★ PASS：复数 eps_r 伴随方向正确 ★★★\n');
else
    fprintf('#  ⚠ FAIL 或部分通过\n');
end
fprintf('############################################################\n');

%% 8. 保存
result = struct();
result.N_sample = N_s;
result.g_FD = g_FD_sample;
result.g_adj = g_adj_sample;
result.ratios = ratios;
result.sign_rate = sign_rate;
result.cos_theta = cos_theta;
result.eps_true = '5-3j';
result.eps_init = '3-1j';

save(fullfile(p.dir_result, 'per_voxel_complex_result.mat'), 'result');
fprintf('\n[PVC] 结果已保存\n');

try phys.feature('vec1').set('Je',{'0','0','0'}); catch; end
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try model.param.set('adjoint_mode','1'); catch; end

end

function solve_quiet_c(model, p)
    try model.param.set('freq',num2str(p.freq)); try model.study('std1').feature('freq').set('plist',sprintf('%g[Hz]',p.freq)); catch; end; catch; end
    try model.sol('sol1').clearSolutionData(); catch; end
    try model.sol('sol1').clearSolution(); catch; end
    try model.physics('emw').prop('BackgroundField').set('Eb',[0 0 1]); catch; end
    try model.param.set('adjoint_mode','1'); catch; end
    try model.physics('emw').feature('vec1').set('Je',{'0','0','0'}); catch; end
    try; s1=model.sol('sol1').feature('s1'); try s1.feature('dDirect'); catch; s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso'); end; try s1.feature('fc1').set('linsolver','dDirect'); catch; end; catch; end
    model.sol('sol1').runAll();
end

function s = ternary_s(cond, a, b), if cond, s=a; else, s=b; end; end
