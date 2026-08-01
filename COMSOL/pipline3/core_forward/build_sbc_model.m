function model = build_sbc_model(p)
%BUILD_SBC_MODEL 构建 SBC（散射边界条件）模型，替代 PML
%   K 保持对称（无 PML 复坐标变换）

import com.comsol.model.*
import com.comsol.model.util.*

fprintf('[build_sbc_model] 构建 SBC 模型（无 PML）\n');

%% 1. 创建模型
try ModelUtil.remove('Model'); catch; end
model = ModelUtil.create('Model');
model.modelNode.create('comp1', true);

%% 2. 几何：单层球（散射体 + 空气，无 PML 层）
geom = model.geom.create('geom1', 3);
geom.model('comp1');
sph = geom.create('sph1', 'Sphere');
sph.set('r', num2str(p.R_air));  % 只到 R_air，不加 PML 层
% 用 layer 分出内球（散射体区域）
sph.setIndex('layer', num2str(p.R_air - p.R_inner), 0);  % 空气层厚度
geom.run;
fprintf('  几何: R=%.3f（散射体+空气，无PML）\n', p.R_air);

%% 3. 物理：EMW 频域 + 散射场公式
phys = model.physics.create('emw', 'ElectromagneticWaves', 'geom1');
phys.model('comp1');

% 散射场公式（背景平面波）
phys.create('sctr1', 'Scattering', 2);
theta = acosd(p.background.k_direction(3));
phi = atan2d(p.background.k_direction(2), p.background.k_direction(1));
try
    phys.feature('sctr1').set('theta0', num2str(theta));
    phys.feature('sctr1').set('phi0', num2str(phi));
catch
end
try phys.feature('sctr1').selection.all(); catch; end

% ε_r 插值函数
model.component('comp1').func.create('int1', 'Interpolation');
model.component('comp1').func('int1').set('nargs', '3');
model.component('comp1').func('int1').set('source', 'table');
init_pts = [0 0 0 1; 0.01 0 0 1; 0 0.01 0 1; 0 0 0.01 1];
tmp = [tempname, '.csv']; dlmwrite(tmp, init_pts);
model.component('comp1').func('int1').importData(tmp); delete(tmp);

model.component('comp1').func.create('int2', 'Interpolation');
model.component('comp1').func('int2').set('nargs', '3');
model.component('comp1').func('int2').set('source', 'table');
init_pts_im = [0 0 0 0; 0.01 0 0 0; 0 0.01 0 0; 0 0 0.01 0];
tmp2 = [tempname, '.csv']; dlmwrite(tmp2, init_pts_im);
model.component('comp1').func('int2').importData(tmp2); delete(tmp2);

try
    phys.feature('wee1').set('epsilonr_mat', 'userdef');
    phys.feature('wee1').set('epsilonr', 'int1(x,y,z) + i*int2(x,y,z)');
catch
end

% ExternalCurrentDensity（伴随源注入）
phys.create('vec1', 'ExternalCurrentDensity', 3);
phys.feature('vec1').set('Je', {'0' '0' '0'});
try phys.feature('vec1').selection.all(); catch; end

%% 4. 散射边界条件替代 PML
% COMSOL EMW 中散射边界条件的 feature ID 为 'ScatteringBoundaryCondition'
% 但不同版本可能不同，尝试多种名称
sbc_created = false;
for sbc_id = {'ScatteringBoundaryCondition', 'ScatterBC', 'LowReflectingBoundary'}
    try
        phys.create('sbc1', sbc_id{1}, 2);
        sbc_created = true;
        fprintf('  SBC feature: %s\n', sbc_id{1});
        break;
    catch
        continue;
    end
end
if sbc_created
    try phys.feature('sbc1').selection.all(); catch; end
    fprintf('  SBC 已添加（替代 PML）\n');
else
    fprintf('  [WARN] SBC feature 创建失败，使用散射场公式作为隐式吸收\n');
end

%% 5. 材料
mat = model.material.create('mat1', 'Common', 'comp1');
mat.propertyGroup('def').set('relpermittivity', {'1'});
mat.propertyGroup('def').set('relpermeability', {'1'});
mat.propertyGroup('def').set('electricconductivity', {'0'});

%% 6. 网格
mesh = model.mesh.create('mesh1', 'geom1');
try
    mesh.create('size1', 'Size');
    mesh.feature('size1').set('hmax', '0.015');
    mesh.feature('size1').set('hmin', '0.005');
    mesh.feature('size1').set('custom', 'on');
catch
end
mesh.run;
fprintf('  网格划分完成\n');

%% 7. Study + Solver
study = model.study.create('std1');
freq_feat = study.create('freq', 'Frequency');
freq_feat.set('plist', sprintf('%g[Hz]', p.freq));
freq_feat.setSolveFor('/physics/emw', true);

sol = model.sol.create('sol1');
sol.study('std1');
sol.attach('std1');
sol.create('st1', 'StudyStep');
sol.feature('st1').set('study', 'std1');
sol.feature('st1').set('studystep', 'freq');
sol.create('v1', 'Variables');
sol.feature('v1').set('control', 'freq');
stat = sol.create('s1', 'Stationary');
stat.set('stol', 0.01);
stat.create('p1', 'Parametric');
stat.feature('p1').set('pname', {'freq'});
stat.feature('p1').set('plistarr', {sprintf('%g[Hz]', p.freq)});
try stat.feature('p1').feature.remove('pDef'); catch; end
try
    stat.create('dDirect', 'Direct');
    stat.feature('dDirect').set('linsolver', 'pardiso');
    stat.create('fc1', 'FullyCoupled');
    stat.feature('fc1').set('linsolver', 'dDirect');
catch
end

%% 8. 参数
model.param.set('freq', num2str(p.freq));
model.param.set('adjoint_mode', '1');

try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end

fprintf('[build_sbc_model] SBC 模型构建完成\n');
end
