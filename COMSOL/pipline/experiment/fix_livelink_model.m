function fix_livelink_model()
%FIX_LIVELINK_MODEL 修改 livelink_model.mph 使其与管线2对齐
%   1. 删除 sctr1 (Scattering feature)
%   2. Ebg 从 0*adjoint_mode 改成 0
%   3. 设 Eb = [0,0,1]

addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('=== 修复 livelink_model.mph ===\n\n');

mphstart(2036);
model = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
phys = model.physics('emw');

%% 1. 删除 sctr1
fprintf('1. 删除 sctr1...\n');
try
    phys.feature().remove('sctr1');
    fprintf('   OK sctr1 已删除\n');
catch ME
    fprintf('   [WARN] sctr1 删除失败: %s\n', ME.message);
end

%% 2. Ebg 改成恒 0（与管线2一致）
fprintf('\n2. 修改 Ebg...\n');
try
    phys.prop('BackgroundField').set('Ebg', {'0' '0' '0'});
    val = char(phys.prop('BackgroundField').getString('Ebg'));
    fprintf('   OK Ebg = %s\n', val);
catch ME
    fprintf('   [WARN] Ebg 修改失败: %s\n', ME.message);
end

%% 3. 设 Eb = [0,0,1]
fprintf('\n3. 设置 Eb = [0,0,1]...\n');
try
    phys.prop('BackgroundField').set('Eb', [0 0 1]);
    fprintf('   OK Eb = [0,0,1]\n');
catch ME
    fprintf('   [WARN] Eb 设置失败: %s\n', ME.message);
end

%% 4. 确认最终状态
fprintf('\n=== 修改后的状态 ===\n');
try
    bf = phys.prop('BackgroundField');
    fprintf('  WaveType = %s\n', char(bf.getString('WaveType')));
    fprintf('  Eb = %s\n', char(bf.getString('Eb')));
    fprintf('  Ebg = %s\n', char(bf.getString('Ebg')));
catch, end

% 列出当前 features
fprintf('  Features:\n');
ft = phys.feature().tags();
for i = 1:length(ft)
    fprintf('    %s\n', char(ft(i)));
end

%% 5. 保存
fprintf('\n=== 保存模型 ===\n');
try
    model.save('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
    fprintf('   OK 已保存\n');
catch ME
    fprintf('   [WARN] 保存失败（只读？）: %s\n', ME.message);
    fprintf('   尝试另存为...\n');
    model.save('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model_fixed.mph');
    fprintf('   OK 另存为 livelink_model_fixed.mph\n');
end

try ModelUtil.remove('Model'); catch, end
fprintf('\n完成。\n');
