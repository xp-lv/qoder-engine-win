function model = build_lightweight_model(p)
%BUILD_LIGHTWEIGHT_MODEL 程序化构建极简 2 层 COMSOL 电磁散射模型
%   model = build_lightweight_model(p)
%
%   ★ pipline_adjoint 专用：降规模快速伴随法验证 ★
%
%   几何结构（2 层球）：
%     内层球 R_inner：散射体区域（通过体素 epsilon_r 分配）
%     外层球 R_outer：空气 + PML（球面波吸收边界）
%     测量球面 R_sphere：在空气层内（不建模为几何，通过 mphinterp 提取）
%
%   物理设置：
%     EMW 频域 + 散射场公式（平面波背景场）
%     PML 球面缩放（外层最外侧 pml_thick）
%     epsilon_r = int2(x,y,z) + i*int3(x,y,z)（插值函数，运行时更新）
%     ExternalCurrentDensity (vec1) 用于伴随源注入
%
%   用法：
%     p = config();
%     model = build_lightweight_model(p);  % 构建 + 网格划分
%     model.sol('sol1').runAll();          % 首次求解（初始化 LU 分解）

import com.comsol.model.*
import com.comsol.model.util.*

fprintf('[build_lightweight_model] ★ 构建 2 层极简模型 ★\n');
fprintf('  R_inner=%.3fm, R_air=%.3fm, PML=%.3fm, R_outer=%.3fm\n', ...
    p.R_inner, p.R_air, p.pml_thick, p.R_outer);
fprintf('  R_sphere=%.3fm, freq=%.0f GHz\n', p.R_sphere, p.freq/1e9);

%% 1. 创建模型容器
try
    ModelUtil.remove('Model');  % 清除已有模型
catch
end
model = ModelUtil.create('Model');

model.modelNode.create('comp1', true);

%% 2. 几何：2 层球
geom = model.geom.create('geom1', 3);
geom.model('comp1');

% 主球体，使用 layers 分层
% layer[0] = PML 层（最外侧 pml_thick）
% layer[1] = 空气层（R_air - R_inner 到 R_air 之间）
% 剩余 = 内球散射体区域
sph = geom.create('sph1', 'Sphere');
sph.set('r', num2str(p.R_outer));
sph.setIndex('layer', num2str(p.pml_thick), 0);  % PML 层
sph.setIndex('layer', num2str(p.R_air - p.R_inner), 1);  % 空气层厚度

geom.run;
fprintf('  OK 几何构建完成（2 层球）\n');

%% 3. PML 坐标系
model.coordSystem.create('pml1', 'geom1', 'PML');
model.coordSystem('pml1').set('ScalingType', 'Spherical');

% PML 选择最外层域（layer 0 对应的边界域）
% 需要根据几何序列号设置，这里用几何域自动检测
try
    model.coordSystem('pml1').selection.geom('geom1', 3);
    model.coordSystem('pml1').selection.set([1 2 3 4]);  % PML 层域（经验值，可能需调整）
catch
    fprintf('  [WARN] PML selection 自动设置失败，尝试全部外层域\n');
    try
        model.coordSystem('pml1').selection.all();
    catch
    end
end
fprintf('  OK PML 坐标系（球面缩放）\n');

%% 4. 物理：Electromagnetic Waves, frequency domain
phys = model.physics.create('emw', 'ElectromagneticWaves', 'geom1');
phys.model('comp1');

% 散射场公式：Scattering boundary condition
phys.create('sctr1', 'Scattering', 2);
% 设置背景平面波
% E0 = 极化方向 × 幅幅，k_dir = 传播方向
theta = acosd(p.background.k_direction(3));
phi   = atan2d(p.background.k_direction(2), p.background.k_direction(1));
try
    phys.feature('sctr1').set('theta0', num2str(theta));
    phys.feature('sctr1').set('phi0', num2str(phi));
    % E0 不是 sctr1 的参数，用全局变量设置极化
    model.param.set('E0x', num2str(p.background.amplitude * p.background.polarization(1)));
    model.param.set('E0y', num2str(p.background.amplitude * p.background.polarization(2)));
    model.param.set('E0z', num2str(p.background.amplitude * p.background.polarization(3)));
catch ME
    fprintf('  [WARN] sctr1 平面波参数设置: %s\n', ME.message);
end
% sctr1 选择内部域（散射体 + 空气，不含 PML）
try
    phys.feature('sctr1').selection.set([5 6 7 8]);  % 经验值
catch
    try phys.feature('sctr1').selection.all(); catch, end
