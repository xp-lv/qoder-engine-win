function diag_voxel3_im_decompose(which_voxel)
%DIAG_VOXEL3_IM_DECOMPOSE 拆解第3体素虚部梯度的各输入量和贡献
%   逐步打印 E, S, lambda, ES, EL 及各梯度分量

if nargin < 1, which_voxel = 3; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  梯度输入量拆解诊断: 第%d体素\n', which_voxel);
fprintf('############################################################\n\n');

%% 1. 初始化
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

%% 3. 正演 eps_r=3-1j
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
[~, lc_fwd] = born_forward_project(voxel, E_total, p, lc_obs);
Delta_J = J_obs - lc_fwd.J_hyp_perp;

%% 4. 定位目标体素
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
vi_target = sample_idx(which_voxel);
v_global = inner_idx(vi_target);
eps_orig = voxel.epsilon_r(v_global);

%% 5. 伴随源 + 求解
lc_fwd.Delta_J_perp = Delta_J;
lc_fwd.J_obs_perp = J_obs;
[f_adj, S_field, ~] = build_adjoint_source_volume(voxel, lc_fwd, p);
source_pos_vol = voxel.pos(inner_idx, :);
[lambda, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos_vol);
if ~ok_adj, fprintf('[DIAG] [FAIL] adjoint\n'); return; end

%% 6. 拆解各输入量
k0_sq = p.k0^2; dV_v = voxel.dV(v_global);
omega_eps0 = p.omega(1)*p.eps0;

E_v = E_total(vi_target, :);
S_v = S_field(vi_target, :);
L_v = lambda(vi_target, :);
L_c = conj(L_v);  % bilinear 配对

fprintf('===== 原始输入量 (体素 %d, r=%.4f, eps_r=%.4f%+.4fi) =====\n\n', ...
    vi_target, r_inner(vi_target), real(eps_orig), imag(eps_orig));

fprintf('E (正演总场):\n');
for d=1:3
    fprintf('  E[%d] = %+.6e %+.6ei  |E|=%.6e  arg=%.4f rad\n', ...
        d, real(E_v(d)), imag(E_v(d)), abs(E_v(d)), angle(E_v(d)));
end

fprintf('\nS (反投影残差场):\n');
for d=1:3
    fprintf('  S[%d] = %+.6e %+.6ei  |S|=%.6e  arg=%.4f rad\n', ...
        d, real(S_v(d)), imag(S_v(d)), abs(S_v(d)), angle(S_v(d)));
end

fprintf('\nlambda (COMSOL bilinear 伴随解):\n');
for d=1:3
    fprintf('  λ[%d] = %+.6e %+.6ei  |λ|=%.6e  arg=%.4f rad\n', ...
        d, real(L_v(d)), imag(L_v(d)), abs(L_v(d)), angle(L_v(d)));
end

fprintf('\nconj(lambda) (bilinear 配对后):\n');
for d=1:3
    fprintf('  conj(λ)[%d] = %+.6e %+.6ei\n', ...
        d, real(L_c(d)), imag(L_c(d)));
end

%% 7. 内积计算
% --- 质心取值 ---
ES = sum(conj(E_v) .* S_v);  % 直接项: Hermitian conj(E)·S
EL = sum(conj(E_v) .* L_c);  % 间接项: conj(E)·conj(λ) = conj(E·λ) (bilinear)

fprintf('\n===== 内积 (质心取值) =====\n');
fprintf('  ES = conj(E)·S = %+.6e %+.6ei\n', real(ES), imag(ES));
fprintf('    Re(ES) = %.6e   Im(ES) = %.6e\n', real(ES), imag(ES));
fprintf('\n  EL = conj(E)·conj(λ) = conj(E·λ) = %+.6e %+.6ei\n', real(EL), imag(EL));
fprintf('    Re(EL) = %.6e   Im(EL) = %.6e\n', real(EL), imag(EL));

% --- Gauss 积分（4 点） ---
ES_gauss = 0; EL_gauss = 0; has_gauss = false;
if ~isempty(E_gauss) && ~isempty(lambda_gauss) && ~isempty(voxel.gauss_pos)
    inner_idx_list = find(inner);
    % 找目标体素在 inner 序列中的位置
    vi_in_inner = find(inner_idx_list == inner_idx(vi_target), 1);
    if ~isempty(vi_in_inner)
        gp_range = (4*(vi_in_inner-1)+1):(4*vi_in_inner);
        gw = voxel.gauss_w;
        for gpi = 1:4
            Eg = E_gauss(gp_range(gpi), :);
            Lg = conj(lambda_gauss(gp_range(gpi), :));  % conj(λ) for bilinear
            % S 在 Gauss 点的值（从 Born FT 反投影计算）
            Sg = zeros(1, 3);
            pos_g = voxel.gauss_pos(gp_range(gpi), :)';
            for ki = 1:size(Delta_J, 1)
                phase = exp(1i * (lc_fwd.k_vec(ki,:) * pos_g));
                Sg = Sg + lc_fwd.dOmega(ki) * Delta_J(ki,:) .* phase;
            end
            ES_gauss = ES_gauss + gw(gpi) * sum(conj(Eg) .* Sg);
            EL_gauss = EL_gauss + gw(gpi) * sum(conj(Eg) .* Lg);
        end
        has_gauss = true;
        fprintf('\n===== 内积 (4-pt Gauss 积分) =====\n');
        fprintf('  ES_gauss = %+.6e %+.6ei\n', real(ES_gauss), imag(ES_gauss));
        fprintf('    Re = %.6e   Im = %.6e\n', real(ES_gauss), imag(ES_gauss));
        fprintf('\n  EL_gauss = %+.6e %+.6ei\n', real(EL_gauss), imag(EL_gauss));
        fprintf('    Re = %.6e   Im = %.6e\n', real(EL_gauss), imag(EL_gauss));
        fprintf('\n  ★ 质心 vs Gauss 对比:\n');
        fprintf('    Re(ES): 质心=%+.4e  Gauss=%+.4e  差异=%+.2f%%\n', ...
            real(ES), real(ES_gauss), (real(ES_gauss)-real(ES))/max(abs(real(ES)),1e-30)*100);
        fprintf('    Re(EL): 质心=%+.4e  Gauss=%+.4e  差异=%+.2f%%\n', ...
            real(EL), real(EL_gauss), (real(EL_gauss)-real(EL))/max(abs(real(EL)),1e-30)*100);
    end
