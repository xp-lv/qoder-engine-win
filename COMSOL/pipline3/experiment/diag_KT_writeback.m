function diag_KT_writeback()
%DIAG_KT_WRITEBACK 测试多种方法将 K^T 解写回 COMSOL 模型
%   目标: 让 mphinterp 能读取 K^T 求解的 lambda

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  K^T 解写回 COMSOL 方法测试\n');
fprintf('############################################################\n\n');

%% 1. 初始化 + 正演
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

% 正演 eps_r=3（均匀实数，简化问题）
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

% 导出 K 和 L
fprintf('导出 Kc, Lc...\n');
MA = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
Kc = MA.Kc; Lc = MA.Lc;
fprintf('Kc: %dx%d, Lc: %dx%d\n', size(Kc,1), size(Kc,2), size(Lc,1), size(Lc,2));
fprintf('Null: %dx%d, ud: %dx%d, uscale: %dx%d\n', ...
    size(MA.Null,1), size(MA.Null,2), size(MA.ud,1), size(MA.ud,2), ...
    size(MA.uscale,1), size(MA.uscale,2));

% 检查 Dofs 输出
% Dofs 不是 mphmatrix 的有效 out 参数

% K\E (正演解)
Uc_fwd = Kc \ Lc;
U_fwd = MA.Null * Uc_fwd + MA.ud;
U_full_fwd = U_fwd .* MA.uscale;
fprintf('正演 U_full: %d elements, |U| range [%.4e, %.4e]\n', ...
    length(U_full_fwd), full(min(abs(U_full_fwd))), full(max(abs(U_full_fwd))));

% K^T\E (伴随解)
Uc_adj = Kc' \ Lc;
U_adj = MA.Null * Uc_adj + MA.ud;
U_full_adj = U_adj .* MA.uscale;
fprintf('伴随 U_full: %d elements, |U| range [%.4e, %.4e]\n', ...
    length(U_full_adj), full(min(abs(U_full_adj))), full(max(abs(U_full_adj))));

%% 方案 1: mphsetu (标准 API)
fprintf('\n=== 方案 1: mphsetu ===\n');
try
    mphsetu(model, 'sol1', U_full_adj);
    fprintf('  mphsetu 成功!\n');
    % 验证: 读取一个点
    pt = voxel.pos(inner_idx(1), :)';
    test_val = mphinterp(model, 'emw.Ez', 'coord', pt);
    fprintf('  验证 mphinterp: Ez(测试点) = %.4e\n', test_val(1));
catch ME
    fprintf('  mphsetu 失败: %s\n', ME.message);
end

%% 方案 2: model.sol.setU + createSolution
fprintf('\n=== 方案 2: setU + createSolution ===\n');
try
    model.sol('sol1').setU(U_full_adj);
    model.sol('sol1').createSolution();
    fprintf('  setU + createSolution 成功!\n');
catch ME
    fprintf('  setU 失败: %s\n', ME.message);
end

%% 方案 3: 用 solution data API
fprintf('\n=== 方案 3: setSolutionData ===\n');
try
    % 尝试通过 Java API 设置
    sol = model.sol('sol1');
    % 获取 solution feature
    sf = sol.feature('s1');
    fprintf('  求解器 feature 类: %s\n', char(sf.getClass().getSimpleName()));
    % 尝试 setSolutionData
    try
        sol.setSolutionData(U_full_adj);
        fprintf('  setSolutionData 成功!\n');
    catch ME
        fprintf('  setSolutionData 失败: %s\n', ME.message);
    end
catch ME
    fprintf('  方案3 失败: %s\n', ME.message);
end

%% 方案 4: 用 mphmatrix 的 'matrix' 输出直接从 DOF 到坐标映射
fprintf('\n=== 方案 4: mphmatrix + U_full 直接映射 ===\n');
% mphinterp 本质是: 给定坐标 → 找到包含该坐标的单元 → 用形函数插值
% 但我们可以用 mphmatrix 提取坐标→DOF 的映射矩阵
try
    % 尝试提取 maphmatrix 的完整 DOF 信息
    MA2 = mphmatrix(model, 'sol1', ...
        'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
        'initmethod', 'sol', 'initsol', 'sol1', ...
        'symmetry', 'off');
    fprintf('  mphmatrix 输出字段: %s\n', strjoin(fieldnames(MA2), ', '));
