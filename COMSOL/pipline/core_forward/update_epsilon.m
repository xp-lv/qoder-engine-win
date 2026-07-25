function model = update_epsilon(model, voxel, p)
%UPDATE_EPSILON 更新 COMSOL 模型中 ε_r 分布（通过插值函数 int2/int3）
%   model = update_epsilon(model, voxel, p)
%
%   原理: COMSOL GUI 中设置 ε_r = int2(x,y,z)，
%   此处通过更新 int2 数据表传递新的 ε_r 分布。
%
%   B03 扩展 (2026-06-26): 支持复数 ε_r
%     实部 → int2 (与原版一致)
%     虚部 → int3 (新增, 当 eps_r 有虚部时)
%     EMW 物理场表达式: int2(x,y,z) + i*int3(x,y,z)
%     当 eps_r 为实数时, int3=0, 表达式等价于 int2(x,y,z) (向后兼容)

fprintf('[update_epsilon] 更新 ε_r (N_voxel=%d)...\n', length(voxel.epsilon_r));

if isempty(model)
    return;
end

eps_re = real(voxel.epsilon_r(:));
eps_im = imag(voxel.epsilon_r(:));
has_imag = any(abs(eps_im) > 0);

if has_imag
    fprintf('  [update_epsilon] 复数 ε_r: Re range [%.3f, %.3f], Im range [%.3f, %.3f]\n', ...
        min(eps_re), max(eps_re), min(eps_im), max(eps_im));
end

try
    % --- int2: 实部 (与原版一致) ---
    try
        model.component('comp1').func('int2');
    catch
        model.component('comp1').func.create('int2', 'Interpolation');
        model.component('comp1').func('int2').set('nargs', '3');
        model.component('comp1').func('int2').set('source', 'table');
    end
    
    table_re = [voxel.pos, eps_re];
    csv_path = [tempname, '.csv'];
    dlmwrite(csv_path, table_re);
    model.component('comp1').func('int2').importData(csv_path);
    delete(csv_path);
    
    fprintf('  OK int2 (Re) 已更新\n');
    
    % --- int3: 虚部 (B03 新增) ---
    % 始终创建/更新 int3 (实数时全零, 保证 int2 + i*int3 = int2)
    try
        model.component('comp1').func('int3');
    catch
        model.component('comp1').func.create('int3', 'Interpolation');
        model.component('comp1').func('int3').set('nargs', '3');
        model.component('comp1').func('int3').set('source', 'table');
    end
    
    table_im = [voxel.pos, eps_im];
    csv_path_im = [tempname, '.csv'];
    dlmwrite(csv_path_im, table_im);
    model.component('comp1').func('int3').importData(csv_path_im);
    delete(csv_path_im);
    
    if has_imag
        fprintf('  OK int3 (Im) 已更新\n');
    end
    
    % 始终设置复数表达式 (int2 + i*int3, 实数时 int3=0 等价于 int2)
    set_complex_epsr_expr(model);
    
catch ME
    warning('[update_epsilon] 失败: %s', ME.message);
end

end

%% 设置 EMW 物理场的相对介电常数为复数表达式 int2 + i*int3
function set_complex_epsr_expr(model)
% H004 优化 (2026-07-24): first-call flag 跳过冗余特征枚举
% 实验执行者观察: 每次 solve_forward 调用重复枚举 7 个 EMW features (30+ 次/实验),
%   每次耗时 3-5s, 占总耗时 ~9%。特征结构首次设置后不变, int2/int3 数据已通过
%   主函数 importData 更新, 表达式字符串无需重新设置。
%   persistent 变量在同一 MATLAB 会话 (mphstart 连接期间) 可靠; MATLAB 重启后自动重置。
persistent complex_epsr_configured

% --- 后续调用: 轻量级验证后直接跳过完整枚举 ---
if complex_epsr_configured
    try
        val_check = char(model.physics('emw').feature('wee1').getString('epsilonr'));
        if ~isempty(val_check) && contains(val_check, 'int2')
            fprintf('  [set_complex] 已配置 (skip enumerate, expr active)\n');
            return;
        end
    catch
        % 检查失败, 继续走完整初始化流程
    end
    fprintf('  [set_complex] 表达式丢失, 重新配置...\n');
end

fprintf('  [set_complex] 设置 EMW 复数表达式 (首次配置, epsilonr_mat=userdef)...\n');

%% CRITICAL FIX: epsilonr_mat = "from_mat" 导致 COMSOL 从材料节点获取 ε_r,
%   完全忽略 wee1.epsilonr. 必须设为 "userdef" 才能使用 int2 插值函数.
try
    phys = model.physics('emw');
    cur_mat = char(phys.feature('wee1').getString('epsilonr_mat'));
    if ~strcmp(cur_mat, 'userdef')
        phys.feature('wee1').set('epsilonr_mat', 'userdef');
        fprintf('  OK epsilonr_mat: "%s" -> "userdef"\n', cur_mat);
    end
catch ME
    fprintf('  [WARN] epsilonr_mat set failed: %s\n', ME.message);
end

expr = 'int2(x,y,z) + i*int3(x,y,z)';
set_ok = false;

% 属性名列表 — 覆盖 COMSOL EMW 各种可能的介电常数属性
prop_names = {'epsilonr', 'epsilonrMat', 'sigma', 'mur', 'n', 'k', 'alpha', ...
    'relperm', 'relperm1', 'relperm2', 'Relepsr', 'Imepsr', 'eps', 'epsr', ...
    'epsilonrNo', 'epsilonrcoeff', 'murel', 'murelMat'};

