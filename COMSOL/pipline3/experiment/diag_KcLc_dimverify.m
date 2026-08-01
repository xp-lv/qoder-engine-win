function diag_KcLc_dimverify()
%DIAG_KCLC_DIMVERIFY 排查 Kc\Lc 还原链 + ExternalCurrentDensity 量纲

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  Kc\\Lc 还原链 + 量纲诊断\n');
fprintf('############################################################\n\n');

p = config();
omega = p.omega(1); mu0 = p.mu0; eps0 = p.eps0;
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[DIAG] [FAIL]\n'); return; end
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
inner = voxel.mask_interior;

%% === 问题1: Kc\Lc 还原链 ===
fprintf('======== 问题1: Kc\\Lc 还原链 ========\n\n');

% 正演 eps_r=3
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 1a. mphgetu 获取正演解
U_direct = mphgetu(model);
fprintf('mphgetu: %d elements, |U| max=%.4e\n', length(U_direct), max(abs(U_direct)));

% 1b. mphmatrix 导出（含完整还原参数）
MA = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale', 'M'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');

fprintf('Kc: %dx%d, Lc: %dx%d\n', size(MA.Kc,1), size(MA.Kc,2), size(MA.Lc,1), size(MA.Lc,2));
fprintf('Null: %dx%d, ud: %dx%d, uscale: %dx%d\n', ...
    size(MA.Null,1), size(MA.Null,2), ...
    size(MA.ud,1), size(MA.ud,2), ...
    size(MA.uscale,1), size(MA.uscale,2));
if isfield(MA, 'M')
    fprintf('M (mass matrix): %dx%d\n', size(MA.M,1), size(MA.M,2));
end

% 1c. 用 Kc\Lc 还原
Uc = MA.Kc \ MA.Lc;
fprintf('\nUc (Kc\\Lc): %d elements, |Uc| max=%.4e\n', length(Uc), max(abs(Uc)));

% 还原步骤: U_full = uscale .* (Null * Uc + ud)
U_recovered = MA.uscale .* (MA.Null * Uc + MA.ud);
fprintf('U_recovered: %d elements, |U| max=%.4e\n', length(U_recovered), max(abs(U_recovered)));

% 1d. 对比
U_direct_compact = U_direct(1:length(U_recovered));
fprintf('\n|U_direct|    max=%.4e\n', max(abs(U_direct)));
fprintf('|U_recovered| max=%.4e\n', max(abs(U_recovered)));

if length(U_direct) == length(U_recovered)
    err = norm(U_direct - U_recovered) / norm(U_direct);
    fprintf('相对误差 = %.6e\n', err);
    
    % 检查是否只是缩放
    scale = U_direct ./ U_recovered;
    scale_valid = scale(abs(U_recovered) > 0.01 * max(abs(U_recovered)));
    if ~isempty(scale_valid)
        fprintf('U_direct / U_recovered 的中位数 = %.6e\n', median(real(scale_valid)));
        fprintf('U_direct / U_recovered 的变异系数 = %.4f%%\n', ...
            std(scale_valid)/abs(mean(scale_valid))*100);
    end
else
    fprintf('长度不匹配: U_direct=%d, U_recovered=%d\n', length(U_direct), length(U_recovered));
end

% 1e. 验证 Kc*Uc = Lc
residual = MA.Kc * Uc - MA.Lc;
fprintf('\nKc*Uc - Lc 残差: max=%.4e (应为≈0)\n', full(max(abs(residual))));

%% === 问题2: ExternalCurrentDensity 量纲 ===
fprintf('\n======== 问题2: ExternalCurrentDensity 量纲 ========\n\n');

% 测试1: Je=[1,0,0]，归零背景场
fprintf('--- 测试1: Je=[1,0,0], Eb=0 ---\n');
model.param.set('adjoint_mode', '0');
try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch; end
phys.feature('vec1').set('Je', {'1', '0', '0'});
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 提取 (0.04,0,0) 的 E
pt = [0.04; 0; 0];
Ex1 = mphinterp(model, 'emw.Ex', 'coord', pt);
Ey1 = mphinterp(model, 'emw.Ey', 'coord', pt);
Ez1 = mphinterp(model, 'emw.Ez', 'coord', pt);
fprintf('  E(0.04,0,0) = [%.4e, %.4e, %.4e]\n', Ex1(1), Ey1(1), Ez1(1));
fprintf('  |E| = %.4e\n', abs(Ex1(1)));

