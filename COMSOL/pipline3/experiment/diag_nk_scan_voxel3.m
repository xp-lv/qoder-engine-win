function diag_nk_scan_voxel3()
%DIAG_NK_SCAN_VOXEL3 扫描 N_k=16/32/64 对第3体素虚部梯度 sign 的影响
%   验证: 是否增加 k 方向采样能修复 S 场相位精度

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  N_k 扫描: 第3体素虚部梯度 sign 随 k 方向数的变化\n');
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

%% 2. J_obs（Stratton-Chu，固定真值）
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[E_true, ~, ~] = solve_forward(model, voxel, p);
sf_true = extract_scattered(model, grid_meas);
lc_obs_16 = lightcone_project(grid_meas, sf_true, p);  % 16 k 的 J_obs
J_obs_16 = lc_obs_16.J_obs_perp;

%% 3. 正演 eps_r=3-1j
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);

%% 4. FD 虚部真值（与 N_k 无关，固定参考）
k0_sq = p.k0^2; omega_eps0 = p.omega(1)*p.eps0;
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
vi_target = sample_idx(3);  % 第3体素
v_global = inner_idx(vi_target);
eps_orig = voxel.epsilon_r(v_global);
fprintf('目标体素: vi=%d, r=%.4f, eps_r=%.4f%+.4fi\n\n', vi_target, r_inner(vi_target), real(eps_orig), imag(eps_orig));

% FD delta=0.01
fd_delta = 0.01;
voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)+fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Ep,~,~] = solve_forward(model, voxel, p);
voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)-fd_delta);
update_epsilon(model, voxel, p); solve_quiet(model, p);
[Em,~,~] = solve_forward(model, voxel, p);
voxel.epsilon_r(v_global) = eps_orig;

% 注意：FD 用的 J_hyp 也依赖 N_k，所以需要对每个 N_k 分别算 FD
fprintf('===== FD 对每个 N_k 分别计算（因为 J_hyp 依赖 k 采样）=====\n\n');

%% 5. 对每个 N_k 计算
N_k_list = [16, 32, 64];
E_v = E_total(vi_target, :);
dV_v = voxel.dV(v_global);

fprintf(' N_k | FD_im        | gd_im        | gi_im        | g_adj_im     | ratio    | sign\n');
fprintf('-----|--------------|--------------|--------------|--------------|----------|-----\n');

for ni = 1:length(N_k_list)
    N_k = N_k_list(ni);
    
    % 生成 N_k 个 k 方向
    [k_dir_nk, dOmega_nk] = fibonacci_sphere(N_k);
    k_vec_nk = p.k0 * k_dir_nk;
    
    % J_obs for this N_k (用 Born FT，因为 Stratton-Chu 的 lightcone_project 内部用 p.N_k)
    [~, lc_obs_nk] = born_forward_project(voxel, E_true, p, struct('k_dir',k_dir_nk,'k_vec',k_vec_nk,'dOmega',dOmega_nk,'J_obs_perp',[]));
    J_obs_nk = lc_obs_nk.J_hyp_perp;
    
    % J_hyp for current eps_r
    [~, lc_fwd_nk] = born_forward_project(voxel, E_total, p, struct('k_dir',k_dir_nk,'k_vec',k_vec_nk,'dOmega',dOmega_nk,'J_obs_perp',J_obs_nk));
    Delta_J_nk = J_obs_nk - lc_fwd_nk.J_hyp_perp;
    
    % S 场（反投影）
    pos_v = voxel.pos(inner_idx(vi_target), :)';
    S_v = zeros(1,3);
    for ki = 1:N_k
        phase = exp(1i * (k_vec_nk(ki,:) * pos_v));
        S_v = S_v + dOmega_nk(ki) * Delta_J_nk(ki,:) .* phase;
    end
    
    % F_obs
    F_obs_nk = sum(dOmega_nk .* sum(abs(J_obs_nk).^2, 2));
    if F_obs_nk < p.F_obs_min, F_obs_nk = 1.0; end
    
    % FD for this N_k
    voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)+fd_delta);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Ep_nk,~,~] = solve_forward(model, voxel, p);
    [~,lcp_nk] = born_forward_project(voxel, Ep_nk, p, struct('k_dir',k_dir_nk,'k_vec',k_vec_nk,'dOmega',dOmega_nk,'J_obs_perp',J_obs_nk));
    Fp_nk = sum(dOmega_nk .* sum(abs(J_obs_nk - lcp_nk.J_hyp_perp).^2,2)) / F_obs_nk;
    
    voxel.epsilon_r(v_global) = real(eps_orig) + 1i*(imag(eps_orig)-fd_delta);
    update_epsilon(model, voxel, p); solve_quiet(model, p);
    [Em_nk,~,~] = solve_forward(model, voxel, p);
    [~,lcm_nk] = born_forward_project(voxel, Em_nk, p, struct('k_dir',k_dir_nk,'k_vec',k_vec_nk,'dOmega',dOmega_nk,'J_obs_perp',J_obs_nk));
    Fm_nk = sum(dOmega_nk .* sum(abs(J_obs_nk - lcm_nk.J_hyp_perp).^2,2)) / F_obs_nk;
    voxel.epsilon_r(v_global) = eps_orig;
    
    g_FD_im = (Fp_nk - Fm_nk) / (2*fd_delta);
    
    % 直接项虚部
    ES = sum(conj(E_v) .* S_v);
    gd_im = -2*dV_v*omega_eps0*real(ES)/F_obs_nk;
    
    % 间接项虚部（需要 lambda，这里先用直接项 ratio 分析）
    % 注意: lambda 也依赖 N_k（通过伴随源），需要完整伴随求解
    % 这里先只看直接项 + FD 的关系
    ratio_d = gd_im / max(abs(g_FD_im), 1e-30);
    s_d = '-'; if gd_im * g_FD_im > 0, s_d = 'OK'; end
    
    fprintf(' %3d | %+12.6e | %+12.6e | (需lambda)    | (需gd+gi)     | %8.4f | %s\n', ...
        N_k, g_FD_im, gd_im, ratio_d, s_d);
end

fprintf('\n===== 分析 =====\n');
fprintf('如果直接项 gd_im 的 sign 随 N_k 增加而翻转为正，\n');
fprintf('则证实是 Born 近似的 k 采样分辨率不足导致 S 场相位错误。\n');
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
