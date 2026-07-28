% 从 COMSOL 模型中提取 SurfaceCurrent/MagneticCurrent 的弱形式
% 通过 mphinspect 或 model class 反射获取
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline');
addpath('config','utils');

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        error('mphstart: %s', ME.message);
    end
end

model = mphload(fullfile(pwd, '..', 'livelink_model.mph'));
phys = model.physics('emw');

% 创建 SurfaceCurrent 和 SurfaceMagneticCurrent
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end

phys.feature().create('sc_adj', 'SurfaceCurrent', 2);
sc = phys.feature('sc_adj');
try sc.selection().all(); catch, end
sc.set('Js0', {'1[A/m]', '0', '0'});  % 测试值

phys.feature().create('ms_adj', 'SurfaceMagneticCurrentDensity', 2);
ms = phys.feature('ms_adj');
try ms.selection().all(); catch, end
ms.set('Jms0', {'1[V/m]', '0', '0'});

% 尝试用 mphgetkeys 或其他方式获取弱形式
fprintf('\n========== SurfaceCurrent (sc_adj) ==========\n');

% 方法 1: 尝试获取 'contrib' 或 'weakcontribution'
fields_to_try = {'weak', 'weakcontribution', 'contrib', 'source', ...
                 'equation', 'expression', 'sourcevec', 'framework', ...
                 'selectionmethod', 'activeinweak', 'input Jes', 'input Jms'};
for i = 1:length(fields_to_try)
    try
        val = sc.getString(fields_to_try{i});
        fprintf('  %s = %s\n', fields_to_try{i}, val);
    catch
    end
end

% 方法 2: 列出所有属性名
fprintf('\nsc_adj all property names:\n');
plist = sc.properties();
n = plist.size();
for i = 1:n
    try
        name = plist.get(i-1).getKey();
        fprintf('  %s\n', name);
    catch
    end
end

fprintf('\n========== SurfaceMagneticCurrent (ms_adj) ==========\n');
for i = 1:length(fields_to_try)
    try
        val = ms.getString(fields_to_try{i});
        fprintf('  %s = %s\n', fields_to_try{i}, val);
    catch
    end
end

fprintf('\nms_adj all property names:\n');
plist2 = ms.properties();
n2 = plist2.size();
for i = 1:n2
    try
        name = plist2.get(i-1).getKey();
        fprintf('  %s\n', name);
    catch
    end
end

% 方法 3: mphphysics 获取弱形式
fprintf('\n========== mphphysics 尝试 ==========\n');
try
    weak_expr = mphphysics(phys, 'weak');
    fprintf('  mphphysics weak = %s\n', weak_expr);
catch ME
    fprintf('  mphphysics failed: %s\n', ME.message);
end

% 方法 4: 直接查 model class 的 variables
fprintf('\n========== model variables 检查 ==========\n');
try
    % 检查 emw.Jes (表面电流产生的等效源)
    vars = {'emw.Jesx', 'emw.Jesy', 'emw.Jesz', ...
            'emw.Jmsx', 'emw.Jmsy', 'emw.Jmsz', ...
            'emw.Jx', 'emw.Jy', 'emw.Jz'};
    inner_pos = [0; 0; 0]';
    for vi = 1:length(vars)
        try
            val = mphinterp(model, vars{vi}, 'coord', inner_pos);
            fprintf('  %s = %.6e\n', vars{vi}, val);
        catch
            fprintf('  %s: not available\n', vars{vi});
        end
    end
catch ME
    fprintf('  model vars check failed: %s\n', ME.message);
end

% 方法 5: 检查 model.xml 或 model 的 Java class 层级
fprintf('\n========== Feature class info ==========\n');
fprintf('  sc_adj class: %s\n', class(sc));
fprintf('  sc_adj super: %s\n', class(sc.getImplementation()));
try
    fprintf('  sc_adj type: %s\n', sc.getType());
catch
end

% 清理
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end

fprintf('\n========== 完成 ==========\n');
