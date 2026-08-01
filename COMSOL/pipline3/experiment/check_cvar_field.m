function check_cvar_field()
% 检查 Control Variable Field 功能是否可用

addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
try; ts=ModelUtil.tags(); for i=1:length(ts), ModelUtil.remove(char(ts(i))); end; catch; end

model = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline3\2layer_sensitive.mph');

% 检查许可证
fprintf('=== 检查许可证 ===\n');
try
    products = ModelUtil.getLicensedProducts();
    if isempty(products)
        fprintf('  无额外许可证\n');
    else
        for i=1:length(products)
            fprintf('  %s\n', char(products(i)));
        end
    end
catch ME
    fprintf('  getLicensedProducts: %s\n', ME.message);
end

% 列出 comp1 的所有子节点类型
fprintf('\n=== comp1 子节点 ===\n');
try
    ct = model.component('comp1').feature();
    fprintf('  feature tags: ');
    for i=1:length(ct), fprintf('%s ', char(ct(i))); end
    fprintf('\n');
catch; end

% 尝试各种方式创建 Control Variable Field
fprintf('\n=== 尝试创建 Control Variable Field ===\n');

% 方式1: component.create
try
    model.component('comp1').create('cvar1', 'ControlVariableField', 3);
    fprintf('  方式1 (component.create): OK!\n');
catch ME
    fprintf('  方式1 FAIL: %s\n', ME.message);
end

% 方式2: component.prop.create
try
    model.component('comp1').prop.create('cvar2', 'ControlVariableField', 3);
    fprintf('  方式2 (prop.create): OK!\n');
catch ME
    fprintf('  方式2 FAIL: %s\n', ME.message);
end

% 方式3: definitions (varList)
try
    model.component('comp1').varList.create('cvar3', 'ControlVariableField', 3);
    fprintf('  方式3 (varList): OK!\n');
catch ME
    fprintf('  方式3 FAIL: %s\n', ME.message);
end

% 方式4: 查找正确的 API
fprintf('\n=== 查找 API ===\n');
try
    methods = model.component('comp1').methods;
    cv_methods = methods(contains(methods, 'ontrol') | contains(methods, 'ariable') | contains(methods, 'arList'));
    fprintf('  Control/Variable methods: %s\n', strjoin(cv_methods, ', '));
catch ME
    fprintf('  methods FAIL: %s\n', ME.message);
end

% 尝试 Optimization 接口
fprintf('\n=== 尝试 Optimization 接口 ===\n');
try
    model.component('comp1').opt.create('opt1', 'Optimization');
    fprintf('  opt.create: OK!\n');
catch ME
    fprintf('  opt FAIL: %s\n', ME.message);
end

% 检查 comp1 下有哪些节点类型可以创建
fprintf('\n=== comp1 可创建的节点类型 ===\n');
node_types = {'coordSystem', 'material', 'physics', 'mesh', 'func', 'cpl', ...
    'varList', 'probe', 'opt', 'geom', 'view', 'dataset'};
for i = 1:length(node_types)
    nt = node_types{i};
    try
        % 尝试访问
        tmp = model.component('comp1').(nt);
        fprintf('  %s: exists\n', nt);
    catch
        % 尝试创建（只是检查是否可用，不真正创建）
        fprintf('  %s: not accessible\n', nt);
    end
end

try ModelUtil.remove('Model'); catch; end
end
