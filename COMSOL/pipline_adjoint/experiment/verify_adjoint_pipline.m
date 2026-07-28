function verify_adjoint_pipline()
%VERIFY_ADJOINT_PIPLINE pipline_adjoint 完整验证
%
%   1. 构建极简模型
%   2. 单参数 eps_r FD（3个步长，验证收敛）
%   3. 正演 + 伴随求解（修正后的 solve_adjoint）
%   4. 逐体素 sign 对比

this_dir = fileparts(mfilename('fullpath'));
cd(fileparts(this_dir));  % cd 到 pipline_adjoint 根目录
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  pipline_adjoint 完整验证\n');
fprintf('#  极简模型 + 单参数 eps_r + 体素级 FD\n');
fprintf('#  solve_adjoint: f_adj/(i*omega*mu0) 直接注入\n');
fprintf('#  梯度公式: -k0^2*dV*Re(conj(lambda)*E)\n');
fprintf('############################################################\n\n');

p = config();

%% 连接 COMSOL
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart: %s\n', ME.message); return;
    end
end

% 直接加载 mph（包含网格+求解器）
fprintf('[VP] 加载 2layer.mph...\n');
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

% 确保 vec1 (ExternalCurrentDensity) 存在
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
    fprintf('[VP] vec1 已创建\n');
end

% 确保 adjoint_mode 参数
try model.param.set('adjoint_mode', '1'); catch, end

% 查找可用的 study/sol
fprintf('[VP] 可用 studies: ');
tags_s = model.study().tags();
for ti = 1:length(tags_s)
    fprintf('%s ', char(tags_s(ti)));
end
fprintf('\n');

fprintf('[VP] 可用 solvers: ');
tags_sol = model.sol().tags();
for ti = 1:length(tags_sol)
    fprintf('%s ', char(tags_sol(ti)));
end
fprintf('\n');

% 用第一个可用的 sol
sol_tag = char(tags_sol(1));
fprintf('[VP] 使用 sol: %s\n', sol_tag);
try model.sol(sol_tag).runAll(); catch, end
fprintf('[VP] 首次求解完成\n');

%% 提取网格
grid = build_measurement_grid(p);
voxel = fem_mesh_utils(model, p, p.a_scatter);
inner = voxel.mask_interior;
inner_pos = voxel.pos(inner, :);
inner_idx = find(inner);
N_inner = sum(inner);
fprintf('[VP] N_inner = %d\n', N_inner);

