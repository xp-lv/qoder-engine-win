function verify_adjoint_layered()
%VERIFY_ADJOINT_LAYERED 分层球体体素级 FD vs 伴随梯度
%
%   eps_r 分布：内球 r<R/2 eps_r=5, 外壳 R/2<r<R eps_r=2
%   选 6 个代表性体素（不同径向位置）做单体素 FD

this_dir = fileparts(mfilename('fullpath'));
cd(fileparts(this_dir));
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  分层球体体素级 FD vs 伴随梯度\n');
fprintf('#  eps_r: 内球(r<R/2)=5, 外壳=2\n');
fprintf('############################################################\n\n');

p = config();

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart: %s\n', ME.message); return;
    end
end

model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

% vec1
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end

% 首次求解
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').runAll(); catch, end

grid = build_measurement_grid(p);
voxel = fem_mesh_utils(model, p, p.a_scatter);
inner = voxel.mask_interior;
inner_pos = voxel.pos(inner, :);
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('[VL] N_inner = %d\n', N_inner);

%% 分层 eps_r 分布
R_scatter = p.a_scatter;
r_v = sqrt(sum(inner_pos.^2, 2));
eps_layered = ones(N_inner, 1) * 2.0;   % 外壳 eps_r=2
eps_layered(r_v < R_scatter/2) = 5.0;   % 内球 eps_r=5
fprintf('[VL] 分层: 内球(r<%.3f) eps_r=5: %d 体素, 外壳 eps_r=2: %d 体素\n', ...
    R_scatter/2, sum(r_v < R_scatter/2), sum(r_v >= R_scatter/2));

pf = p;

%% 真值 J_obs（用均匀 eps_r=5 作为真值，与测试分布不同）
fprintf('[VL] 预计算 J_obs (均匀 eps_r=5)...\n');
voxel.epsilon_r = ones(size(voxel.epsilon_r)) * 1.0;  % 外层空气
voxel.epsilon_r(inner) = 5.0;  % 均匀球 eps_r=5
update_epsilon(model, voxel, p);
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();
sf = extract_scattered(model, grid);
J_obs = lightcone_project(grid, sf, pf).J_obs_perp;

%% 选代表性体素（不同径向位置）
% 选 6 个：2 个内球（eps_r=5），2 个边界附近，2 个外壳（eps_r=2）
inner_voxels = find(r_v < R_scatter/2);   % 内球体素
outer_voxels = find(r_v >= R_scatter/2);  % 外壳体素

% 按距原点距离排序
[~, idx_inner] = sort(r_v(inner_voxels));
[~, idx_outer] = sort(r_v(outer_voxels));

% 选 3 个内球（近中心、中间、接近边界）+ 3 个外壳
sel_local = [ ...
    inner_voxels(idx_inner(round(end*0.25)));  % 内球中部
    inner_voxels(idx_inner(round(end*0.5)));   % 内球中心
    inner_voxels(idx_inner(round(end*0.9)));   % 内球接近边界
    outer_voxels(idx_outer(round(end*0.1)));   % 外壳接近边界
    outer_voxels(idx_outer(round(end*0.5)));   % 外壳中部
    outer_voxels(idx_outer(round(end*0.9)));   % 外壳外部
];
N_sel = length(sel_local);
fprintf('[VL] 选 %d 个代表性体素:\n', N_sel);
for i = 1:N_sel
    vi = sel_local(i);
    fprintf('  体素 %d: r=%.4f, eps_r=%.1f\n', vi, r_v(vi), eps_layered(vi));
end

%% 单体素 FD（delta=0.01）
fprintf('\n[VL] 单体素 FD (delta=0.01)...\n');
fd_delta = 0.01;
g_FD_voxels = zeros(N_sel, 1);

for si = 1:N_sel
    vi = sel_local(si);

    % F(eps+delta)
    eps_pert = eps_layered;
    eps_pert(vi) = eps_pert(vi) + fd_delta;
    voxel.epsilon_r(inner) = eps_pert;
    update_epsilon(model, voxel, p);
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    F_plus = mean(sum(abs(J_obs - lc.J_obs_perp).^2, 2));

    % F(eps-delta)
    eps_pert(vi) = eps_layered(vi) - fd_delta;
    voxel.epsilon_r(inner) = eps_pert;
    update_epsilon(model, voxel, p);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    F_minus = mean(sum(abs(J_obs - lc.J_obs_perp).^2, 2));

    g_FD_voxels(si) = (F_plus - F_minus) / (2 * fd_delta);
    fprintf('  体素 %d (r=%.4f, eps=%.0f): g_FD=%+.6e\n', ...
        vi, r_v(vi), eps_layered(vi), g_FD_voxels(si));
end

%% 伴随梯度
fprintf('\n[VL] 正演 + 伴随 (分层 eps_r)...\n');
voxel.epsilon_r(inner) = eps_layered;
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj = Js + Ms;

[lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
if ~ok, fprintf('[VL] [FAIL]\n'); return; end

% 体素级伴随梯度
k0_sq = pf.k0^2; dV_vec = voxel.dV;
gauss_w = voxel.gauss_w;
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && size(E_gauss,1)==size(voxel.gauss_pos,1) ...
    && size(lambda_gauss,1)==size(voxel.gauss_pos,1);

g_voxel_all = zeros(N_inner, 1);
if use_gauss
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        v_idx = inner_idx(vi);
        gs = 0;
        for gpi = 1:4
            gs = gs + gauss_w(gpi) * real(conj(lambda_gauss(gp(gpi),:)) * E_gauss(gp(gpi),:)');
        end
        g_voxel_all(vi) = -k0_sq * dV_vec(v_idx) * gs;
    end
else
    for vi = 1:N_inner
        v_idx = inner_idx(vi);
        g_voxel_all(vi) = -k0_sq * dV_vec(v_idx) * real(conj(lambda(vi,:)) * E_total(vi,:)');
    end
end

%% 对比
fprintf('\n############################################################\n');
fprintf('#  分层球体体素级结果\n');
fprintf('############################################################\n');
fprintf('#  体素   r       eps_r   g_FD          g_adj          ratio     sign\n');
n_match = 0;
ratios = [];
for si = 1:N_sel
    vi = sel_local(si);
    g_a = g_voxel_all(vi);
    g_f = g_FD_voxels(si);
    if abs(g_f) > 1e-30
        r = g_a / g_f;
    else
        r = NaN;
    end
    s_fd = sign(g_f); s_adj = sign(g_a);
    match = 'Y'; if s_adj ~= s_fd, match = 'N'; end
    if s_adj == s_fd, n_match = n_match + 1; end
    if ~isnan(r), ratios = [ratios; r]; end
    fprintf('#  %3d  %.4f  %.0f    %+.4e   %+.4e   %+.4f   %c%c\n', ...
        vi, r_v(vi), eps_layered(vi), g_f, g_a, r, s_fd>0, match);
end
fprintf('#\n');
fprintf('#  sign 匹配: %d/%d\n', n_match, N_sel);
if ~isempty(ratios)
    fprintf('#  ratio: mean=%.4f, std=%.4f, CV=%.4f\n', ...
        mean(ratios), std(ratios), std(ratios)/abs(mean(ratios)));
end
fprintf('############################################################\n');
end
