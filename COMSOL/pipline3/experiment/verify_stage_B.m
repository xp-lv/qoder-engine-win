function verify_stage_B()
%VERIFY_STAGE_B 光锥投影 L 与伴随 L^H 的矩阵级内积测试
%
%   测试: <L(x), ΔJ> = <x, L^H(ΔJ)>  对任意 x 和 ΔJ
%
%   L: lightcone_project（表面场 sf → J_obs）
%   L^H: build_adjoint_source_fullmaxwell（ΔJ → Js+Ms）
%
%   关键：L^H 中有 coeff_base 缩放，测试时需要剥离

this_dir = fileparts(mfilename('fullpath'));
cd(fileparts(this_dir));
addpath('config','utils','core_forward','core_jobs','core_jhyp');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  阶段 B: 光锥投影 L 与 L^H 的矩阵级内积测试\n');
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

% vec1 + 首次求解
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    phys.feature('vec1').set('Je', {'0','0','0'});
    try phys.feature('vec1').selection().all(); catch, end
end
try model.param.set('adjoint_mode', '1'); catch, end
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').runAll(); catch, end

grid = build_measurement_grid(p);
voxel = fem_mesh_utils(model, p, p.a_scatter);
inner = voxel.mask_interior;

% 用均匀 eps_r=4 做正演
voxel.epsilon_r(inner) = 4.0;
update_epsilon(model, voxel, p);
[E_total, ~] = solve_forward(model, voxel, p);

% 提取表面场（这就是 L 的输入 x）
sf = extract_scattered(model, grid);

%% 构造 L 的矩阵表示
% L: sf(E_cart, H_cart) → J_obs_perp
% 对每个表面点 s，L 是线性映射：
%   J_obs(i,:) = Σ_s w(s) * [K_J(k_i, n_s) · H_s + K_M(k_i, n_s) · E_s] * exp(-ik·r_s)

N_surface = size(grid.pos, 1);
N_k = p.N_k;
[k_dir, dOmega] = fibonacci_sphere(N_k);
k_vec = p.k0 * k_dir;

w = grid.weight(:);
n_hat = grid.norm;
pos = grid.pos;
eta0 = p.eta0;

%% 测试 1: <L(x), y> vs <x, L^H(y)>
% x = 随机表面场（E,H 各 N_surface×3）
% y = 随机 ΔJ（N_k×3）

fprintf('[B] 构造随机测试场...\n');
rng(42);  % 可复现
x_E = randn(N_surface, 3) + 1i * randn(N_surface, 3);
x_H = randn(N_surface, 3) + 1i * randn(N_surface, 3);
y_DJ = randn(N_k, 3) + 1i * randn(N_k, 3);

%% 左边: L(x) = J_obs(x)
% 直接用 lightcone_project 的公式
sf_x.E_cart = x_E;
sf_x.H_cart = x_H;

lc_x = lightcone_project(grid, sf_x, p);
Lx = lc_x.J_obs_perp;  % [N_k × 3]

% <L(x), y> = sum(conj(Lx) .* y) = Hermitian 内积
lhs = sum(conj(Lx(:)) .* y_DJ(:));
fprintf('[B] <L(x), y> = %+.6e %+.6ei\n', real(lhs), imag(lhs));

%% 右边: <x, L^H(y)>
% L^H 的输出应该是表面场（E,H 各 N_surface×3）
% 但 build_adjoint_source 输出的是 Js+Ms（含 coeff_base 缩放）
% 需要手动构造 L^H（不带 coeff_base）

% 手动计算 L^H(y) = 表面场
% 对每个表面点 s：
%   H_adj(s) = Σ_k w(s) * K_J^T(k_i, n_s) · [y(k_i) * exp(+ik·r_s)]
%   E_adj(s) = Σ_k w(s) * K_M^T(k_i, n_s) · [y(k_i) * exp(+ik·r_s)]

fprintf('[B] 手动计算 L^H(y)（无 coeff_base）...\n');
H_adj = zeros(N_surface, 3);
E_adj = zeros(N_surface, 3);