end

%% 8. 梯度四分量
fprintf('\n===== 梯度四分量 =====\n');
fprintf('  dV=%.6e, ωε₀=%.6e, k₀²=%.6e, F_obs=%.6e\n\n', dV_v, omega_eps0, k0_sq, F_obs);

% --- 质心取值 ---
gd_re = +2*dV_v*omega_eps0*imag(ES)/F_obs;
gd_im = -2*dV_v*omega_eps0*real(ES)/F_obs;
gi_re = -k0_sq*dV_v*real(EL);
gi_im = -k0_sq*dV_v*imag(EL);
g_re = gd_re + gi_re;
g_im = gd_im + gi_im;

fprintf('  [质心] 直接项: gd_re=%+.4e gd_im=%+.4e\n', gd_re, gd_im);
fprintf('  [质心] 间接项: gi_re=%+.4e gi_im=%+.4e\n', gi_re, gi_im);
fprintf('  [质心] 合计:   g_re=%+.4e g_im=%+.4e\n\n', g_re, g_im);

% --- Gauss 积分 ---
if has_gauss
    gd_re_g = +2*dV_v*omega_eps0*imag(ES_gauss)/F_obs;
    gd_im_g = -2*dV_v*omega_eps0*real(ES_gauss)/F_obs;
    gi_re_g = -k0_sq*dV_v*real(EL_gauss);
    gi_im_g = -k0_sq*dV_v*imag(EL_gauss);
    g_re_g = gd_re_g + gi_re_g;
    g_im_g = gd_im_g + gi_im_g;
    
    fprintf('  [Gauss] 直接项: gd_re=%+.4e gd_im=%+.4e\n', gd_re_g, gd_im_g);
    fprintf('  [Gauss] 间接项: gi_re=%+.4e gi_im=%+.4e\n', gi_re_g, gi_im_g);
    fprintf('  [Gauss] 合计:   g_re=%+.4e g_im=%+.4e\n\n', g_re_g, g_im_g);
    fprintf('  ★ 虚部 sign 对比: 质心=%s  Gauss=%s\n', ...
        ternary_s(g_im>0,'正','负'), ternary_s(g_im_g>0,'正','负'));
end

%% 9. FD 对比
fprintf('\n===== FD 对比 (δ=0.01) =====\n');
fd_delta = 0.01;

% FD 虚部
voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)+fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Ep,~,~] = solve_forward(model, voxel, p);
[~,lcp] = born_forward_project(voxel, Ep, p, lc_obs);
Fp = sum(dOmega .* sum(abs(J_obs - lcp.J_hyp_perp).^2,2)) / F_obs;

voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)-fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Em,~,~] = solve_forward(model, voxel, p);
[~,lcm] = born_forward_project(voxel, Em, p, lc_obs);
Fm = sum(dOmega .* sum(abs(J_obs - lcm.J_hyp_perp).^2,2)) / F_obs;
voxel.epsilon_r(v_global) = eps_orig;

g_FD_im = (Fp - Fm)/(2*fd_delta);
fprintf('  FD_im = (F+ - F-)/(2δ) = (%.6e - %.6e)/%.4f = %+.6e\n', Fp, Fm, 2*fd_delta, g_FD_im);
fprintf('  adj_im = %+.6e\n', g_im);
fprintf('  ratio = %.4f  sign=%s\n', g_im/g_FD_im, ternary_s(g_FD_im*g_im>0,'OK','XX'));

fprintf('\n===== 诊断分析 =====\n');
fprintf('  直接项虚部 gd_im = %+.6e (sign=%s)\n', gd_im, ternary_s(gd_im*g_FD_im>0,'与FD同号','与FD反号'));
fprintf('  间接项虚部 gi_im = %+.6e (sign=%s)\n', gi_im, ternary_s(gi_im*g_FD_im>0,'与FD同号','与FD反号'));
if sign(gi_im) ~= sign(g_FD_im)
    fprintf('\n  ★ 间接项 gi_im 方向错误！这是 sign 反转的根因。\n');
    fprintf('    gi_im = %+.6e, FD = %+.6e\n', gi_im, g_FD_im);
    fprintf('    间接项绝对值远大于直接项（|gi|/|gd|=%.2f），主导了总梯度方向\n', abs(gi_im)/abs(gd_im));
elseif sign(gd_im) ~= sign(g_FD_im)
    fprintf('\n  ★ 直接项 gd_im 方向错误！\n');
else
    fprintf('\n  两项均与 FD 同号，但合计仍反号 → 数值精度问题\n');
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

function s = ternary_s(cond, a, b), if cond, s=a; else, s=b; end, end