%% 真值 J_obs
fprintf('[VP] 预计算 J_obs (eps_r=%.1f)...\n', p.eps_r_true);
voxel.epsilon_r(inner) = p.eps_r_true;
update_epsilon(model, voxel, p);
pf = p; pf.freq = p.freq; pf.omega = p.omega; pf.k0 = p.k0; pf.lambda = p.lambda;
model.param.set('freq', num2str(pf.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', pf.freq)); catch, end
try model.sol(sol_tag).clearSolutionData(); catch, end
try model.sol(sol_tag).clearSolution(); catch, end
model.sol(sol_tag).runAll();
fprintf('[VP] J_obs 求解完成\n');
sf = extract_scattered(model, grid);
lc_obs = lightcone_project(grid, sf, pf);
J_obs = lc_obs.J_obs_perp;
% ★ ⚠5 修复：预计算 F_obs（定义 A 的归一化因子）
F_obs_vp = sum(lc_obs.dOmega .* sum(abs(J_obs).^2, 2));
if F_obs_vp < p.F_obs_min, F_obs_vp = 1.0; end
fprintf('[VP] F_obs = %.6e
', F_obs_vp);

%% 单参数 eps_r FD
fprintf('\n[VP] 单参数 eps_r FD...\n');
eps_r_test = 4.0;  % 测试点
fd_deltas = [0.1, 0.01, 0.001];
N_delta = length(fd_deltas);
g_FD = zeros(N_delta, 1);

for di = 1:N_delta
    delta = fd_deltas(di);
    voxel.epsilon_r(inner) = eps_r_test + delta;
    update_epsilon(model, voxel, p);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    F_plus = sum(lc.dOmega .* sum(abs(dJ).^2, 2)) / F_obs_vp;  % ★ ⚠5 修复：定义 A

    voxel.epsilon_r(inner) = eps_r_test - delta;
    update_epsilon(model, voxel, p);
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    F_minus = sum(lc.dOmega .* sum(abs(dJ).^2, 2)) / F_obs_vp;  % ★ ⚠5 修复：定义 A

    g_FD(di) = (F_plus - F_minus) / (2 * delta);
    fprintf('  delta=%.0e: F+=%.6e, F-=%.6e, g_FD=%.6e\n', delta, F_plus, F_minus, g_FD(di));
end

% 验证收敛
fprintf('\nFD 收敛性:\n');
for di = 1:N_delta
    fprintf('  delta=%.0e: g_FD=%.8e\n', fd_deltas(di), g_FD(di));
end
g_FD_ref = g_FD(end);  % 最小步长
fprintf('  sign 一致: %s\n', ...
    ternary_s(all(sign(g_FD) == sign(g_FD_ref)), 'YES', 'NO'));

%% 正演 + 伴随
fprintf('\n[VP] 正演 (eps_r=%.1f)...\n', eps_r_test);
voxel.epsilon_r(inner) = eps_r_test;
update_epsilon(model, voxel, p);
[E_total, ~, E_gauss] = solve_forward(model, voxel, pf);

% 伴随源
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, pf);
Delta_J = J_obs - lc.J_obs_perp;
lc.k_vec = pf.k0 * lc.k_dir;
lc.J_obs_perp = J_obs;
lc.Delta_J_perp = Delta_J;
[Js, Ms, source_pos, F_obs_adj] = build_adjoint_source_fullmaxwell(grid, lc, pf);
f_adj = Js + Ms;

% 伴随求解（修正后的 solve_adjoint）
fprintf('\n[VP] 伴随求解...\n');
[lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, pf, f_adj, source_pos, []);
if ~ok, fprintf('[VP] [FAIL]\n'); return; end
fprintf('[VP] lambda: |mean|=%.4e\n', mean(vecnorm(lambda, 2, 2)));

%% 体素级梯度（★ ⚠5 修复：统一系数 -k0²·dV，与 run_fd_truth 一致）
% dF/dε_v = -k0²·dV·Re[λ·E]（bilinear，无共轭）
% F_obs 归一化在最终梯度层面统一处理
k0_sq = pf.k0^2;
dV_vec = voxel.dV;
gauss_w = voxel.gauss_w;
use_gauss = ~isempty(E_gauss) && ~isempty(lambda_gauss) ...
    && size(E_gauss,1)==size(voxel.gauss_pos,1) ...
    && size(lambda_gauss,1)==size(voxel.gauss_pos,1);

g_voxel = zeros(N_inner, 1);
if use_gauss
    for vi = 1:N_inner
        gp = (4*(vi-1)+1):(4*vi);
        v_idx = inner_idx(vi);
        gs = 0;
        for gpi = 1:4
            % bilinear: Re(λ·E) = Re(λ)·Re(E) - Im(λ)·Im(E)，无共轭
            lam_g = lambda_gauss(gp(gpi),:);
            E_g = E_gauss(gp(gpi),:);
            gs = gs + gauss_w(gpi) * (sum(real(lam_g).*real(E_g)) - sum(imag(lam_g).*imag(E_g)));
        end
        g_voxel(vi) = -k0_sq * dV_vec(v_idx) * gs;  % ★ ⚠5：统一 -k0²·dV
    end
else
    for vi = 1:N_inner
        v_idx = inner_idx(vi);
        lam_v = lambda(vi,:);
        E_v = E_total(vi,:);
        dot_bil = sum(real(lam_v).*real(E_v)) - sum(imag(lam_v).*imag(E_v));
        g_voxel(vi) = -k0_sq * dV_vec(v_idx) * dot_bil;  % ★ ⚠5：统一 -k0²·dV
    end
end

% 链式法则 → eps_r 参数级
% deps/deps_r = 1（均匀球模型）
% ★ ⚠5 修复：伴随梯度统一除以 F_obs，与 FD 定义 A 自洽
g_param = sum(g_voxel) / F_obs_adj;

%% 对比
ratio = g_param / g_FD_ref;
fprintf('\n############################################################\n');
fprintf('#  结果\n');
fprintf('############################################################\n');
fprintf('#  g_FD(eps_r)    = %+.8e\n', g_FD_ref);
fprintf('#  g_adj(eps_r)   = %+.8e\n', g_param);
fprintf('#  ratio          = %+.6f\n', ratio);
fprintf('#  sign match     = %s\n', ternary_s(sign(g_param)==sign(g_FD_ref), 'YES', 'NO'));
fprintf('#\n');
if sign(g_param) == sign(g_FD_ref)
    fprintf('#  *** sign 一致！伴随梯度方向正确！***\n');
else
    fprintf('#  sign 不一致！仍需修正。\n');
end
fprintf('############################################################\n');
end

function s = ternary_s(cond, a, b)
    if cond, s=a; else, s=b; end
end