for sj = 1:N_surface
    r_s = pos(sj, :);
    n_s = n_hat(sj, :);

    % 共轭相位
    phase = exp(1i * k_vec * r_s(:));  % [N_k × 1]

    % v = y · phase
    v = y_DJ .* phase;  % [N_k × 3]

    % k·v, n·v
    kdv = sum(k_dir .* v, 2);
    n_rep = repmat(n_s, N_k, 1);
    ndv = sum(n_rep .* v, 2);

    % K_J^T · v = n × (v - k(k·v))
    v_perp = v - k_dir .* kdv;
    KJt_v = cross(n_rep, v_perp, 2);

    % K_M^T · v = (k(n·v) - v(n·k)) / eta0
    ndk = sum(n_rep .* k_dir, 2);
    KMt_v = (k_dir .* ndv - ndk .* v) / eta0;

    % 权重 w(s)
    H_adj(sj, :) = w(sj) * sum(KJt_v, 1);
    E_adj(sj, :) = w(sj) * sum(KMt_v, 1);
end

% <x, L^H(y)> = <x_E, E_adj> + <x_H, H_adj>
rhs = sum(conj(x_E(:)) .* E_adj(:)) + sum(conj(x_H(:)) .* H_adj(:));
fprintf('[B] <x, L^H(y)> = %+.6e %+.6ei\n', real(rhs), imag(rhs));

%% 对比
ratio = lhs / rhs;
fprintf('\n############################################################\n');
fprintf('#  阶段 B 结果\n');
fprintf('############################################################\n');
fprintf('#  <L(x), y>   = %+.8e %+.8ei\n', real(lhs), imag(lhs));
fprintf('#  <x, L^H(y)> = %+.8e %+.8ei\n', real(rhs), imag(rhs));
fprintf('#  ratio = %.10f %+.10fi\n', real(ratio), imag(ratio));
fprintf('#  |ratio - 1| = %.2e\n', abs(ratio - 1));
if abs(ratio - 1) < 1e-10
    fprintf('#  *** 阶段 B 通过！L 和 L^H 构成精确伴随对！***\n');
else
    fprintf('#  阶段 B 不通过。问题在 lightcone_project / build_adjoint_source 的伴随关系。\n');
end
fprintf('############################################################\n');

%% 测试 2: 多组随机场，验证 ratio 的稳定性
fprintf('\n[B] 多组随机测试（5 组）...\n');
ratios_re = [];
for trial = 1:5
    x_E2 = randn(N_surface, 3) + 1i * randn(N_surface, 3);
    x_H2 = randn(N_surface, 3) + 1i * randn(N_surface, 3);
    y_DJ2 = randn(N_k, 3) + 1i * randn(N_k, 3);

    % L(x2)
    sf_x2.E_cart = x_E2; sf_x2.H_cart = x_H2;
    Lx2 = lightcone_project(grid, sf_x2, p).J_obs_perp;
    lhs2 = sum(conj(Lx2(:)) .* y_DJ2(:));

    % L^H(y2)
    H_adj2 = zeros(N_surface, 3); E_adj2 = zeros(N_surface, 3);
    for sj = 1:N_surface
        r_s = pos(sj, :); n_s = n_hat(sj, :);
        phase = exp(1i * k_vec * r_s(:));
        v = y_DJ2 .* phase;
        kdv = sum(k_dir .* v, 2);
        n_rep = repmat(n_s, N_k, 1);
        ndv = sum(n_rep .* v, 2);
        v_perp = v - k_dir .* kdv;
        KJt_v = cross(n_rep, v_perp, 2);
        ndk = sum(n_rep .* k_dir, 2);
        KMt_v = (k_dir .* ndv - ndk .* v) / eta0;
        H_adj2(sj, :) = w(sj) * sum(KJt_v, 1);
        E_adj2(sj, :) = w(sj) * sum(KMt_v, 1);
    end
    rhs2 = sum(conj(x_E2(:)) .* E_adj2(:)) + sum(conj(x_H2(:)) .* H_adj2(:));

    r2 = lhs2 / rhs2;
    ratios_re = [ratios_re; real(r2)];
    fprintf('  Trial %d: ratio = %.10f\n', trial, real(r2));
end
fprintf('  mean=%.10f, std=%.2e, CV=%.2e\n', ...
    mean(ratios_re), std(ratios_re), std(ratios_re)/abs(mean(ratios_re)));
fprintf('############################################################\n');
end
