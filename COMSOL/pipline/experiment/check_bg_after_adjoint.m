function check_bg_after_adjoint()
%CHECK_BG_AFTER_ADJOINT 验证伴随恢复后背景场的实际状态
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
import com.comsol.model.util.*

setup_fn = which('setup');
if isempty(setup_fn), addpath('config','experiment','core_forward','core_jhyp','core_jobs','utils','algorithm','core_adjoint'); end

p = config();
mphstart(2036);
model = mphload(p.comsol_model_path);

fprintf('\n=== 1. 模型加载后（初始状态）===\n');
phys = model.physics('emw');
try
    bf = phys.prop('BackgroundField');
    fprintf('  Eb = %s\n', char(bf.getString('Eb')));
    fprintf('  Ebg = %s\n', char(bf.getString('Ebg')));
    fprintf('  WaveType = %s\n', char(bf.getString('WaveType')));
catch ME
    fprintf('  Error: %s\n', ME.message);
end
try
    am = char(model.param().get('adjoint_mode'));
    fprintf('  adjoint_mode = %s\n', am);
catch
    fprintf('  adjoint_mode = (undefined)\n');
end

% 正演
voxel_struct = fem_mesh_utils(model, p, p.a_scatter);
inner_idx = find(voxel_struct.mask_interior);
voxel_struct.epsilon_r(inner_idx) = 5.0;
fprintf('\n=== 2. 正演后 ===\n');
solve_forward(model, voxel_struct, p);

try
    bf = phys.prop('BackgroundField');
    fprintf('  Eb = %s\n', char(bf.getString('Eb')));
    fprintf('  Ebg = %s\n', char(bf.getString('Ebg')));
catch ME
    fprintf('  Error: %s\n', ME.message);
end
try
    am = char(model.param().get('adjoint_mode'));
    fprintf('  adjoint_mode = %s\n', am);
catch
end

% 检查实际场值（在空气中应该 ≈ [0,0,1]）
test_pt = [0.2; 0; 0]';
Ez_total = mphinterp(model, 'emw.Ez', 'coord', test_pt');
Ez_scat = mphinterp(model, 'emw.relEz', 'coord', test_pt);
fprintf('  E_total_z at r=0.2: %.6f (应≈1.0 if plane wave)\n', Ez_total);
fprintf('  E_scat_z at r=0.2: %.6f\n', Ez_scat);

% 伴随求解
grid = build_measurement_grid(p);
sf = extract_scattered(model, grid);
lc = lightcone_project(grid, sf, p);
J_obs = lc.J_obs_perp;

% 中间态正演
pos_inner = voxel_struct.pos(inner_idx, :);
eps_init = 4.0 * ones(size(pos_inner,1), 1);
voxel_struct.epsilon_r(inner_idx) = eps_init;
[E_eval, ~, E_gauss_eval] = solve_forward(model, voxel_struct, p);
sf_eval = extract_scattered(model, grid);
lc_eval = lightcone_project(grid, sf_eval, p);
Delta_J = J_obs - lc_eval.J_obs_perp;

lc_adj = lc_eval;
lc_adj.k_dir = fibonacci_sphere(p.N_k);
lc_adj.k_vec = p.k0 * lc_adj.k_dir;
lc_adj.J_obs_perp = J_obs;
lc_adj.Delta_J_perp = Delta_J;

[Js, Ms, source_pos, ~] = build_adjoint_source_fullmaxwell(grid, lc_adj, p);
[lambda, adj_ok, lambda_gauss] = solve_adjoint(model, voxel_struct, p, Js, source_pos, Ms);

fprintf('\n=== 3. 伴随求解后（solve_adjoint 内部归零）===\n');
try
    bf = phys.prop('BackgroundField');
    fprintf('  Eb = %s\n', char(bf.getString('Eb')));
    fprintf('  Ebg = %s\n', char(bf.getString('Ebg')));
catch
end
try
    am = char(model.param().get('adjoint_mode'));
    fprintf('  adjoint_mode = %s\n', am);
catch
end

% solve_adjoint 的恢复（第325行设 adjoint_mode=1, 第327行设 Eb=[0,0,1]）
% 这些已经在 solve_adjoint 内部执行了

fprintf('\n=== 4. 伴随恢复后（FD 循环开始前）===\n');
try
    bf = phys.prop('BackgroundField');
    fprintf('  Eb = %s\n', char(bf.getString('Eb')));
    fprintf('  Ebg = %s\n', char(bf.getString('Ebg')));
catch
end
try
    am = char(model.param().get('adjoint_mode'));
    fprintf('  adjoint_mode = %s\n', am);
catch
end

% ★ 关键验证：FD 微扰后的实际场值
fprintf('\n=== 5. FD 微扰后 solve_quiet 的场值 ===\n');
v_test = inner_idx(1);
voxel_struct.epsilon_r(v_test) = voxel_struct.epsilon_r(v_test) + 0.001;
update_epsilon(model, voxel_struct, p);
% solve_quiet
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

% 检查 Eb/Ebg 状态
try
    bf = phys.prop('BackgroundField');
    fprintf('  Eb = %s\n', char(bf.getString('Eb')));
    fprintf('  Ebg = %s\n', char(bf.getString('Ebg')));
catch
end
try
    am = char(model.param().get('adjoint_mode'));
    fprintf('  adjoint_mode = %s\n', am);
catch
end

% 场值验证
Ez_fd = mphinterp(model, 'emw.Ez', 'coord', test_pt);
fprintf('  E_total_z at r=0.2 after FD: %.6f\n', Ez_fd);

% 对比：如果 Eb=[0,0,1] 但 Ebg=[0,0,0*adjoint_mode]
% COMSOL 实际用的是哪个？
fprintf('\n=== 分析 ===\n');
fprintf('如果 Ebg 表达式包含 adjoint_mode，则：\n');
fprintf('  adjoint_mode=1 -> Ebg=[0,0,1] (正确)\n');
fprintf('  adjoint_mode=0 -> Ebg=[0,0,0] (无背景场)\n');
fprintf('Eb 直接值设为 [0,0,1]，但 Ebg 表达式可能覆盖 Eb\n');
