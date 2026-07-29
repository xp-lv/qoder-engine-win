function check_p2_incident()
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint');
addpath('config','utils','core_forward','core_jobs');

p2 = config();
mphstart(2036);
model2 = mphload(p2.comsol_model_path);
try model2.geom('geom1').run; catch, end
try model2.mesh('mesh1').run; catch, end
phys2 = model2.physics('emw');

fprintf('\n=== 管线2: 无散射体 (eps=1 全域) 测入射波 ===\n');

% 所有 features
fprintf('Features:\n');
ft = phys2.feature().tags();
for i = 1:length(ft)
    fn = char(ft(i));
    fprintf('  %s', fn);
    try
        je = char(phys2.feature(fn).getString('Je'));
        if length(je) > 0, fprintf('  [Je=%s]', je); end
    catch, end
    fprintf('\n');
end

% BackgroundField 加载时状态
fprintf('\nBackgroundField (加载时):\n');
try fprintf('  WaveType = %s\n', char(phys2.prop('BackgroundField').getString('WaveType'))); catch, end
try fprintf('  Eb = %s\n', char(phys2.prop('BackgroundField').getString('Eb'))); catch, end
try fprintf('  Ebg = %s\n', char(phys2.prop('BackgroundField').getString('Ebg'))); catch, end
try fprintf('  SolveFor = %s\n', char(phys2.prop('BackgroundField').getString('SolveFor'))); catch, end

% eps=1 全域
voxel2 = fem_mesh_utils(model2, p2, p2.R_inner);
voxel2.epsilon_r(:) = 1.0;
update_epsilon(model2, voxel2, p2);

% 设 Eb=[0,0,1] (solve_forward 方式)
try model2.physics('emw').prop('BackgroundField').set('Eb', [0 0 1]); end

fprintf('\nBackgroundField (设Eb后):\n');
try fprintf('  Eb = %s\n', char(phys2.prop('BackgroundField').getString('Eb'))); catch, end

% 求解
model2.param.set('freq', num2str(p2.freq));
try model2.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p2.freq)); catch, end
try model2.sol('sol1').clearSolutionData(); catch, end
try model2.sol('sol1').clearSolution(); catch, end
model2.sol('sol1').runAll();

% 无散射体时场值
pts = [0.09 0 0; -0.09 0 0; 0 0 0.09; 0 0 -0.09; 0.12 0 0; 0 0.12 0]';
Ex = mphinterp(model2, 'emw.Ex', 'coord', pts);
Ey = mphinterp(model2, 'emw.Ey', 'coord', pts);
Ez = mphinterp(model2, 'emw.Ez', 'coord', pts);
rEx = mphinterp(model2, 'emw.relEx', 'coord', pts);
rEy = mphinterp(model2, 'emw.relEy', 'coord', pts);
rEz = mphinterp(model2, 'emw.relEz', 'coord', pts);

labels = {'+x(9cm)', '-x(9cm)', '+z(9cm)', '-z(9cm)', '+x(12cm)', '+y(12cm)'};
fprintf('\n无散射体场值:\n');
for i = 1:6
    fprintf('  %s: E_total=[%.6f, %.6f, %.6f] |E|=%.6f | E_scat=[%.6f, %.6f, %.6f]\n', ...
        labels{i}, Ex(i), Ey(i), Ez(i), norm([Ex(i),Ey(i),Ez(i)]), ...
        rEx(i), rEy(i), rEz(i));
end

fprintf('\n预期: 无散射体时 E_total ≈ [0,0,1]*exp(ikx), E_scat ≈ 0\n');
fprintf('  +x(9cm): E_z 应≈cos(2pi*0.09/0.3)=%.6f\n', cos(2*pi*0.09/0.3));
fprintf('  -x(9cm): E_z 应≈cos(-2pi*0.09/0.3)=%.6f\n', cos(-2*pi*0.09/0.3));

try ModelUtil.remove('Model'); catch, end
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