%% Method 1: 枚举所有 EMW features — 使用 check_model_features.m 的精确模式
try
    phys = model.physics('emw');
    ft = phys.feature().tags();   % 方法调用 (带括号), 返回 Java 数组
    fc = cell(ft);                 % cell() 转换 (proven pattern)
    fprintf('  [set_complex] 发现 %d 个 EMW features\n', length(fc));

    for i = 1:length(fc)
        fn = char(fc{i});          % 转为 char 字符串
        fprintf('  [set_complex] feature[%d]: %s\n', i, fn);

        for pi = 1:length(prop_names)
            pn = prop_names{pi};
            try
                val = phys.feature(fn).getString(pn);
                val = char(val);
                if ~isempty(val) && contains(val, 'int2')
                    % Force COMSOL re-evaluation: set to dummy then back
                    % COMSOL caches expression parse tree; same string = no re-read of int3 data
                    phys.feature(fn).set(pn, '1');
                    phys.feature(fn).set(pn, expr);
                    fprintf('  OK emw/%s.%s: %s -> %s (forced re-eval)\n', fn, pn, val, expr);
                    set_ok = true;
                end
            catch
                % property 不存在, 继续
            end
        end
    end
catch ME
    fprintf('  [set_complex] Method 1 (enumerate) failed: %s\n', ME.message);
    % 诊断: 尝试另一种 tags 访问方式
    try
        emw_tags_alt = model.physics('emw').feature.tags;
        fprintf('  [set_complex] alt .feature.tags class: %s, iscell=%d\n', ...
            class(emw_tags_alt), iscell(emw_tags_alt));
    catch ME2
        fprintf('  [set_complex] alt access also failed: %s\n', ME2.message);
    end
end

%% Method 2: 直接覆盖 wee1 (Wave Equation Electric) 的 epsilonr
if ~set_ok
    fprintf('  [set_complex] Method 1 未找到 int2, 尝试直接覆盖 wee1...\n');
    % 2a: 诊断 wee1 当前 epsilonr 值
    try
        val_wee1 = model.physics('emw').feature('wee1').getString('epsilonr');
        fprintf('  [set_complex] wee1.epsilonr 当前值 = %s\n', char(val_wee1));
    catch
        fprintf('  [set_complex] wee1 无 epsilonr 属性\n');
    end
    % 2b: 直接 set wee1.epsilonr = int2 + i*int3 (覆盖材料引用)
    % Force re-evaluation: set to '1' first
    try
        model.physics('emw').feature('wee1').set('epsilonr', '1');
        model.physics('emw').feature('wee1').set('epsilonr', expr);
        fprintf('  OK emw/wee1.epsilonr = %s (override, forced re-eval)\n', expr);
        set_ok = true;
    catch ME3
        fprintf('  [set_complex] wee1.epsilonr set 失败: %s\n', ME3.message);
    end
end

%% Method 3: 检查材料节点是否引用 int2
if ~set_ok
    fprintf('  [set_complex] 尝试检查材料节点...\n');
    try
        mat_tags = model.material.tags;
        if ~iscell(mat_tags), mat_tags = cell(mat_tags); end
        fprintf('  [set_complex] 发现 %d 个材料\n', length(mat_tags));
        for mi = 1:length(mat_tags)
            mn = char(mat_tags{mi});
            fprintf('  [set_complex] material[%d]: %s\n', mi, mn);
            % 尝试设置材料的 epsilonr
            try
                model.material(mn).property('def').set('epsilonr', expr);
                fprintf('  OK material/%s.def.epsilonr = %s\n', mn, expr);
                set_ok = true;
            catch
                % 尝试其他属性名
                try
                    model.material(mn).property('RefractiveIndex').set('n', expr);
                    fprintf('  OK material/%s.RefractiveIndex.n = %s\n', mn, expr);
                    set_ok = true;
                catch
                end
            end
        end
    catch ME4
        fprintf('  [set_complex] 材料检查失败: %s\n', ME4.message);
    end
end

%% Method 4: 最后后各 — 尝试其他已知 feature 名
if ~set_ok
    fprintf('  [set_complex] 尝试其他 feature 名...\n');
    feat_names = {'eeqw1', 'weq1', 'weq2', 'med1', 'med2', 'mat1', 'mat2', ...
        'fl1', 'fl2', 'amm1', 'amm2', 'trans1', 'trans2'};
    for fi = 1:length(feat_names)
        if set_ok, break; end
        ft = feat_names{fi};
        for pi = 1:length(prop_names)
            pn = prop_names{pi};
            try
                model.physics('emw').feature(ft).set(pn, expr);
                fprintf('  OK emw/%s.%s = %s (direct set)\n', ft, pn, expr);
                set_ok = true;
                break;
            catch
            end
        end
    end
end

if set_ok
    complex_epsr_configured = true;  % H004: 标记首次配置完成, 后续调用跳过枚举
    fprintf('  [update_epsilon] 复数 ε_r 表达式已设置 (首次配置完成)\n');
else
    fprintf('  [WARN] 无法自动设置复数 ε_r. 请在 COMSOL GUI 中手动设 ε_r = int2 + i*int3\n');
end
end
