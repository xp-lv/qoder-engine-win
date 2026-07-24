
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');

fprintf('\n[api] === 1. func API ===\n');

% 1.1 列出 func.tags
fprintf('[api] func.tags class: %s\n', class(m.func.tags));
fprintf('[api] func.tags: '); disp(m.func.tags);

% 1.2 取 int2 各种方式
fprintf('\n[api] --- access int2 ---\n');
fprintf('[api] 1.2.1 m.func(''int2''): class=%s\n', class(m.func('int2')));
try, fprintf('  getString: %s\n', char(m.func('int2').getString())); catch ME, fprintf('  no getString: %s\n', ME.message); end
try, fprintf('  getType: %s\n', char(m.func('int2').getType)); catch ME, fprintf('  no getType: %s\n', ME.message); end
try, fprintf('  type: %s\n', char(m.func('int2').type)); catch ME, fprintf('  no type attr: %s\n', ME.message); end
try, fprintf('  tag: %s\n', char(m.func('int2').tag)); catch ME, fprintf('  no tag attr: %s\n', ME.message); end
try, fprintf('  label: %s\n', char(m.func('int2').label)); catch ME, fprintf('  no label: %s\n', ME.message); end

% 1.3 删除方式
fprintf('\n[api] --- remove int2 ---\n');
fprintf('[api] 1.3.1 m.func(''int2'').remove:\n');
try, m.func('int2').remove; fprintf('  OK\n'); catch ME, fprintf('  FAIL: %s\n', ME.message); end

fprintf('[api] 1.3.2 m.func.remove(''int2''):\n');
try, m.func.remove('int2'); fprintf('  OK\n'); catch ME, fprintf('  FAIL: %s\n', ME.message); end

fprintf('[api] 1.3.3 m.func().remove(''int2''):\n');
try, m.func().remove('int2'); fprintf('  OK\n'); catch ME, fprintf('  FAIL: %s\n', ME.message); end

fprintf('[api] 1.3.4 ModelUtil.remove(m.func, ''int2''):\n');
try, ModelUtil.remove(m.func, 'int2'); fprintf('  OK\n'); catch ME, fprintf('  FAIL: %s\n', ME.message); end

% 检查是否删了
fprintf('[api] after remove attempts, func.tags: '); disp(m.func.tags);

fprintf('\n[api] === 2. physics feature API ===\n');
fprintf('[api] m.physics(''emw'') class: %s\n', class(m.physics('emw')));
fprintf('[api] emw.feature(''wee1'') class: %s\n', class(m.physics('emw').feature('wee1')));
try, fprintf('[api] wee1.tag: %s\n', char(m.physics('emw').feature('wee1').tag)); catch ME, fprintf('  no tag: %s\n', ME.message); end
try, fprintf('[api] wee1.type: %s\n', char(m.physics('emw').feature('wee1').type)); catch ME, fprintf('  no type: %s\n', ME.message); end
try, fprintf('[api] wee1.getType(): %s\n', char(m.physics('emw').feature('wee1').getType())); catch ME, fprintf('  no getType: %s\n', ME.message); end

% 试 set/get
fprintf('\n[api] --- set/get epsilonr ---\n');
try
    old_mat = m.physics('emw').feature('wee1').get('epsilonr_mat');
    fprintf('[api] get(''epsilonr_mat''): %s\n', char(old_mat));
catch ME
    fprintf('[api] get(''epsilonr_mat'') fail: %s\n', ME.message);
end
try
    m.physics('emw').feature('wee1').set('epsilonr_mat', 'userdef');
    fprintf('[api] set epsilonr_mat=userdef: OK\n');
catch ME
    fprintf('[api] set epsilonr_mat fail: %s\n', ME.message);
end
try
    m.physics('emw').feature('wee1').set('epsilonr', 'int2(x,y,z)');
    fprintf('[api] set epsilonr=int2(x,y,z): OK\n');
catch ME
    fprintf('[api] set epsilonr fail: %s\n', ME.message);
end

% 3. emw 顶层属性（不是 feature）
fprintf('\n[api] === 3. emw prop ===\n');
fprintf('[api] emw.prop class: %s\n', class(m.physics('emw').prop));
try, fprintf('[api] prop.tags: '); disp(m.physics('emw').prop.tags); catch ME, fprintf('[api] prop.tags fail: %s\n', ME.message); end
try
    sf = m.physics('emw').prop('BackgroundField').get('SolveFor');
    fprintf('[api] BackgroundField.SolveFor: %s\n', char(sf));
catch ME
    fprintf('[api] BackgroundField fail: %s\n', ME.message);
end

clearvars m;
fprintf('\n[api] === DONE ===\n');
