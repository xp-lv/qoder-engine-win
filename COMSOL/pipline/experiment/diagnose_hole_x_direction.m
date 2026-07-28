function diagnose_hole_x_direction()
%DIAGNOSE_HOLE_X_DIRECTION hole_x 梯度方向实证验证
%
%   当前点 hole_x=0.015, 真值 hole_x=0.03
%   FD:   g_hole_x > 0 (增大降低F)
%   伴随: g_hole_x < 0 (减小降低F)
%
%   实验: F(0.025) vs F(0.005) vs F(0.015)
%   如果 F(0.025) < F(0.015) < F(0.005) -> FD 正确 (+方向是下降)
%   如果 F(0.005) < F(0.015) < F(0.025) -> 伴随正确 (-方向是下降)

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath(fullfile(pipline_dir,'config'), fullfile(pipline_dir,'utils'), ...
        fullfile(pipline_dir,'core_forward'), fullfile(pipline_dir,'core_jobs'), ...
        fullfile(pipline_dir,'core_jhyp'), fullfile(pipline_dir,'core_adjoint'), ...
        fullfile(pipline_dir,'algorithm'), fullfile(pipline_dir,'experiment'))
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  hole_x 梯度方向实证验证\n');
fprintf('#  hole_x=0.015 (当前), 真值=0.03\n');
fprintf('#  FD: g>0 (+方向), 伴随: g<0 (-方向)\n');
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

%% 预计算 J_obs（真值）
fprintf('[DX] 预计算 J_obs (真值 eps_r=5, hole=[0.03,0.02,0.01])...\n');
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

%% 计算 3 个点的 F（非归一化目标函数）
test_points = [
    0.025,  % 朝真值方向 (+0.01)
    0.015,  % 当前点 (基准)
    0.005,  % 背离真值方向 (-0.01)
];
F_values = zeros(3, 1);

fprintf('\n[DX] 计算 F(hole_x)...\n');
for i = 1:3
    hx = test_points(i);
    hp = [hx; 0.010; 0.005];
    d_v = sqrt(sum((inner_pos - hp').^2, 2));
    voxel.epsilon_r(inner_mask) = eps_r_test + (1.0-eps_r_test)*0.5*(1-tanh(d_v/delta_sdf));
    update_epsilon(model, voxel, p);
    pf = pf0;
    solve_forward(model, voxel, pf);
    sf = extract_scattered(model, grid);
    lc = lightcone_project(grid, sf, pf);
    dJ = J_obs - lc.J_obs_perp;
    F = mean(sum(abs(dJ).^2, 2)) / 6;
    F_values(i) = F;
    fprintf('  hole_x=%.3f: F = %.10e\n', hx, F);
end

%% 分析
fprintf('\n############################################################\n');
fprintf('#  结果\n');
fprintf('############################################################\n');
fprintf('#  hole_x=0.025 (+方向, 朝真值): F = %.10e\n', F_values(1));
fprintf('#  hole_x=0.015 (基准):         F = %.10e\n', F_values(2));
fprintf('#  hole_x=0.005 (-方向, 背离):  F = %.10e\n', F_values(3));
fprintf('#\n');

if F_values(1) < F_values(2) && F_values(2) < F_values(3)
    fprintf('#  F(0.025) < F(0.015) < F(0.005)\n');
    fprintf('#  => +方向是下降方向 -> FD 正确 (g_hole_x > 0)\n');
    fprintf('#  => 伴随梯度 sign 错误\n');
elseif F_values(3) < F_values(2) && F_values(2) < F_values(1)
    fprintf('#  F(0.005) < F(0.015) < F(0.025)\n');
    fprintf('#  => -方向是下降方向 -> 伴随正确 (g_hole_x < 0)\n');
    fprintf('#  => FD sign 错误（不太可能，因为 FD 是纯数值差分）\n');
else
    fprintf('#  F 不是单调的 -> 目标函数在 hole_x 方向有局部极值\n');
    fprintf('#  当前点可能不在凸区域内\n');
end

fprintf('#\n#  方向导数（中心差分）:\n');
dF_plus = F_values(1) - F_values(2);
dF_minus = F_values(3) - F_values(2);
fprintf('#  F(0.025) - F(0.015) = %+.10e (朝真值)\n', dF_plus);
fprintf('#  F(0.005) - F(0.015) = %+.10e (背离真值)\n', dF_minus);
fprintf('#  中心差分 g_FD ≈ %.10e\n', (F_values(1) - F_values(3)) / 0.02);
fprintf('############################################################\n');
end
