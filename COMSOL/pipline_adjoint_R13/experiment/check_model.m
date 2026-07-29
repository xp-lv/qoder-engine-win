% 快速检查 2layer.mph 的物理特征和变量
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
cd('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint');
addpath('config','utils','core_forward');

try mphstart(2036); catch, end
model = mphload('2layer.mph');
try model.geom('geom1').run; catch, end
try model.mesh('mesh1').run; catch, end

phys = model.physics('emw');

% 列出物理特征（用 tag() 获取）
fprintf('\n===== EMW Features =====\n');
tags = phys.feature().tags();
for ti = 1:length(tags)
    fprintf('  %s\n', char(tags(ti)));
end

% Study
fprintf('\n===== Study =====\n');
try
    tags_s = model.study('std1').feature().tags();
    for ti = 1:length(tags_s)
        fprintf('  %s\n', char(tags_s(ti)));
    end
catch ME
    fprintf('  无 std1: %s\n', ME.message);
end

% Solver
fprintf('\n===== Solver =====\n');
try
    model.sol('sol1');
    fprintf('  sol1 存在\n');
catch
    fprintf('  sol1 不存在\n');
end

% BackgroundField
fprintf('\n===== BackgroundField =====\n');
try
    bf = phys.prop('BackgroundField');
    fprintf('  SolveFor: %s\n', bf.get('SolveFor'));
catch ME
    fprintf('  无 BackgroundField prop: %s\n', ME.message);
end

% 尝试求解
fprintf('\n===== 尝试求解 =====\n');
try
    % 设简单 eps=1
    model.param.set('freq', '1e9');
    try model.study('std1').feature('freq').set('plist', '1e9[Hz]'); catch, end
    model.study('std1').run;
    fprintf('  求解成功\n');

    % 提取场变量
    coord = [0; 0.02; 0.02];
    vars = {'emw.Ex', 'emw.Ey', 'emw.Ez', 'emw.relEx', 'emw.relEy', 'emw.relEz'};
    for vi = 1:length(vars)
        try
            val = mphinterp(model, vars{vi}, 'coord', coord);
            fprintf('  %s = %.6e\n', vars{vi}, val);
        catch ME
            fprintf('  %s: 不可用 (%s)\n', vars{vi}, ME.message);
        end
    end
catch ME
    fprintf('  求解失败: %s\n', ME.message);
end