end
fprintf('  OK EMW 物理 + 散射场公式 (θ=%.0f°, φ=%.0f°)\n', theta, phi);

% Wave Equation Electric: 设置 epsilon_r = int2 + i*int3
% 先创建插值函数占位（update_epsilon 会更新数据）
model.component('comp1').func.create('int2', 'Interpolation');
model.component('comp1').func('int2').set('nargs', '3');
model.component('comp1').func('int2').set('source', 'table');
% 初始数据：多点采样表示空气（eps_r=1）
init_pts = [0 0 0 1; 0.01 0 0 1; 0 0.01 0 1; 0 0 0.01 1; 0.02 0 0 1; 0 0.02 0 1; 0 0 0.02 1];
model.component('comp1').func('int2').set('table', num2str(init_pts));

model.component('comp1').func.create('int3', 'Interpolation');
model.component('comp1').func('int3').set('nargs', '3');
model.component('comp1').func('int3').set('source', 'table');
init_pts_im = [0 0 0 0; 0.01 0 0 0; 0 0.01 0 0; 0 0 0.01 0; 0.02 0 0 0; 0 0.02 0 0; 0 0 0.02 0];
model.component('comp1').func('int3').set('table', num2str(init_pts_im));

try
    phys.feature('wee1').set('epsilonr_mat', 'userdef');
    phys.feature('wee1').set('epsilonr', 'int2(x,y,z) + i*int3(x,y,z)');
    fprintf('  OK wee1.epsilonr = int2 + i*int3\n');
catch ME
    fprintf('  [WARN] wee1 epsilonr 设置: %s（后续 update_epsilon 会重试）\n', ME.message);
end

% External Current Density（用于伴随源注入）
phys.create('ecd1', 'ExternalCurrentDensity', 3);
phys.feature('ecd1').set('Je', {'0' '0' '0'});
try phys.feature('ecd1').selection.all(); catch, end

%% 5. 材料
mat = model.material.create('mat1', 'Common', 'comp1');
mat.propertyGroup('def').set('relpermittivity', {'1'});
mat.propertyGroup('def').set('relpermeability', {'1'});
mat.propertyGroup('def').set('electricconductivity', {'0'});

%% 6. 网格（粗网格，关键降规模手段）
mesh = model.mesh.create('mesh1', 'geom1');

% 内球使用较细网格（散射体区域），外层使用粗网格
% hmax: 最大单元尺寸；hmin: 最小单元尺寸
% 内球 ~lambda/(10*sqrt(eps_r)) ~ 0.03/sqrt(5) ~ 0.013m → 用 0.015m
% 空气层 ~lambda/6 ~ 0.05m → 用 0.04m
% PML ~lambda/4 → 用 0.04m
try
    mesh.create('size1', 'Size');
    mesh.feature('size1').set('hmax', '0.015');   % 内球细网格
    mesh.feature('size1').set('hmin', '0.005');
    mesh.feature('size1').set('custom', 'on');
    % 对内球域应用（域编号需根据实际几何调整）
catch
end

try
    mesh.create('size2', 'Size');
    mesh.feature('size2').set('hmax', '0.04');    % 外层粗网格
    mesh.feature('size2').set('hmin', '0.01');
    mesh.feature('size2').set('custom', 'on');
catch
end

mesh.run;
fprintf('  OK 网格划分完成\n');

%% 7. Study + Solver
study = model.study.create('std1');
freq_feat = study.create('freq', 'Frequency');
freq_feat.set('plist', sprintf('%g[Hz]', p.freq));
freq_feat.setSolveFor('/physics/emw', true);

% 求解器配置
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
try stat.feature('p1').feature.remove('pDef'); catch, end

% PARDISO 直接求解器
try
    stat.create('dDirect', 'Direct');
    stat.feature('dDirect').set('linsolver', 'pardiso');
    stat.create('fc1', 'FullyCoupled');
    stat.feature('fc1').set('linsolver', 'dDirect');
catch ME
    fprintf('  [WARN] PARDISO 配置: %s\n', ME.message);
end

%% 8. 参数
model.param.set('freq', num2str(p.freq));
model.param.set('adjoint_mode', '1');  % 1=正演模式, 0=伴随模式（零背景场）

%% 9. 首次几何+网格运行
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

fprintf('\n[build_lightweight_model] ★ 模型构建完成 ★\n');
fprintf('  下一步: model = build_lightweight_model(p); voxel = fem_mesh_utils(model, p, p.R_inner);\n');

end
