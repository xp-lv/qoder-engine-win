function diag_voxel4_im_fdsteps(which_voxel)
%DIAG_VOXEL4_IM_FDSTEPS 诊断指定体素虚部 FD 在不同步长下的可靠性
%   diag_voxel4_im_fdsteps(2)  % 测试第2个体素
%   测试 fd_delta = [0.1, 0.01, 0.001] 三步长的 central FD
if nargin < 1, which_voxel = 3; end  % 默认第3个体素（尚未测过）

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  诊断: 第%d个体素 虚部 FD 步长敏感性\n', which_voxel);
fprintf('############################################################\n\n');

%% 1. 初始化（复用验证脚本的初始化）
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[DIAG] [FAIL] mphstart\n'); return; end
end
try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

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
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);

%% 2. J_obs（Stratton-Chu）
fprintf('[DIAG] 预计算 J_obs (eps_r=5-3j, Stratton-Chu)...\n');
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

[E_true, ~, ~] = solve_forward(model, voxel, p);
sf_true = extract_scattered(model, grid_meas);
lc_obs = lightcone_project(grid_meas, sf_true, p);
J_obs = lc_obs.J_obs_perp;
dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end
fprintf('[DIAG] F_obs=%.4e\n', F_obs);

%% 3. 正演 eps_r=3-1j（非均匀梯度）
fprintf('[DIAG] 正演 (eps_r=3-1j 非均匀梯度)...\n');
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;

%% 4. 定位目标体素（按 r 排序后取第 which_voxel 个）
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
vi_target = sample_idx(which_voxel);  % 第 which_voxel 个体素
v_global = inner_idx(vi_target);
eps_orig = voxel.epsilon_r(v_global);
fprintf('\n[DIAG] 目标体素: vi=%d, r=%.4f, eps_r=%.4f%+.4fi\n', ...
    vi_target, r_inner(vi_target), real(eps_orig), imag(eps_orig));

%% 5. 多步长 FD（实部 + 虚部双分量）
% 实部步长 [1, 0.01]，虚部步长 [1, 0.01]
fd_re  = [1, 0.01];
fd_im  = [1, 0.01];
g_FD_re = zeros(size(fd_re));
g_FD_im = zeros(size(fd_im));

% 基准 F (eps_orig)
update_epsilon(model, voxel, p);
solve_quiet(model, p);
[E0,~,~] = solve_forward(model, voxel, p);
[~, lc0] = born_forward_project(voxel, E0, p, lc_obs);
F0 = sum(dOmega .* sum(abs(J_obs - lc0.J_hyp_perp).^2,2)) / F_obs;
fprintf('[DIAG] 基准 F0=%.6e (eps_r=%.4f%+.4fi)\n\n', F0, real(eps_orig), imag(eps_orig));

fprintf('========== 实部 ε_re FD ==========\n');
for di = 1:length(fd_re)
    delta = fd_re(di);
    % +delta (实部)
    voxel.epsilon_r(v_global) = (real(eps_orig)+delta) + 1i*imag(eps_orig);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Ep,~,~] = solve_forward(model, voxel, p);
    [~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
    Fp = sum(dOmega .* sum(abs(J_obs - lcp.J_hyp_perp).^2,2)) / F_obs;
    % -delta (实部)
    voxel.epsilon_r(v_global) = (real(eps_orig)-delta) + 1i*imag(eps_orig);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Em,~,~] = solve_forward(model, voxel, p);
    [~,lcm] = born_forward_project(voxel, Em, p, lc_obs);
    Fm = sum(dOmega .* sum(abs(J_obs - lcm.J_hyp_perp).^2,2)) / F_obs;
    voxel.epsilon_r(v_global) = eps_orig;
    g_FD_re(di) = (Fp - Fm) / (2*delta);
    fwd = (Fp-F0)/delta; bwd = (F0-Fm)/delta;
    asym = abs(fwd-bwd)/max(abs(g_FD_re(di)),1e-30)*100;
    fprintf('  δ=%.2f: F+=%.6e F0=%.6e F-=%.6e | central=%+.6e asym=%.4f%%\n', ...
        delta, Fp, F0, Fm, g_FD_re(di), asym);
end

