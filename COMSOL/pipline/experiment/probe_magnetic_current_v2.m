function probe_magnetic_current_v2()
%PROBE_MAGNETIC_CURRENT_V2 精简实测（修正 API + 避免超时）
%
%   已知（上一轮探测）：
%     - Feature 创建 + Jms0 读写 + 7 属性 ✓
%     - PARDISO + clearSolutionData 路径下可求解（此时 ms1 带非零磁流仍在）✓
%
%   本轮目标：
%     1. 用正确 remove API（emw.feature().remove 而非 delete）
%     2. 带磁流求解（PARDISO + clearSolutionData）
%     3. 场输出验证（emw.Ex/Ey/Ez + coord 转置）

fprintf('\n========== [PROBE-V2] SurfaceMagneticCurrentDensity 精简实测 ==========\n');

%% 0. 初始化
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
base_path = fileparts(fileparts(mfilename('fullpath')));
model_path = fullfile(base_path, '..', 'livelink_model.mph');
fprintf('[PROBE-V2] model: %s\n', model_path);

%% 1. 连接 + 加载
fprintf('[PROBE-V2] 连接 COMSOL Server...\n');
try
    mphstart(2036);
    fprintf('[PROBE-V2] mphstart(2036) OK\n');
catch ME_conn
    if contains(ME_conn.message, 'Already connected')
        fprintf('[PROBE-V2] Already connected (OK)\n');
    else
        fprintf('[PROBE-V2] [FAIL] mphstart: %s\n', ME_conn.message);
        return;
    end
end

fprintf('[PROBE-V2] 加载模型...\n');
model = mphload(model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end
emw = model.physics('emw');
fprintf('[PROBE-V2] 模型加载完成\n');

%% 2. 创建 ms1 + 设 Jms0 + selection.all
ms1_tag = 'ms1_v2';
try emw.feature().remove(ms1_tag); catch, end  % 文档第 3.4 节正确 API
emw.feature().create(ms1_tag, 'SurfaceMagneticCurrentDensity', 2);
emw.feature(ms1_tag).set('Jms0', {'1.0', '0.5', '-0.3'});
try emw.feature(ms1_tag).selection().all(); catch, end
val = emw.feature(ms1_tag).getString('Jms0');
fprintf('[PROBE-V2] [OK] ms1 创建+设值 OK (Jms0=%s)\n', char(val));

%% 3. 求解（PARDISO + clearSolutionData —— 上一轮验证的成功路径）
fprintf('[PROBE-V2] 求解中（PARDISO + clearSolutionData）...\n');
solve_ok = false;
try
    s1 = model.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch, s1.create('dDirect','Direct'); s1.feature('dDirect').set('linsolver','pardiso'); end
    try s1.feature('fc1').set('linsolver','dDirect'); catch, end
    try model.sol('sol1').clearSolutionData(); catch, end
    model.sol('sol1').runAll();
    solve_ok = true;
    fprintf('[PROBE-V2] [OK] ★带磁流求解成功★\n');
catch ME
    fprintf('[PROBE-V2] [WARN] PARDISO 失败: %s\n', ME.message);
    try
        model.sol('sol1').runAll();
        solve_ok = true;
        fprintf('[PROBE-V2] [OK] 直接 runAll 成功\n');
    catch ME2
        fprintf('[PROBE-V2] [WARN] runAll 也失败: %s\n', ME2.message);
    end
end

%% 4. 场输出验证
field_nonzero = false;
if solve_ok
    try
        test_pts = [0.0, 0.0, 0.0; 0.05, 0.0, 0.0; 0.0, 0.05, 0.0; 0.0, 0.0, 0.05];
        coord_t = test_pts';
        Ex = mphinterp(model, 'emw.Ex', 'coord', coord_t);
        Ey = mphinterp(model, 'emw.Ey', 'coord', coord_t);
        Ez = mphinterp(model, 'emw.Ez', 'coord', coord_t);
        E_test = [Ex(:), Ey(:), Ez(:)];
        E_mag = vecnorm(E_test, 2, 2);
        fprintf('[PROBE-V2] 球心附近电场:\n');
        for i = 1:size(test_pts,1)
            fprintf('   (%.3f,%.3f,%.3f): |E|=%.4e\n', test_pts(i,1),test_pts(i,2),test_pts(i,3), E_mag(i));
        end
        if any(E_mag > 1e-10)
            field_nonzero = true;
            fprintf('[PROBE-V2] [OK] ★磁流源产生非零电场★\n');
        else
            fprintf('[PROBE-V2] [WARN] 场为零\n');
        end
    catch ME
        fprintf('[PROBE-V2] [WARN] 场评估失败: %s\n', ME.message);
    end
end

%% 5. 清理
try emw.feature().remove(ms1_tag); catch, end

%% 6. 结论
fprintf('\n========== [PROBE-V2] 结论（对照文档第 1 节） ==========\n');
fprintf('| 验证项                | 结果  |\n');
fprintf('|-----------------------|-------|\n');
fprintf('| Feature 创建 (dim=2)  |  OK  |\n');
fprintf('| 设置 Jms0 + 读回      |  OK  |\n');
fprintf('| 求解器兼容            | %s |\n', ternary(solve_ok, ' OK ', 'FAIL'));
fprintf('| 物理场输出 (非零场)   | %s |\n', ternary(field_nonzero, ' OK ', 'SKIP'));
fprintf('================================================\n\n');

end

function s = ternary(cond, a, b)
if cond, s = a; else, s = b; end
end
