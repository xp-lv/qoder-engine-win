function result = compare_kb_gradient(N_sample)
%COMPARE_KB_GRADIENT 用 K\b 反解方法计算精确梯度
%
%   方法：
%     1. 正演求解后导出 K, b（载荷向量）
%     2. MATLAB 中 u = K \ b（验证与 COMSOL 解一致）
%     3. 对采样体素 v：
%        a. 微扰 ε_v ± δ
%        b. 重新组装 K_plus, K_minus（mphmatrix + initmethod='sol'）
%        c. dK_v = (K_plus - K_minus) / (2δ)
%        d. 精确梯度 g(v) = Re[λ^T · dK_v · u]（λ = K\b_adj）
%     4. 与 FD 和 mphinterp 对比

if nargin < 1, N_sample = 10; end

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  K\\b 精确梯度对比\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[KB] [FAIL]\n'); return; end
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

%% 2. J_obs
fprintf('[KB] 预计算 J_obs...\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
sf_obs = extract_scattered(model, grid_meas);
lc_obs = lightcone_project(grid_meas, sf_obs, p);
J_obs = lc_obs.J_obs_perp; dOmega = lc_obs.dOmega;
F_obs = sum(dOmega .* sum(abs(J_obs).^2,2)); if F_obs<p.F_obs_min, F_obs=1.0; end

%% 3. 正演 eps_r=3 + 导出 K, b
fprintf('[KB] 正演 + 导出 K, b...\n');
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try model.param.set('adjoint_mode','1'); catch; end
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
try; s1=model.sol('sol1').feature('s1'); try s1.feature('dDirect'); catch; s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso'); end; try s1.feature('fc1').set('linsolver','dDirect'); catch; end; catch; end
model.sol('sol1').runAll();

% 导出 K 和 b（载荷向量 L）
fprintf('[KB] 导出 K, L...\n');
try
    str_fwd = mphmatrix(model, 'sol1', 'out', {'K', 'L'});
    K_base = str_fwd.K;
    b_fwd = str_fwd.L;  % 载荷向量
    N_dof = size(K_base, 1);
    fprintf('[KB] K: %dx%d nnz=%d\n', N_dof, N_dof, nnz(K_base));
    fprintf('[KB] L: %dx1 |mean|=%.4e\n', length(b_fwd), mean(abs(b_fwd)));
    
    % MATLAB 反解 u = K \ b
    u_fwd = K_base \ b_fwd;
    fprintf('[KB] u_fwd = K\\L: |mean|=%.4e\n', mean(abs(u_fwd)));
    
    % 验证：K·u 应该等于 b
    residual = norm(K_base * u_fwd - b_fwd) / norm(b_fwd);
    fprintf('[KB] K·u - b 残差 = %.2e\n', residual);
    have_K = true;
catch ME
    fprintf('[KB] [FAIL] K/L 导出: %s\n', ME.message);
    have_K = false;
end

% 同时获取 mphinterp 场
[E_total, ~, E_gauss] = solve_forward(model, voxel, p);
sf = extract_scattered(model, grid_meas);
lc = lightcone_project(grid_meas, sf, p);
Delta_J = J_obs - lc.J_obs_perp;
F_data = sum(dOmega .* sum(abs(Delta_J).^2,2)) / F_obs;
fprintf('[KB] F_data=%.6e\n', F_data);

%% 4. 伴随求解 + 导出 K_adj, b_adj
fprintf('[KB] 伴随求解...\n');
lc.k_vec = p.k0 * lc.k_dir; lc.J_obs_perp = J_obs; lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid_meas, lc, p);
[lambda_interp, ok_adj, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms, true);
if ~ok_adj, fprintf('[KB] [FAIL] adjoint\n'); return; end