fprintf('\n========== 虚部 ε_im FD ==========\n');
for di = 1:length(fd_im)
    delta = fd_im(di);
    % +delta (虚部)
    voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)+delta);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Ep,~,~] = solve_forward(model, voxel, p);
    [~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
    Fp = sum(dOmega .* sum(abs(J_obs - lcp.J_hyp_perp).^2,2)) / F_obs;
    % -delta (虚部)
    voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)-delta);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Em,~,~] = solve_forward(model, voxel, p);
    [~,lcm] = born_forward_project(voxel, Em, p, lc_obs);
    Fm = sum(dOmega .* sum(abs(J_obs - lcm.J_hyp_perp).^2,2)) / F_obs;
    voxel.epsilon_r(v_global) = eps_orig;
    g_FD_im(di) = (Fp - Fm) / (2*delta);
    fwd = (Fp-F0)/delta; bwd = (F0-Fm)/delta;
    asym = abs(fwd-bwd)/max(abs(g_FD_im(di)),1e-30)*100;
    fprintf('  δ=%.3f: F+=%.6e F0=%.6e F-=%.6e | central=%+.6e asym=%.4f%%\n', ...
        delta, Fp, F0, Fm, g_FD_im(di), asym);
end

%% 6. 伴随梯度（参考值）
fprintf('\n[DIAG] 计算伴随梯度...\n');
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);
[lambda, ok_adj, ~] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[DIAG] [FAIL] adjoint\n'); return; end

% 复数梯度四分量（bilinear）
lambda_c = conj(lambda(vi_target,:));
EL = sum(conj(E_total(vi_target,:)).*lambda_c);
k0_sq = p.k0^2; dV_v = voxel.dV(v_global);
omega_eps0 = p.omega(1)*p.eps0;
ES = sum(conj(E_total(vi_target,:)).*S_field(vi_target,:));

gd_re = +2*dV_v*omega_eps0*imag(ES)/F_obs;
gd_im = -2*dV_v*omega_eps0*real(ES)/F_obs;
gi_re = -k0_sq*dV_v*real(EL);
gi_im = -k0_sq*dV_v*imag(EL);
g_adj_re = gd_re + gi_re;
g_adj_im = gd_im + gi_im;

fprintf('\n############################################################\n');
fprintf('#  第%d体素(r=%.4f) 实部+虚部梯度对比\n', which_voxel, r_inner(vi_target));
fprintf('############################################################\n');
fprintf('  伴随梯度: g_re=%+.6e (gd=%+.4e gi=%+.4e)\n', g_adj_re, gd_re, gi_re);
fprintf('            g_im=%+.6e (gd=%+.4e gi=%+.4e)\n\n', g_adj_im, gd_im, gi_im);

fprintf('  --- 实部 ε_re ---\n');
fprintf('  步长      central-FD        ratio(adj/FD)   sign\n');
for di=1:length(fd_re)
    r = g_adj_re / g_FD_re(di);
    s = ternary_s(g_FD_re(di)*g_adj_re>0,'OK','XX');
    fprintf('  %.2f     %+.6e   %+.4f       %s\n', fd_re(di), g_FD_re(di), r, s);
end
fprintf('\n  --- 虚部 ε_im ---\n');
fprintf('  步长      central-FD        ratio(adj/FD)   sign\n');
for di=1:length(fd_im)
    r = g_adj_im / g_FD_im(di);
    s = ternary_s(g_FD_im(di)*g_adj_im>0,'OK','XX');
    fprintf('  %.3f    %+.6e   %+.4f       %s\n', fd_im(di), g_FD_im(di), r, s);
end
fprintf('############################################################\n');

%% 7. 判断 FD 可靠性
% 实部
rr = g_adj_re ./ g_FD_re;
sc_re = all(sign(rr)==sign(rr(1)));
cv_re = abs(rr(end)/rr(1));
% 虚部
ri = g_adj_im ./ g_FD_im;
sc_im = all(sign(ri)==sign(ri(1)));
cv_im = abs(ri(end)/ri(1));
fprintf('\n[DIAG] FD 可靠性判断:\n');
fprintf('  实部: sign一致=%s  小/大步长ratio=%.4f\n', string(sc_re), cv_re);
fprintf('  虚部: sign一致=%s  小/大步长ratio=%.4f\n', string(sc_im), cv_im);
if sc_re && sc_im
    fprintf('  ★ 实部+虚部 FD 均可靠，伴随梯度 sign 可信\n');
else
    fprintf('  ⚠ 存在不可靠分量\n');
end

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

function s = ternary_s(cond, a, b), if cond, s=a; else, s=b; end, end
