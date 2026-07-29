function main_per_voxel(N_sample)
%MAIN_PER_VOXEL 主管线（使用2layer.mph）逐体素FD验证
if nargin < 1, N_sample = 30; end

this_dir = fileparts(mfilename('fullpath'));
cd(this_dir);
addpath('../config','../utils','../core_forward','../core_jobs','../core_jhyp','../core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  主管线逐体素FD验证（使用2layer.mph）\n');
fprintf('############################################################\n\n');

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected'), fprintf('[FAIL]\n'); return; end
end
try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

p = config();
fprintf('[MPV] 模型: %s\n', p.comsol_model_path);
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

voxel = fem_mesh_utils(model, p, p.a_scatter);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);
fprintf('[MPV] N_inner=%d\n', N_inner);

grid = build_measurement_grid(p);

% J_obs
fprintf('[MPV] 预计算 J_obs (eps_r=5)...\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]',p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
sf_obs = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf_obs, p);
J_obs = lc_obs.J_obs_perp; dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs < p.F_obs_min, F_obs = 1.0; end

% 正演 eps_r=3 + 伴随
fprintf('[MPV] 正演 (eps_r=3)...\n');
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
[E_total,~,E_gauss] = solve_forward(model, voxel, p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
F = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[MPV] F=%.6e\n', F);

lc.k_vec = p.k0 * lc.k_dir; lc.J_obs_perp = J_obs; lc.Delta_J_perp = Delta_J;
[Js,Ms,source_pos,~] = build_adjoint_source_fullmaxwell(grid, lc, p);
[lambda,ok_adj,lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms);
if ~ok_adj, fprintf('[FAIL] adjoint\n'); return; end

% 梯度
k0_sq = p.k0^2; dV_vec = voxel.dV;
g_adj_all = zeros(N_inner,1);
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) && size(E_gauss,1)==size(voxel.gauss_pos,1);
if use_gauss
    gw = voxel.gauss_w;
    for vi=1:N_inner
        gp=(4*(vi-1)+1):(4*vi); gs=0;
        for gpi=1:4, gs=gs+gw(gpi)*real(sum(E_gauss(gp(gpi),:).*lambda_gauss(gp(gpi),:))); end
        g_adj_all(vi) = -k0_sq*dV_vec(inner_idx(vi))*gs;
    end
else
    for vi=1:N_inner, g_adj_all(vi)=-k0_sq*dV_vec(inner_idx(vi))*real(sum(E_total(vi,:).*lambda(vi,:))); end
end
g_adj_all = g_adj_all / F_obs;

% 采样FD
r_inner = vecnorm(voxel.pos(inner_idx,:),2,2);
[~,sort_order] = sort(r_inner); step = floor(N_inner/N_sample);
sample_idx = sort_order(1:step:N_inner); sample_idx = sample_idx(1:min(N_sample,length(sample_idx)));
N_s = length(sample_idx);

fprintf('\n[MPV] ===== FD验证 (N=%d) =====\n', N_s);
fd_delta = 0.001;
g_FD_sample = zeros(N_s,1); g_adj_sample = zeros(N_s,1);
for si=1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi); eps_orig = voxel.epsilon_r(v_global);
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    sf_p = extract_scattered(model, grid); lc_p = lightcone_project(grid, sf_p, p);
    F_plus = sum(dOmega .* sum(abs(J_obs-lc_p.J_obs_perp).^2,2)) / F_obs;
    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet(model, p);
    sf_m = extract_scattered(model, grid); lc_m = lightcone_project(grid, sf_m, p);
    F_minus = sum(dOmega .* sum(abs(J_obs-lc_m.J_obs_perp).^2,2)) / F_obs;
    voxel.epsilon_r(v_global) = eps_orig;
    g_FD = (F_plus - F_minus) / (2*fd_delta);
    g_FD_sample(si) = g_FD; g_adj_sample(si) = g_adj_all(vi);
    if mod(si,5)==0 || si==N_s
        fprintf('  [%3d/%3d] r=%.3f: g_FD=%+.2e g_adj=%+.2e ratio=%.4f sign=%s\n', ...
            si,N_s,r_inner(vi),g_FD,g_adj_sample(si),g_adj_sample(si)/g_FD, ...
            ternary_s(g_FD*g_adj_sample(si)>0,'OK','XX'));
    end
end

% 统计
sign_match = sign(g_FD_sample .* g_adj_sample) > 0;
sign_rate = sum(sign_match) / N_s;
ratios = g_adj_sample ./ g_FD_sample;
valid = abs(g_FD_sample) > 1e-30;
ratios_v = ratios(valid);
cos_theta = dot(g_FD_sample, g_adj_sample) / (norm(g_FD_sample) * norm(g_adj_sample));

fprintf('\n############################################################\n');
fprintf('#  主管线逐体素验证结果（2layer.mph）\n');
fprintf('############################################################\n');
fprintf('#  sign一致率: %d/%d = %.1f%%\n', sum(sign_match), N_s, 100*sign_rate);
if ~isempty(ratios_v)
    fprintf('#  ratio mean=%.6f CV=%.6f\n', mean(ratios_v), std(ratios_v)/abs(mean(ratios_v)));
end
fprintf('#  cos θ = %.6f\n', cos_theta);
if sign_rate > 0.9 && cos_theta > 0.8
    fprintf('#  ★★★ PASS ★★★\n');
else
    fprintf('#  ⚠ FAIL\n');
end
fprintf('############################################################\n');
end

function solve_quiet(model, p)
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
