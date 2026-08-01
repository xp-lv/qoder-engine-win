function probe_cvar()
% 探测控制变量场的正确属性
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
try; ts=ModelUtil.tags(); for i=1:length(ts), ModelUtil.remove(char(ts(i))); end; catch; end
model = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline3\2layer_sensitive.mph');

fprintf('=== cvf1 属性 ===\n');
cvf1 = model.component('comp1').common('cvf1');
try
    props = cvf1.properties();
    fprintf('  properties: ');
    for i=1:length(props), fprintf('%s ', char(props(i))); end
    fprintf('\n');
catch ME
    fprintf('  properties FAIL: %s\n', ME.message);
end

% 逐个测试常见属性名
test_props = {'name', 'init', 'initialvalue', 'expr', 'value', 'default', ...
    'lo', 'hi', 'scale', 'dispname', 'dvar'};
for i = 1:length(test_props)
    pn = test_props{i};
    try
        v = cvf1.get(pn);
        fprintf('  %s = %s\n', pn, char(v));
    catch
        fprintf('  %s: N/A\n', pn);
    end
end

% 列出 common 下所有节点
fprintf('\n=== common 节点 ===\n');
try
    ct = model.component('comp1').common().tags();
    for i=1:length(ct)
        t = char(ct(i));
        try name = model.component('comp1').common(t).get('name'); catch; name='?'; end
        fprintf('  %s: name=%s\n', t, char(name));
    end
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

try ModelUtil.remove('Model'); catch; end
end