if have_K
    % 导出伴随态的 K 和 b
    fprintf('[KB] 导出 K_adj, L_adj...\n');
    try
        str_adj = mphmatrix(model, 'sol1', 'out', {'K', 'L'});
        K_adj = str_adj.K;
        b_adj = str_adj.L;
        fprintf('[KB] K_adj: %dx%d nnz=%d\n', size(K_adj,1), size(K_adj,2), nnz(K_adj));
        fprintf('[KB] L_adj: |mean|=%.4e\n', mean(abs(b_adj)));
        
        % MATLAB 反解 lambda = K_adj \ b_adj
        lambda_dof = K_adj \ b_adj;
        lambda_dof = conj(lambda_dof);  % 双源路径 conj 约定
        fprintf('[KB] lambda_dof: |mean|=%.4e\n', mean(abs(lambda_dof)));
        
        % 验证 K_adj 是否与 K_base 一致（同一个 K，因为 epsilon_r 没变）
        if size(K_adj,1) == size(K_base,1)
            K_diff = norm(K_adj - K_base) / norm(K_base);
            fprintf('[KB] ||K_adj - K_base|| / ||K_base|| = %.2e\n', K_diff);
        end
        have_K_adj = true;
    catch ME
        fprintf('[KB] [WARN] K_adj 导出失败: %s\n', ME.message);
        have_K_adj = false;
    end
else
    have_K_adj = false;
end

% 恢复模型
try phys.feature('vec1').set('Je',{'0','0','0'}); catch; end
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try model.param.set('adjoint_mode','1'); catch; end
try phys.feature().remove('sc_adj'); catch; end
try phys.feature().remove('ms_adj'); catch; end

%% 5. mphinterp 梯度
k0_sq = p.k0^2; dV_vec = voxel.dV;
g_mphinterp = zeros(N_inner, 1);
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) && size(E_gauss,1)==size(voxel.gauss_pos,1);
if use_gauss
    gw = voxel.gauss_w;
    for vi=1:N_inner
        gp=(4*(vi-1)+1):(4*vi); gs=0;
        for gpi=1:4, gs=gs+gw(gpi)*real(sum(E_gauss(gp(gpi),:).*lambda_gauss(gp(gpi),:))); end
        g_mphinterp(vi) = -k0_sq*dV_vec(inner_idx(vi))*gs;
    end
else
    for vi=1:N_inner, g_mphinterp(vi)=-k0_sq*dV_vec(inner_idx(vi))*real(sum(E_total(vi,:).*lambda_interp(vi,:))); end
end
g_mphinterp = g_mphinterp / F_obs;

%% 6. 采样 + 三路径对比
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / N_sample);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(N_sample, length(sample_idx)));
N_s = length(sample_idx);

fprintf('\n[KB] ===== 三路径对比 (N=%d) =====\n', N_s);
fd_delta = 0.001;
g_FD = zeros(N_s,1); g_mph = zeros(N_s,1); g_kb = zeros(N_s,1);