% 导出此时的 Lc（应该含 Je=[1,0,0] 的源贡献）
MA_J1 = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
fprintf('  |Lc(Je=1)| max=%.4e\n', full(max(abs(MA_J1.Lc))));

% 测试2: Je=[10,0,0]（10倍）
fprintf('\n--- 测试2: Je=[10,0,0], Eb=0 ---\n');
phys.feature('vec1').set('Je', {'10', '0', '0'});
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
Ex10 = mphinterp(model, 'emw.Ex', 'coord', pt);
fprintf('  Ex(0.04,0,0) = %.4e\n', Ex10(1));
fprintf('  Ex(Je=10)/Ex(Je=1) = %.4f (应为10)\n', Ex10(1)/Ex1(1));

% 测试3: 频率对 E 的影响
fprintf('\n--- 测试3: Je=[1,0,0], freq=2GHz ---\n');
model.param.set('freq', num2str(2e9));
try model.study('std1').feature('freq').set('plist', '2e9[Hz]'); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
Ex_2g = mphinterp(model, 'emw.Ex', 'coord', pt);
fprintf('  Ex(2GHz) = %.4e\n', Ex_2g(1));
fprintf('  Ex(2GHz)/Ex(1GHz) = %.4f\n', Ex_2g(1)/Ex1(1));
fprintf('  ω(2GHz)/ω(1GHz) = %.4f\n', 2.0);

% 恢复频率
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end

% 测试4: 验证 K*E = jωμ₀*Je 的离散形式
% 如果 COMSOL 的弱形式是 ∫(∇×W)·μᵣ⁻¹·(∇×E)dV - k₀²∫W·εᵣ·E dV = -jωμ₀∫W·Je dV
% 则 L = -jωμ₀ * ∫W·Je dV（注意负号！）
fprintf('\n--- 测试4: Lc 物理含义分析 ---\n');
phys.feature('vec1').set('Je', {'1', '0', '0'});
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
MA_J1b = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');

fprintf('  |Lc| max=%.4e\n', full(max(abs(MA_J1b.Lc))));
fprintf('  ωμ₀ = %.4e\n', omega*mu0);
fprintf('  |Lc|max / (ωμ₀) = %.4e\n', full(max(abs(MA_J1b.Lc)))/(omega*mu0));

% 背景场源的 Lc（正演无 Je）
fprintf('\n--- 背景场源 Lc ---\n');
model.param.set('adjoint_mode', '1');
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch; end
phys.feature('vec1').set('Je', {'0', '0', '0'});
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
MA_fwd = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
fprintf('  正演 |Lc_fwd| max=%.4e\n', full(max(abs(MA_fwd.Lc))));

% 零背景场 + 零 Je 的 Lc（应=0 或=ud贡献）
fprintf('\n--- 零源 Lc ---\n');
model.param.set('adjoint_mode', '0');
try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch; end
phys.feature('vec1').set('Je', {'0', '0', '0'});
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
MA_zero = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
fprintf('  零源 |Lc_zero| max=%.4e\n', full(max(abs(MA_zero.Lc))));
fprintf('  → 如果 Lc_zero≈0 则 Lc 纯粹来自物理源\n');
fprintf('  → 如果 Lc_zero≠0 则有约束贡献\n');

fprintf('\n############################################################\n');
fprintf('#  总结\n');
fprintf('#  1. Kc\\Lc 恢复误差: 待分析（看上面数据）\n');
fprintf('#  2. Je 的缩放关系: Ex∝Je线性, Ex∝ω? \n');
fprintf('#  3. Lc 的物理含义: |Lc|/(ωμ₀) 的比值\n');
fprintf('############################################################\n');

end
