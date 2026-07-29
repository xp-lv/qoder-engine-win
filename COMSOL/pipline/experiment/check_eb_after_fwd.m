function check_eb_after_fwd()
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
addpath('config','experiment','core_forward','utils');

p = config();
fprintf('Model: %s\n', p.comsol_model_path);
mphstart(2036);
model = mphload(p.comsol_model_path);
phys = model.physics('emw');

fprintf('\n=== 加载后 Eb/Ebg ===\n');
try fprintf('  Eb = %s\n', char(phys.prop('BackgroundField').getString('Eb'))); catch, end
try fprintf('  Ebg = %s\n', char(phys.prop('BackgroundField').getString('Ebg'))); catch, end

% 模拟 solve_forward 的操作
voxel = fem_mesh_utils(model, p, p.a_scatter);
inner = voxel.mask_interior;
voxel.epsilon_r(inner) = 5.0;
voxel.epsilon_r(~inner) = 1.0;
model = update_epsilon(model, voxel, p);

% solve_forward 中设 Eb=[0,0,1]
try model.physics('emw').prop('BackgroundField').set('Eb', [0 0 1]); end

fprintf('\n=== update_epsilon + Eb=[0,0,1] 后 ===\n');
try fprintf('  Eb = %s\n', char(phys.prop('BackgroundField').getString('Eb'))); catch, end
try fprintf('  Ebg = %s\n', char(phys.prop('BackgroundField').getString('Ebg'))); catch, end

% 求解
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

fprintf('\n=== 求解后 ===\n');
try fprintf('  Eb = %s\n', char(phys.prop('BackgroundField').getString('Eb'))); catch, end
try fprintf('  Ebg = %s\n', char(phys.prop('BackgroundField').getString('Ebg'))); catch, end

% 检查入射波 E_inc（在无散射体的远场点应该≈Eb）
fprintf('\n=== 检查实际入射波（r=0.3 远离散射体）===\n');
pts = [0.3 0 0; 0 0 0.3; 0 0 -0.3; 0.15 0 0; 0 0.15 0]';
Ex = mphinterp(model, 'emw.Ex', 'coord', pts);
Ey = mphinterp(model, 'emw.Ey', 'coord', pts);
Ez = mphinterp(model, 'emw.Ez', 'coord', pts);
for i = 1:5
    fprintf('  pt%d: E_total = [%.6f, %.6f, %.6f] |E|=%.6f\n', i, Ex(i), Ey(i), Ez(i), norm([Ex(i),Ey(i),Ez(i)]));
end

% 管线2同样测试
fprintf('\n\n=== 管线2 ===\n');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint');
addpath('config','utils','core_forward');
p2 = config();
model2 = mphload(p2.comsol_model_path);
try model2.geom('geom1').run; catch, end
try model2.mesh('mesh1').run; catch, end
phys2 = model2.physics('emw');

fprintf('\n=== 加载后 Eb/Ebg (管线2) ===\n');
try fprintf('  Eb = %s\n', char(phys2.prop('BackgroundField').getString('Eb'))); catch, end
try fprintf('  Ebg = %s\n', char(phys2.prop('BackgroundField').getString('Ebg'))); catch, end

voxel2 = fem_mesh_utils(model2, p2, p2.R_inner);
inner2 = voxel2.mask_interior;
voxel2.epsilon_r(inner2) = 5.0;
update_epsilon(model2, voxel2, p2);
try model2.physics('emw').prop('BackgroundField').set('Eb', [0 0 1]); end

fprintf('\n=== update_epsilon + Eb=[0,0,1] 后 (管线2) ===\n');
try fprintf('  Eb = %s\n', char(phys2.prop('BackgroundField').getString('Eb'))); catch, end
try fprintf('  Ebg = %s\n', char(phys2.prop('BackgroundField').getString('Ebg'))); catch, end

model2.param.set('freq', num2str(p2.freq));
try model2.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p2.freq)); catch, end
try model2.sol('sol1').clearSolutionData(); catch, end
try model2.sol('sol1').clearSolution(); catch, end
model2.sol('sol1').runAll();

fprintf('\n=== 检查实际入射波（管线2模型，r=0.15=空气层内）===\n');
pts2 = [0.15 0 0; 0 0 0.15; 0 0 -0.15; 0.1 0 0; 0 0.1 0]';
Ex2 = mphinterp(model2, 'emw.Ex', 'coord', pts2);
Ey2 = mphinterp(model2, 'emw.Ey', 'coord', pts2);
Ez2 = mphinterp(model2, 'emw.Ez', 'coord', pts2);
for i = 1:5
    fprintf('  pt%d: E_total = [%.6f, %.6f, %.6f] |E|=%.6f\n', i, Ex2(i), Ey2(i), Ez2(i), norm([Ex2(i),Ey2(i),Ez2(i)]));
end

try ModelUtil.remove('Model'); catch, end
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