for si = 1:N_s
    vi = sample_idx(si); v_global = inner_idx(vi); eps_orig = voxel.epsilon_r(v_global);
    
    % === 路径1: FD ===
    voxel.epsilon_r(v_global) = eps_orig + fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_kb(model, p);
    sf_p = extract_scattered(model, grid_meas); lc_p = lightcone_project(grid_meas, sf_p, p);
    F_plus = sum(dOmega .* sum(abs(J_obs-lc_p.J_obs_perp).^2,2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig - fd_delta;
    update_epsilon(model, voxel, p);
    solve_quiet_kb(model, p);
    sf_m = extract_scattered(model, grid_meas); lc_m = lightcone_project(grid_meas, sf_m, p);
    F_minus = sum(dOmega .* sum(abs(J_obs-lc_m.J_obs_perp).^2,2)) / F_obs;
    
    voxel.epsilon_r(v_global) = eps_orig;
    g_FD(si) = (F_plus - F_minus) / (2*fd_delta);
    g_mph(si) = g_mphinterp(vi);
    
    % === 路径3: K\b 精确梯度 ===
    if have_K && have_K_adj
        try
            % 微扰 +δ：重新组装 K_plus
            voxel.epsilon_r(v_global) = eps_orig + fd_delta;
            update_epsilon(model, voxel, p);
            try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
            try model.param.set('adjoint_mode','1'); catch; end
            try model.sol('sol1').clearSolutionData(); catch; end
            try model.sol('sol1').clearSolution(); catch; end
            model.sol('sol1').runAll();
            str_p = mphmatrix(model, 'sol1', 'out', {'K'});
            K_plus = str_p.K;
            
            % 微扰 -δ：重新组装 K_minus
            voxel.epsilon_r(v_global) = eps_orig - fd_delta;
            update_epsilon(model, voxel, p);
            try model.sol('sol1').clearSolutionData(); catch; end
            try model.sol('sol1').clearSolution(); catch; end
            model.sol('sol1').runAll();
            str_m = mphmatrix(model, 'sol1', 'out', {'K'});
            K_minus = str_m.K;
            
            % 恢复
            voxel.epsilon_r(v_global) = eps_orig;
            
            % dK = (K_plus - K_minus) / (2*delta)
            dK = (K_plus - K_minus) / (2 * fd_delta);
            
            % 精确梯度 = Re[lambda^T · dK · u]
            % 注意 lambda_dof 已取 conj
            g_kb(si) = real(lambda_dof' * dK * u_fwd) / F_obs;
            
        catch ME
            fprintf('[KB] K\\b 计算失败 (体素 %d): %s\n', si, ME.message);
            g_kb(si) = NaN;
        end
    else
        g_kb(si) = NaN;
    end
    
    if mod(si,3)==0 || si==N_s
        r_mph = g_mph(si) / max(abs(g_FD(si)),1e-30);
        r_kb = g_kb(si) / max(abs(g_FD(si)),1e-30);
        s_mph = ternary_s(g_FD(si)*g_mph(si)>0,'OK','XX');
        s_kb = ternary_s(~isnan(g_kb(si)) && g_FD(si)*g_kb(si)>0,'OK','XX');
        fprintf('  [%2d/%d] r=%.3f:\n    g_FD =%+.4e\n    g_mph=%+.4e (ratio=%.4f sign=%s)\n    g_kb =%+.4e (ratio=%.4f sign=%s)\n', ...
            si, N_s, r_inner(vi), g_FD(si), g_mph(si), r_mph, s_mph, g_kb(si), r_kb, s_kb);
    end
end

%% 7. 统计
fprintf('\n############################################################\n');
fprintf('#  三路径对比统计\n');
fprintf('############################################################\n');

valid = abs(g_FD) > 1e-30;

% mphinterp
sign_mph = sum(sign(g_FD(valid).*g_mph(valid))>0);
ratios_mph = g_mph(valid)./g_FD(valid);
fprintf('mphinterp: sign=%d/%d ratio=%.6f CV=%.4f\n', sign_mph, sum(valid), mean(ratios_mph), std(ratios_mph)/abs(mean(ratios_mph)));

% K\b
valid_kb = valid & ~isnan(g_kb);
if sum(valid_kb) > 0
    sign_kb = sum(sign(g_FD(valid_kb).*g_kb(valid_kb))>0);
    ratios_kb = g_kb(valid_kb)./g_FD(valid_kb);
    fprintf('K\\b:      sign=%d/%d ratio=%.6f CV=%.4f\n', sign_kb, sum(valid_kb), mean(ratios_kb), std(ratios_kb)/abs(mean(ratios_kb)));
    
    if abs(mean(ratios_kb) - 1) < 0.1
        fprintf('\n  ★★★ K\\b ratio ≈ 1！偏差来自 mphinterp + Qv 近似 ★★★\n');
    elseif abs(mean(ratios_kb)) > abs(mean(ratios_mph)) * 10
        fprintf('\n  K\\b ratio 比 mphinterp 大 10x+，但未到 1\n');
    else
        fprintf('\n  K\\b ratio 与 mphinterp 接近\n');
    end
else
    fprintf('K\\b: 无有效数据\n');
end
fprintf('############################################################\n');

result = struct('g_FD',g_FD,'g_mph',g_mph,'g_kb',g_kb,'r_inner',r_inner(sample_idx));
save(fullfile(p.dir_result,'compare_kb.mat'),'result');
fprintf('\n[KB] 结果已保存\n');

end

function solve_quiet_kb(model, p)
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
