function compare_forward_only()
% 只比正演：同一点 R=0.09 处的散射场
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  纯正演对比：R=0.06, eps=5, 在 R=0.09 处提取散射场\n');
fprintf('############################################################\n\n');

%% 管线1
fprintf('===== 管线 1 (livelink_model.mph) =====\n');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
addpath('config','experiment','core_forward','utils','core_jobs');

p1 = config();
mphstart(2036);
model1 = mphload(p1.comsol_model_path);

voxel1 = fem_mesh_utils(model1, p1, p1.a_scatter);
inner1 = voxel1.mask_interior;

% eps=5 正演
voxel1.epsilon_r(inner1) = 5.0;
voxel1.epsilon_r(~inner1) = 1.0;
solve_forward(model1, voxel1, p1);

% 提取几个关键点的总场和散射场
test_pts = [0.09, 0, 0;    % +x 方向 R=0.09
           -0.09, 0, 0;     % -x 方向
            0, 0.09, 0;     % +y 方向
            0, 0, 0.09;     % +z 方向
            0, 0, -0.09];   % -z 方向
coords = test_pts';

fprintf('\n管线1 场值 (R=0.09m):\n');
Ex1 = mphinterp(model1, 'emw.Ex', 'coord', coords);
Ey1 = mphinterp(model1, 'emw.Ey', 'coord', coords);
Ez1 = mphinterp(model1, 'emw.Ez', 'coord', coords);
rEx1 = mphinterp(model1, 'emw.relEx', 'coord', coords);
rEy1 = mphinterp(model1, 'emw.relEy', 'coord', coords);
rEz1 = mphinterp(model1, 'emw.relEz', 'coord', coords);

for i = 1:size(test_pts,1)
    Etot = [Ex1(i), Ey1(i), Ez1(i)];
    Escat = [rEx1(i), rEy1(i), rEz1(i)];
    fprintf('  pt[%+d,%+d,%+d]: |E_total|=%.6f |E_scat|=%.6f E_total_z=%.6f E_scat_z=%.6f\n', ...
        test_pts(i,1)*100, test_pts(i,2)*100, test_pts(i,3)*100, ...
        norm(Etot), norm(Escat), Ez1(i), rEz1(i));
end

try ModelUtil.remove('Model'); catch, end

%% 管线2
fprintf('\n===== 管线 2 (2layer.mph) =====\n');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint');
addpath('config','utils','core_forward','core_jobs');

p2 = config();
try mphstart(2036); catch ME; if ~contains(ME.message,'Already'), rethrow(ME); end, end
model2 = mphload(p2.comsol_model_path);
try model2.geom('geom1').run; catch, end
try model2.mesh('mesh1').run; catch, end

voxel2 = fem_mesh_utils(model2, p2, p2.R_inner);
inner2 = voxel2.mask_interior;

% eps=5 正演
voxel2.epsilon_r(inner2) = 5.0;
update_epsilon(model2, voxel2, p2);
model2.param.set('freq', num2str(p2.freq));
try model2.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p2.freq)); catch, end
try model2.sol('sol1').clearSolutionData(); catch, end
try model2.sol('sol1').clearSolution(); catch, end
model2.sol('sol1').runAll();

fprintf('\n管线2 场值 (R=0.09m):\n');
Ex2 = mphinterp(model2, 'emw.Ex', 'coord', coords);
Ey2 = mphinterp(model2, 'emw.Ey', 'coord', coords);
Ez2 = mphinterp(model2, 'emw.Ez', 'coord', coords);
rEx2 = mphinterp(model2, 'emw.relEx', 'coord', coords);
rEy2 = mphinterp(model2, 'emw.relEy', 'coord', coords);
rEz2 = mphinterp(model2, 'emw.relEz', 'coord', coords);

for i = 1:size(test_pts,1)
    Etot = [Ex2(i), Ey2(i), Ez2(i)];
    Escat = [rEx2(i), rEy2(i), rEz2(i)];
    fprintf('  pt[%+d,%+d,%+d]: |E_total|=%.6f |E_scat|=%.6f E_total_z=%.6f E_scat_z=%.6f\n', ...
        test_pts(i,1)*100, test_pts(i,2)*100, test_pts(i,3)*100, ...
        norm(Etot), norm(Escat), Ez2(i), rEz2(i));
end

try ModelUtil.remove('Model'); catch, end

%% 对比
fprintf('\n############################################################\n');
fprintf('#  正演场值逐点对比\n');
fprintf('############################################################\n');
fprintf('%-15s | %-18s %-18s | %-18s %-18s\n', '', '管线1_total_z', '管线2_total_z', '管线1_scat_z', '管线2_scat_z');
fprintf('%-15s | %-18s %-18s | %-18s %-18s\n', '---', '---', '---', '---', '---');
labels = {'+x (R=9cm)', '-x', '+y', '+z', '-z'};
for i = 1:size(test_pts,1)
    fprintf('%-15s | %+18.6f %+18.6f | %+18.6f %+18.6f\n', labels{i}, Ez1(i), Ez2(i), rEz1(i), rEz2(i));
end
fprintf('\n');

% 逐点比值
fprintf('管线1/管线2 比值:\n');
for i = 1:size(test_pts,1)
    r1 = abs(rEz1(i)); r2 = abs(rEz2(i));
    if r2 > 1e-15
        fprintf('  %s: E_scat_z ratio = %.4f\n', labels{i}, r1/r2);
    end
end

cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
