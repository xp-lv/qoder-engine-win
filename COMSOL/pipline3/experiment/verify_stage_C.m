function verify_stage_C()
%VERIFY_STAGE_C COMSOL 伴随场求解的复对称性测试
%
%   测试: COMSOL 刚度矩阵 K 是复对称的 (K=K^T)
%   所以 K^{-1} 也是复对称的
%   对于 bilinear 内积 <x,y> = sum(x.*y)（无共轭）:
%     <b2, K^{-1}·b1>_bilin = <K^{-1}·b2, b1>_bilin
%
%   实际操作:
%     1. 正演: 注入 b1 → COMSOL 求解 → E1 (所有内部体素的场)
%     2. 伴随: 注入 b2 → COMSOL 求解 → λ2
%     3. 验证: <b2, E1>_bilin = <λ2, b1>_bilin
%
%   如果相等 → COMSOL 求解正确，问题在后续环节
%   如果不等 → COMSOL 求解链路有 bug（源注入、背景场、求解器等）

this_dir = fileparts(mfilename('fullpath'));
cd(fileparts(this_dir));
addpath('config','utils','core_forward','core_jobs','core_jhyp');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  阶段 C: COMSOL 伴随场求解的复对称性测试\n');
fprintf('#  测试: <b2, K^{-1}b1>_bilin = <K^{-1}b2, b1>_bilin\n');
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

% ★ 关键修正：用 FEM 节点（网格顶点）而非体素中心做测试
% 获取所有 FEM 节点坐标
mesh_obj = model.mesh('mesh1');
fem_pos = mesh_obj.getVertex()';  % [N_vert × 3] FEM 节点坐标
N_fem = size(fem_pos, 1);
fprintf('[C] N_fem_nodes = %d\n', N_fem);

% 只选内部区域的节点（散射体球内）
r_fem = sqrt(sum(fem_pos.^2, 2));
inner_fem = r_fem < p.a_scatter;
fem_inner_pos = fem_pos(inner_fem, :);
N_fem_inner = sum(inner_fem);
fprintf('[C] N_fem_inner = %d\n', N_fem_inner);

% 用均匀 eps_r=4
voxel.epsilon_r(inner) = 4.0;
update_epsilon(model, voxel, p);

%% 构造两个随机源 b1, b2（在内部 FEM 节点上）
rng(42);
b1 = randn(N_fem_inner, 3) + 1i * randn(N_fem_inner, 3);  % 源 1
b2 = randn(N_fem_inner, 3) + 1i * randn(N_fem_inner, 3);  % 源 2

%% 求解 1: 注入 b1 → 得到 E1
fprintf('[C] 求解 1: 注入 b1...\n');
[lambda1, ok1] = inject_and_solve(model, voxel, phys, b1, fem_inner_pos, p);
if ~ok1, fprintf('[C] FAIL solve1\n'); return; end
fprintf('[C] E1 (b1 注入): |mean|=%.4e\n', mean(vecnorm(lambda1, 2, 2)));

%% 求解 2: 注入 b2 → 得到 λ2
fprintf('[C] 求解 2: 注入 b2...\n');
[lambda2, ok2] = inject_and_solve(model, voxel, phys, b2, fem_inner_pos, p);
if ~ok2, fprintf('[C] FAIL solve2\n'); return; end
fprintf('[C] λ2 (b2 注入): |mean|=%.4e\n', mean(vecnorm(lambda2, 2, 2)));

%% bilinear 内积测试
% K·E = -iω·Je，所以 E = K^{-1}·(-iω·b)
% bilinear: <b2, E1> = b2^T·K^{-1}·(-iω·b1)
%          <E2, b1> = (-iω·b2)^T·K^{-1}^T·b1 = (-iω)·b2^T·K^{-1}·b1 （K^T=K）
% 所以: <b2, E1> = (-iω)·<b2, K^{-1}·b1>
%       <E2, b1> = (-iω)·<K^{-1}·b2, b1>
% K^{-1} 复对称: <b2, K^{-1}·b1> = <K^{-1}·b2, b1>
% 因此: <b2, E1> / (-iω) = <E2, b1> / (-iω)
% 即: <b2, E1> = <E2, b1> （-iω 因子在两边抵消！）

% <b2, E1>_bilin = sum(b2 .* E1) （无共轭）
lhs = sum(b2(:) .* lambda1(:));
% <E2, b1>_bilin = sum(E2 .* b1) （无共轭）
rhs = sum(lambda2(:) .* b1(:));

ratio = lhs / rhs;
fprintf('\n############################################################\n');
fprintf('#  阶段 C 结果（bilinear 内积，无共轭）\n');
fprintf('############################################################\n');
fprintf('#  <b2, K^{-1}b1> = %+.8e %+.8ei\n', real(lhs), imag(lhs));
fprintf('#  <K^{-1}b2, b1> = %+.8e %+.8ei\n', real(rhs), imag(rhs));
fprintf('#  ratio = %.10f %+.10fi\n', real(ratio), imag(ratio));
fprintf('#  |ratio - 1| = %.2e\n', abs(ratio - 1));
if abs(ratio - 1) < 1e-10
    fprintf('#  *** 阶段 C 通过！COMSOL K^{-1} 是复对称的！***\n');
else
    fprintf('#  阶段 C 不通过。\n');
end
fprintf('############################################################\n');

%% Hermitian 内积测试（对比，应该不相等）
% <b2, E1>_herm = sum(conj(b2) .* E1)
lhs_h = sum(conj(b2(:)) .* lambda1(:));
rhs_h = sum(conj(lambda2(:)) .* b1(:));
ratio_h = lhs_h / rhs_h;
fprintf('\n#  对比: Hermitian 内积（带共轭，应不为 1）:\n');
fprintf('#  ratio_herm = %.6f %+.6fi\n', real(ratio_h), imag(ratio_h));
fprintf('############################################################\n');
end

%% ====== 辅助函数：注入源并求解 ======
function [lambda, ok] = inject_and_solve(model, voxel, phys, b_src, inner_pos, p)
% 注入体积电流源 b_src 到 COMSOL，求解，返回内部体素的场
%
% b_src: [N_inner × 3] 复数电流密度
% 用 ExternalCurrentDensity (vec1) 注入

ok = false;
lambda = [];

% 写插值函数
func_names = {'int_adj_x_re','int_adj_x_im', ...
              'int_adj_y_re','int_adj_y_im', ...
              'int_adj_z_re','int_adj_z_im'};

for d = 1:3
    for part = 1:2
        idx = (d-1)*2 + part;
        fn = func_names{idx};
        try model.component('comp1').func(fn);
        catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        if part == 1
            vals = real(b_src(:, d));
        else
            vals = imag(b_src(:, d));
        end
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [inner_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp);
        delete(tmp);
    end
end

% 设置 vec1 Je = b_src（直接，不缩放）
Je_x = sprintf('(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))');
Je_y = sprintf('(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))');
Je_z = sprintf('(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))');

try
    phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});
catch ME
    fprintf('  [inject] FAIL vec1 set: %s\n', ME.message);
    return;
end

% 归零背景场
try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch, end
model.param.set('adjoint_mode', '0');

% 求解（不清除解，直接 runAll）
try
    model.sol('sol1').runAll();
catch ME
    fprintf('  [inject] FAIL solve: %s\n', ME.message);
    return;
end

% 提取场
try
    [lambda, ~] = read_field(model, inner_pos);
    ok = true;
catch ME
    fprintf('  [inject] FAIL read: %s\n', ME.message);
end

% 恢复
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
model.param.set('adjoint_mode', '1');
end