catch ME
    fprintf('  方案4 失败: %s\n', ME.message);
end

%% 方案 5: 直接用 mphstate (提取解向量) 然后写回
fprintf('\n=== 方案 5: mphstate ===\n');
try
    % 先用 mphstate 提取当前解（看格式）
    state_fwd = mphstate(model, 'sol1', 'fieldname', {'emw.Ex', 'emw.Ey', 'emw.Ez'});
    fprintf('  mphstate 返回: %d DOF\n', length(state_fwd));
    fprintf('  |state_fwd| range [%.4e, %.4e]\n', min(abs(state_fwd)), max(abs(state_fwd)));
catch ME
    fprintf('  mphstate 失败: %s\n', ME.message);
end

%% 方案 6: 用 study.run 重新求解（但用转置的系统矩阵）
fprintf('\n=== 方案 6: runAll + 后处理 ===\n');
% runAll 解的是 K λ = Lc（不精确的伴随）
% 但我们可以提取 runAll 的解，然后在 MATLAB 中做修正
try
    model.sol('sol1').runAll();
    
    % 提取 runAll 的解（DOF 空间）
    state_runAll = mphstate(model, 'sol1', 'fieldname', {'emw.Ex', 'emw.Ey', 'emw.Ez'});
    fprintf('  runAll 解: %d DOF, |state| range [%.4e, %.4e]\n', ...
        length(state_runAll), min(abs(state_runAll)), max(abs(state_runAll)));
    
    % 对比 K\Kc 和 K^T\Kc 的解（在 Kc 空间）
    fprintf('\n  Kc 空间对比:\n');
    fprintf('    |Uc_fwd| (K\\Lc)  range [%.4e, %.4e]\n', min(abs(Uc_fwd)), max(abs(Uc_fwd)));
    fprintf('    |Uc_adj| (K''\\Lc) range [%.4e, %.4e]\n', min(abs(Uc_adj)), max(abs(Uc_adj)));
    fprintf('    |Uc_fwd - Uc_adj| / |Uc_fwd| = %.4f%%\n', ...
        norm(Uc_fwd - Uc_adj) / norm(Uc_fwd) * 100);
    
catch ME
    fprintf('  方案6 失败: %s\n', ME.message);
end

%% 方案 7: 用 model.sol('sol1').setU with tlist
fprintf('\n=== 方案 7: setU with tlist parameter ===\n');
try
    % 有些 COMSOL 版本需要 tlist 参数
    sol = model.sol('sol1');
    sol.setU(0, U_full_adj);  % 尝试带时间索引
    fprintf('  setU(0, U) 成功!\n');
catch ME
    fprintf('  setU(0,U) 失败: %s\n', ME.message);
    try
        sol.setU(1, U_full_adj);
        fprintf('  setU(1, U) 成功!\n');
    catch ME2
        fprintf('  setU(1,U) 失败: %s\n', ME2.message);
    end
end

%% 方案 8: 用 SolutionMatrix approach
fprintf('\n=== 方案 8: mphsetmatrix ===\n');
try
    mphsetmatrix(model, 'sol1', 'U', U_full_adj);
    fprintf('  mphsetmatrix 成功!\n');
catch ME
    fprintf('  mphsetmatrix 失败: %s\n', ME.message);
end

fprintf('\n############################################################\n');
fprintf('#  结论\n');
fprintf('#  如果以上方案都失败，需要用纯 MATLAB FEM 形函数\n');
fprintf('#  从 DOF 解 U_full 直接插值到体素坐标。\n');
fprintf('############################################################\n');

end

function s = matstr(v)
    if isvector(v)
        s = sprintf('%dx%d', v(1), v(end));
    else
        s = sprintf('%dx%d', v(1), v(2));
    end
end
