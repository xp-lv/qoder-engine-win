function diag_point_field_compare()
%DIAG_POINT_FIELD_COMPARE 验证虚部是否真正写入 COMSOL
%   对比 eps_r=5（纯实数）vs eps_r=5-3j 在 (0.07,0,0) 点的场值

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  对比 eps_r=5 vs eps_r=5-3j 在 (0.07,0,0) 的场值\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[DIAG] [FAIL] mphstart\n'); return; end
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

% 目标探测点（散射体内部，r=0.04 < R_inner=0.06）
probe_point = [0.04, 0, 0];
fprintf('[DIAG] 探测点: (%.4f, %.4f, %.4f)\n', probe_point(1), probe_point(2), probe_point(3));
fprintf('[DIAG] R_inner=%.4f, 探测点在散射体%s\n\n', p.R_inner, ...
    string(ternary_s(norm(probe_point) < p.R_inner, '内部', '外部')));

%% 2. 设置频率
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end

%% 3. Case A: eps_r = 5 (纯实数)
fprintf('========== Case A: eps_r = 5.0 (纯实数) ==========\n');
voxel.epsilon_r(inner) = 5.0;
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolutionData();
model.sol('sol1').clearSolution();
model.sol('sol1').runAll();

% 读取 int1/int2 的实际值（验证 COMSOL 是否正确接收）
coords = probe_point';
int1_val = mphinterp(model, 'int1(x,y,z)', 'coord', coords);
int2_val = mphinterp(model, 'int2(x,y,z)', 'coord', coords);
fprintf('  COMSOL int1 (Re) at probe = %.6f\n', int1_val);
fprintf('  COMSOL int2 (Im) at probe = %.6f\n', int2_val);

% 读场值
Ex_A = mphinterp(model, 'emw.Ex', 'coord', coords);
Ey_A = mphinterp(model, 'emw.Ey', 'coord', coords);
Ez_A = mphinterp(model, 'emw.Ez', 'coord', coords);
E_A = [Ex_A(1), Ey_A(1), Ez_A(1)];
fprintf('  E = %.6e %+.6ei, %.6e %+.6ei, %.6e %+.6ei\n', ...
    real(E_A(1)), imag(E_A(1)), real(E_A(2)), imag(E_A(2)), real(E_A(3)), imag(E_A(3)));
fprintf('  |E| = %.6e\n', norm(E_A));

% 也读散射场
rEx_A = mphinterp(model, 'emw.relEx', 'coord', coords);
rEy_A = mphinterp(model, 'emw.relEy', 'coord', coords);
rEz_A = mphinterp(model, 'emw.relEz', 'coord', coords);
rE_A = [rEx_A(1), rEy_A(1), rEz_A(1)];
fprintf('  relE(scattered) = %.6e %+.6ei, %.6e %+.6ei, %.6e %+.6ei\n', ...
    real(rE_A(1)), imag(rE_A(1)), real(rE_A(2)), imag(rE_A(2)), real(rE_A(3)), imag(rE_A(3)));
fprintf('  |relE| = %.6e\n\n', norm(rE_A));

%% 4. Case B: eps_r = 5 - 3j (复数)
fprintf('========== Case B: eps_r = 5.0 - 3.0j (复数) ==========\n');
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolutionData();
model.sol('sol1').clearSolution();
model.sol('sol1').runAll();

int1_val_B = mphinterp(model, 'int1(x,y,z)', 'coord', coords);
int2_val_B = mphinterp(model, 'int2(x,y,z)', 'coord', coords);
fprintf('  COMSOL int1 (Re) at probe = %.6f\n', int1_val_B);
fprintf('  COMSOL int2 (Im) at probe = %.6f\n', int2_val_B);

Ex_B = mphinterp(model, 'emw.Ex', 'coord', coords);
Ey_B = mphinterp(model, 'emw.Ey', 'coord', coords);
Ez_B = mphinterp(model, 'emw.Ez', 'coord', coords);
E_B = [Ex_B(1), Ey_B(1), Ez_B(1)];
fprintf('  E = %.6e %+.6ei, %.6e %+.6ei, %.6e %+.6ei\n', ...
    real(E_B(1)), imag(E_B(1)), real(E_B(2)), imag(E_B(2)), real(E_B(3)), imag(E_B(3)));
fprintf('  |E| = %.6e\n', norm(E_B));

rEx_B = mphinterp(model, 'emw.relEx', 'coord', coords);
rEy_B = mphinterp(model, 'emw.relEy', 'coord', coords);
rEz_B = mphinterp(model, 'emw.relEz', 'coord', coords);
rE_B = [rEx_B(1), rEy_B(1), rEz_B(1)];
fprintf('  relE(scattered) = %.6e %+.6ei, %.6e %+.6ei, %.6e %+.6ei\n', ...
    real(rE_B(1)), imag(rE_B(1)), real(rE_B(2)), imag(rE_B(2)), real(rE_B(3)), imag(rE_B(3)));
fprintf('  |relE| = %.6e\n\n', norm(rE_B));

%% 5. 对比
fprintf('========== 对比 ==========\n');
fprintf('  int1 差异: %.6f → %.6f (Δ=%.6f)\n', int1_val, int1_val_B, int1_val_B - int1_val);
fprintf('  int2 差异: %.6f → %.6f (Δ=%.6f)\n', int2_val, int2_val_B, int2_val_B - int2_val);
fprintf('  |E|  对比: A=%.6e  B=%.6e  B/A=%.4f\n', norm(E_A), norm(E_B), norm(E_B)/norm(E_A));
fprintf('  |relE| 对比: A=%.6e  B=%.6e  B/A=%.4f\n', norm(rE_A), norm(rE_B), norm(rE_B)/norm(rE_A));
fprintf('\n  ★ 如果 int2 从 0 变为 -3，且 |E| 有变化 → 虚部已正确写入\n');
fprintf('  ★ 如果 int2 仍为 0 或 |E| 完全不变 → 虚部未写入\n');
fprintf('############################################################\n');

end

function s = ternary_s(cond, a, b), if cond, s=a; else, s=b; end, end
