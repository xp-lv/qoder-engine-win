function result = probe_weak_form()
%PROBE_WEAK_FORM 探针：SurfaceCurrent vs SurfaceMagneticCurrentDensity 弱形式判别
%
%   验证 ⚠2：SurfaceMagneticCurrentDensity 是否内置 n̂× 算子？
%
%   判别原理：
%     如果 Ms 弱形式含 n̂×，则 Jms0=(1,0,0) 产生的有效源 ∝ n̂×(1,0,0)，
%     其方向随表面法向量旋转——与 Js0=(1,0,0)（直接耦合，无旋转）的模式不同。
%
%     具体判别（北极点 P3, n̂=(0,0,1)）：
%       Js0=(1,0,0) 直接耦合  → E ∝ (1,0,0)        [x 方向]
%       Jms0=(1,0,0) 含 n̂×    → 有效源=ẑ×x̂=ŷ      → E ∝ (0,1,0) [y 方向]
%       Jms0=(1,0,0) 不含 n̂×  → E ∝ (1,0,0)        [与 Js 相同]
%
%   三种方法：
%     A. mphphysics 弱形式表达式直接提取
%     B. COMSOL 派生变量检查（emw.Jes, emw.Jms 等）
%     C. E 场方向模式分析（核心判别：单位源 → 求解 → 提取代表性点 E 方向）
%
%   用法（需要 COMSOL Server 运行在端口 2036）：
%     >> cd COMSOL/pipline_adjoint
%     >> result = probe_weak_form();

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config', 'utils', 'core_forward', 'core_jobs', 'core_jhyp', 'core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  弱形式探针：SurfaceCurrent vs SurfaceMagneticCurrentDensity\n');
fprintf('#  验证 ⚠2：Ms 是否内置 n̂× 算子\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();

fprintf('[probe] 连接 COMSOL Server (port %d)...\n', p.comsol_port);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[probe] [FAIL] mphstart: %s\n', ME.message);
        result = struct('status', 'fail', 'reason', 'mphstart_failed');
        return;
    end
end

fprintf('[probe] 加载模型: %s\n', p.comsol_model_path);
model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

phys = model.physics('emw');

%% 2. 准备：归零背景场 + epsilon_r = 1（均匀空气，无散射体）
%    这样 E 场只来自 SurfaceCurrent/MagneticCurrent 的贡献
try phys.feature('vec1'); catch
    phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
    try phys.feature('vec1').selection().all(); catch, end
end
phys.feature('vec1').set('Je', {'0', '0', '0'});

% 归零背景场
try phys.prop('BackgroundField').set('Eb', [0 0 0]); catch, end
try model.param.set('adjoint_mode', '0'); catch, end

% epsilon_r = 1（覆盖 int1/int2 插值，确保均匀空气）
try phys.feature('wee1').set('epsilonr_mat', 'userdef'); catch, end
try phys.feature('wee1').set('epsilonr', '1'); catch, end

% 频率
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch, end

% PARDISO 求解器
try
    s1 = model.sol('sol1').feature('s1');
    try s1.feature('dDirect'); catch
        s1.create('dDirect', 'Direct');
        s1.feature('dDirect').set('linsolver', 'pardiso');
    end
    try s1.feature('fc1').set('linsolver', 'dDirect'); catch, end
catch ME
    fprintf('[probe] [WARN] PARDISO 配置: %s\n', ME.message);
end

fprintf('[probe] 模型准备完成（零背景场, epsilon_r=1）\n');

%% 3. 创建 SurfaceCurrent (sc_adj) 和 SurfaceMagneticCurrentDensity (ms_adj)
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end

phys.feature().create('sc_adj', 'SurfaceCurrent', 2);
try phys.feature('sc_adj').selection().all(); catch, end

phys.feature().create('ms_adj', 'SurfaceMagneticCurrentDensity', 2);
try phys.feature('ms_adj').selection().all(); catch, end

% 初始归零
phys.feature('sc_adj').set('Js0', {'0', '0', '0'});
phys.feature('ms_adj').set('Jms0', {'0', '0', '0'});

fprintf('[probe] sc_adj + ms_adj 已创建\n');

%% 4. 方法 A：mphphysics 弱形式提取
fprintf('\n========== 方法 A：mphphysics 弱形式提取 ==========\n');
result.methodA = struct();
try
    weak_str = mphphysics(phys, 'weak');
    fprintf('mphphysics weak 表达式:\n%s\n\n', weak_str);
    result.methodA.weak_expr = weak_str;
    result.methodA.status = 'ok';
catch ME
    fprintf('mphphysics 失败: %s\n', ME.message);
    result.methodA.weak_expr = '';
    result.methodA.status = 'fail';
    result.methodA.error = ME.message;
end

% 列出 sc_adj / ms_adj 所有属性（反射）
fprintf('--- sc_adj 属性列表 ---\n');
try
    sc_props = phys.feature('sc_adj').properties();
    n_sc = sc_props.size();
    sc_names = {};
    for i = 1:n_sc
        try
            pname = char(sc_props.get(i-1).getKey());
            sc_names{end+1} = pname;
            fprintf('  %s\n', pname);
        catch, end
    end
    result.methodA.sc_props = sc_names;
catch ME
    fprintf('  属性枚举失败: %s\n', ME.message);
end

fprintf('--- ms_adj 属性列表 ---\n');
try
    ms_props = phys.feature('ms_adj').properties();
    n_ms = ms_props.size();
    ms_names = {};
    for i = 1:n_ms
        try
            pname = char(ms_props.get(i-1).getKey());
            ms_names{end+1} = pname;
            fprintf('  %s\n', pname);
        catch, end
    end
    result.methodA.ms_props = ms_names;
catch ME
    fprintf('  属性枚举失败: %s\n', ME.message);
end

%% 5. 方法 B：COMSOL 派生变量检查
fprintf('\n========== 方法 B：派生变量检查 ==========\n');
result.methodB = struct();

% 代表性测试点（球面上 6 个点，法向量各异）
R = p.R_sphere;
test_pts = [
    R,  0,  0;       % P1: n̂=(+1,0,0) 赤道X+
    0,  R,  0;       % P2: n̂=(0,+1,0) 赤道Y+
    0,  0,  R;       % P3: n̂=(0,0,+1) 北极
   -R,  0,  0;       % P4: n̂=(-1,0,0) 赤道X-
    0, -R,  0;       % P5: n̂=(0,-1,0) 赤道Y-
    0,  0, -R;       % P6: n̂=(0,0,-1) 南极
];
test_labels = {'P1(n̂=+x)', 'P2(n̂=+y)', 'P3(n̂=+z)', 'P4(n̂=-x)', 'P5(n̂=-y)', 'P6(n̂=-z)'};

% 尝试各种 COMSOL EMW 派生变量
vars_to_try = { ...
    'emw.Jsx',  'emw.Jsy',  'emw.Jsz', ...
    'emw.Jmsx', 'emw.Jmsy', 'emw.Jmsz', ...
    'emw.Jesx', 'emw.Jesy', 'emw.Jesz', ...
    'emw.Jx',   'emw.Jy',   'emw.Jz', ...
    'emw.Jdtx', 'emw.Jdty', 'emw.Jdtz', ...
    'emw.iomega', 'emw.mu0_const' ...
};

found_vars = {};
for vi = 1:length(vars_to_try)
    vn = vars_to_try{vi};
    try
        val = mphinterp(model, vn, 'coord', test_pts');
        if all(~isnan(val)) && any(abs(val) > 0)
            fprintf('  %-16s = [%s]\n', vn, sprintf('%.4e ', val));
            found_vars{end+1} = vn;
        end
    catch
        % 变量不存在
    end
end
result.methodB.found_vars = found_vars;

if isempty(found_vars)
    fprintf('  （无可用派生变量——需要先求解一次才能定义派生变量）\n');
end

%% 6. 方法 C（核心）：E 场方向模式分析
fprintf('\n========== 方法 C：E 场方向模式分析（核心判别）==========\n');
fprintf('  原理：设置单位 Js0 或 Jms0 → 求解 → 在 6 个代表性点提取 E 场\n');
fprintf('  如果 Ms 含 n̂×，E(Ms) 方向随法向量旋转，与 E(Js) 不同\n\n');

result.methodC = struct();

% 6 个测试配置
configs = struct( ...
    'name', {'Js_x', 'Js_y', 'Js_z', 'Ms_x', 'Ms_y', 'Ms_z'}, ...
    'js0',  {{'1[A/m]','0','0'}, {'0','1[A/m]','0'}, {'0','0','1[A/m]'}, ...
             {'0','0','0'}, {'0','0','0'}, {'0','0','0'}}, ...
    'jms0', {{'0','0','0'}, {'0','0','0'}, {'0','0','0'}, ...
             {'1[V/m]','0','0'}, {'0','1[V/m]','0'}, {'0','0','1[V/m]'}} ...
);

E_results = cell(length(configs), 1);

for ci = 1:length(configs)
    cfg = configs(ci);
    fprintf('[probe] --- %s: Js0=%s, Jms0=%s ---\n', ...
        cfg.name, strrep(strjoin(cfg.js0, ','), ' ', ''), strrep(strjoin(cfg.jms0, ','), ' ', ''));

    % 设置源
    phys.feature('sc_adj').set('Js0', cfg.js0);
    phys.feature('ms_adj').set('Jms0', cfg.jms0);

    % 清解 + 求解
    try model.sol('sol1').clearSolutionData(); catch, end
    try model.sol('sol1').clearSolution(); catch, end

    try
        model.sol('sol1').runAll();
    catch ME
        fprintf('[probe] [FAIL] 求解失败 (%s): %s\n', cfg.name, ME.message);
        E_results{ci} = [];
        continue;
    end

    % 提取 E 场在代表性点
    try
        [E_vals, ~] = read_field(model, test_pts);
        E_results{ci} = E_vals;

        fprintf('  E at 6 points (real part):\n');
        for pi = 1:6
            fprintf('    %s: E = [%+.4e, %+.4e, %+.4e]  |E|=%.4e\n', ...
                test_labels{pi}, ...
                real(E_vals(pi,1)), real(E_vals(pi,2)), real(E_vals(pi,3)), ...
                abs(E_vals(pi,1)) + abs(E_vals(pi,2)) + abs(E_vals(pi,3)));
        end
    catch ME
        fprintf('[probe] [FAIL] E 场提取失败 (%s): %s\n', cfg.name, ME.message);
        E_results{ci} = [];
    end
end

%% 7. 方向模式分析
fprintf('\n========== 方向模式分析 ==========\n');

% 提取 Js 和 Ms 的 E 场结果
E_Js_x = E_results{1}; E_Js_y = E_results{2}; E_Js_z = E_results{3};
E_Ms_x = E_results{4}; E_Ms_y = E_results{5}; E_Ms_z = E_results{6};

% 分析 1: Js_x vs Ms_x 在北极 P3 (n̂=z) 的方向
fprintf('\n--- 判别 1: Js_x vs Ms_x 在 P3(n̂=+z) ---\n');
fprintf('  如果 Ms 含 n̂×，ẑ×x̂=ŷ → E(Ms_x) 应在 y 方向\n');
fprintf('  如果 Ms 不含 n̂×，E(Ms_x) 应与 E(Js_x) 同向（x 方向）\n\n');

if ~isempty(E_Js_x) && ~isempty(E_Ms_x)
    p3 = 3;  % P3 索引
    E_Js_p3 = E_Js_x(p3, :);
    E_Ms_p3 = E_Ms_x(p3, :);

    fprintf('  E(Js_x, P3) = [%+.4e, %+.4e, %+.4e]\n', ...
        real(E_Js_p3(1)), real(E_Js_p3(2)), real(E_Js_p3(3)));
    fprintf('  E(Ms_x, P3) = [%+.4e, %+.4e, %+.4e]\n', ...
        real(E_Ms_p3(1)), real(E_Ms_p3(2)), real(E_Ms_p3(3)));

    % 主要分量分析
    [max_Js, idx_Js] = max(abs(real(E_Js_p3)));
    [max_Ms, idx_Ms] = max(abs(real(E_Ms_p3)));
    dir_names = {'x', 'y', 'z'};

    fprintf('\n  E(Js_x) 主分量: %s (|%.4e|)\n', dir_names{idx_Js}, max_Js);
    fprintf('  E(Ms_x) 主分量: %s (|%.4e|)\n', dir_names{idx_Ms}, max_Ms);

    % 判别：如果 Ms 主分量是 y（与 Js 的 x 不同），说明含 n̂×
    if max_Ms > 1e-15
        if idx_Ms ~= idx_Js
            fprintf('\n  ★ Ms 主分量 (%s) ≠ Js 主分量 (%s)', dir_names{idx_Ms}, dir_names{idx_Js});
            fprintf(' → Ms 弱形式含 n̂×（方向被旋转）\n');
            result.methodC.verdict_1 = 'contains_ncross';
        else
            % 进一步检查：y 分量相对大小
            rel_y = abs(real(E_Ms_p3(2))) / max_Ms;
            rel_y_Js = abs(real(E_Js_p3(2))) / max_Js;
            if rel_y > 0.3 && rel_y > rel_y_Js * 3
                fprintf('\n  ★ Ms 的 y 分量显著（rel=%.2f vs Js rel=%.2f）', rel_y, rel_y_Js);
                fprintf(' → Ms 弱形式可能含 n̂×\n');
                result.methodC.verdict_1 = 'likely_contains_ncross';
            else
                fprintf('\n  Ms 主分量与 Js 相同 → Ms 弱形式不含 n̂×（直接耦合）\n');
                result.methodC.verdict_1 = 'no_ncross';
            end
        end
    else
        fprintf('\n  E(Ms_x, P3) ≈ 0 → 无法判定（可能 Ms 在此点贡献为零）\n');
        result.methodC.verdict_1 = 'inconclusive_zero';
    end
else
    fprintf('  [SKIP] Js_x 或 Ms_x 求解失败\n');
    result.methodC.verdict_1 = 'skip';
end

% 分析 2: Ms_z 在 P3 (n̂=z) — 如果含 n̂×，ẑ×ẑ=0，E≈0
fprintf('\n--- 判别 2: Ms_z 在 P3(n̂=+z) ---\n');
fprintf('  如果 Ms 含 n̂×，ẑ×ẑ=0 → E(Ms_z) ≈ 0\n');
fprintf('  如果 Ms 不含 n̂×，E(Ms_z) 应在 z 方向\n\n');

if ~isempty(E_Ms_z) && ~isempty(E_Js_z)
    E_Ms_z_p3 = E_Ms_z(p3, :);
    E_Js_z_p3 = E_Js_z(p3, :);

    fprintf('  E(Js_z, P3) = [%+.4e, %+.4e, %+.4e]\n', ...
        real(E_Js_z_p3(1)), real(E_Js_z_p3(2)), real(E_Js_z_p3(3)));
    fprintf('  E(Ms_z, P3) = [%+.4e, %+.4e, %+.4e]\n', ...
        real(E_Ms_z_p3(1)), real(E_Ms_z_p3(2)), real(E_Ms_z_p3(3)));

    norm_Js_z = norm(real(E_Js_z_p3));
    norm_Ms_z = norm(real(E_Ms_z_p3));

    if norm_Js_z > 1e-15
        ratio_z = norm_Ms_z / norm_Js_z;
        fprintf('\n  |E(Ms_z)| / |E(Js_z)| = %.6f\n', ratio_z);
        if ratio_z < 0.1
            fprintf('  ★ E(Ms_z) ≪ E(Js_z) → Ms 在法向量方向上不产生场 → 含 n̂×\n');
            result.methodC.verdict_2 = 'contains_ncross';
        else
            fprintf('  E(Ms_z) 与 E(Js_z) 可比 → Ms 不含 n̂×（直接耦合）\n');
            result.methodC.verdict_2 = 'no_ncross';
        end
    else
        fprintf('  E(Js_z) ≈ 0，无法计算比值\n');
        result.methodC.verdict_2 = 'inconclusive';
    end
else
    fprintf('  [SKIP] Ms_z 或 Js_z 求解失败\n');
    result.methodC.verdict_2 = 'skip';
end

% 分析 3: 全面 cos similarity 矩阵
fprintf('\n--- 判别 3: cos similarity 矩阵（Js vs Ms 各分量）---\n');
fprintf('  如果 Ms 含 n̂×，b_Ms_x 不与 b_Js_x 平行（cos < 1）\n');
fprintf('  如果 Ms 不含 n̂×，cos(b_Js_i, b_Ms_i) ≈ 1（所有 i）\n\n');

E_all = {E_Js_x, E_Js_y, E_Js_z, E_Ms_x, E_Ms_y, E_Ms_z};
names_all = {'Js_x', 'Js_y', 'Js_z', 'Ms_x', 'Ms_y', 'Ms_z'};

fprintf('  %12s', '');
for j = 1:6
    fprintf(' %10s', names_all{j});
end
fprintf('\n');

cos_matrix = zeros(6, 6);
for i = 1:6
    fprintf('  %12s', names_all{i});
    for j = 1:6
        if ~isempty(E_all{i}) && ~isempty(E_all{j})
            ci = cos_complex(E_all{i}(:), E_all{j}(:));
            cos_matrix(i, j) = ci;
            fprintf(' %10.4f', ci);
        else
            fprintf(' %10s', '--');
        end
    end
    fprintf('\n');
end
result.methodC.cos_matrix = cos_matrix;

% 关键指标：cos(Js_x, Ms_x), cos(Js_y, Ms_y), cos(Js_z, Ms_z)
fprintf('\n  关键指标（对角 Js-Ms cos）:\n');
for d = 1:3
    csim = cos_matrix(d, d+3);
    fprintf('    cos(%s, %s) = %.6f', names_all{d}, names_all{d+3}, csim);
    if csim > 0.95
        fprintf(' → 方向一致（Ms 不含 n̂×）\n');
    elseif csim < 0.3
        fprintf(' → 方向正交（Ms 含 n̂×）\n');
    else
        fprintf(' → 方向部分偏移（可能含 n̂×）\n');
    end
end

%% 8. 综合判定
fprintf('\n############################################################\n');
fprintf('#  综合判定\n');
fprintf('############################################################\n');

v1 = result.methodC.verdict_1;
v2 = result.methodC.verdict_2;

contains_ncross_count = 0;
no_ncross_count = 0;

verdicts = {v1, v2};
for vi = 1:length(verdicts)
    v = verdicts{vi};
    if contains(v, 'contains')
        contains_ncross_count = contains_ncross_count + 1;
    elseif contains(v, 'no_ncross')
        no_ncross_count = no_ncross_count + 1;
    end
end

fprintf('  判别 1 (Js_x vs Ms_x 方向): %s\n', v1);
fprintf('  判别 2 (Ms_z 在法向量方向): %s\n', v2);

if contains_ncross_count > no_ncross_count
    fprintf('\n  ★★★ 结论：SurfaceMagneticCurrentDensity 弱形式含 n̂× ★★★\n');
    fprintf('  → Ms 不做双重叉乘预处理是正确的（n̂× 在弱形式中已内置）\n');
    fprintf('  → Js/Ms 不对称处理得到验证\n');
    result.verdict = 'ms_contains_ncross';
elseif no_ncross_count > contains_ncross_count
    fprintf('\n  ★★★ 结论：SurfaceMagneticCurrentDensity 弱形式不含 n̂× ★★★\n');
    fprintf('  → Ms 需要额外 n̂× 预处理（与 Js 对称）\n');
    fprintf('  → 当前实现可能有 bug\n');
    result.verdict = 'ms_no_ncross';
else
    fprintf('\n  ⚠ 结论不确定，需进一步分析\n');
    result.verdict = 'inconclusive';
end
fprintf('############################################################\n');

%% 9. 保存 E 场数据
result.methodC.E_Js_x = E_Js_x;
result.methodC.E_Js_y = E_Js_y;
result.methodC.E_Js_z = E_Js_z;
result.methodC.E_Ms_x = E_Ms_x;
result.methodC.E_Ms_y = E_Ms_y;
result.methodC.E_Ms_z = E_Ms_z;
result.test_pts = test_pts;
result.test_labels = test_labels;

%% 10. 恢复模型
fprintf('\n[probe] 恢复模型...\n');
try phys.feature('sc_adj').set('Js0', {'0', '0', '0'}); catch, end
try phys.feature('ms_adj').set('Jms0', {'0', '0', '0'}); catch, end
try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end
try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
try model.param.set('adjoint_mode', '1'); catch, end
try phys.feature('wee1').set('epsilonr', 'int1(x,y,z) + i*int2(x,y,z)'); catch, end

%% 保存结果
result.status = 'ok';
save(fullfile(p.dir_result, 'probe_weak_form_result.mat'), 'result');
fprintf('\n[probe] 结果已保存: data/results/probe_weak_form_result.mat\n');

end

%% ====== 辅助函数 ======
function csim = cos_complex(a, b)
%COS_COMPLEX 复向量的 Hermitian cos similarity
%   csim = |a^H · b| / (|a| · |b|)
%   csim ∈ [0, 1]，1 表示方向完全一致
    na = norm(a);
    nb = norm(b);
    if na < eps || nb < eps
        csim = 0;
    else
        csim = abs(a' * b) / (na * nb);
    end
end
