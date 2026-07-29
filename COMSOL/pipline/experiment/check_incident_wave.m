function check_incident_wave()
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
addpath('config','experiment','core_forward','utils');

p = config();
mphstart(2036);
model = mphload(p.comsol_model_path);
phys = model.physics('emw');

fprintf('\n=== 管线1: 无散射体 (eps=1 全域) 测入射波 ===\n');
voxel = fem_mesh_utils(model, p, p.a_scatter);
% 不设 epsilon_r → 全域默认 1.0 (空气)
voxel.epsilon_r(:) = 1.0;
model = update_epsilon(model, voxel, p);
try model.physics('emw').prop('BackgroundField').set('Eb', [0 0 1]); end

% 求解
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end
try model.sol('sol1').clearSolutionData(); catch, end
try model.sol('sol1').clearSolution(); catch, end
model.sol('sol1').runAll();

% 在无散射体时，E_total 应该 = E_inc = [0,0,1] * exp(ikx)
pts = [0.09 0 0; -0.09 0 0; 0 0 0.09; 0 0 -0.09; 0.3 0 0; 0 0.3 0]';
Ex = mphinterp(model, 'emw.Ex', 'coord', pts);
Ey = mphinterp(model, 'emw.Ey', 'coord', pts);
Ez = mphinterp(model, 'emw.Ez', 'coord', pts);
rEx = mphinterp(model, 'emw.relEx', 'coord', pts);
rEy = mphinterp(model, 'emw.relEy', 'coord', pts);
rEz = mphinterp(model, 'emw.relEz', 'coord', pts);

labels = {'+x(9cm)', '-x(9cm)', '+z(9cm)', '-z(9cm)', '+x(30cm)', '+y(30cm)'};
for i = 1:6
    fprintf('  %s: E_total=[%.6f, %.6f, %.6f] |E|=%.6f | E_scat=[%.6f, %.6f, %.6f]\n', ...
        labels{i}, Ex(i), Ey(i), Ez(i), norm([Ex(i),Ey(i),Ez(i)]), ...
        rEx(i), rEy(i), rEz(i));
end

fprintf('\n  如果入射波是 E_inc=[0,0,1]*exp(ikx):\n');
fprintf('    +x方向 E_z 应≈cos(k*x), -x方向 E_z 应≈cos(k*x)\n');
fprintf('    散射场应为 0 (无散射体)\n');

try ModelUtil.remove('Model'); catch, end
