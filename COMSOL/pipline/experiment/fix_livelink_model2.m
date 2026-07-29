function fix_livelink_model2()
% 删除 ecd1 + 确保 Eb=[0,0,1] 用 cell 格式
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('=== 修复 livelink_model_fixed.mph (round 2) ===\n\n');
mphstart(2036);
model = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model_fixed.mph');
phys = model.physics('emw');

%% 1. 删除 ecd1 (残留电流源 Je=-4500i+10000)
fprintf('1. 删除 ecd1...\n');
try
    phys.feature().remove('ecd1');
    fprintf('   OK ecd1 已删除\n');
catch ME
    fprintf('   [WARN] %s\n', ME.message);
end

%% 2. 用 cell 格式设 Eb
fprintf('\n2. 设 Eb (cell格式)...\n');
try
    phys.prop('BackgroundField').set('Eb', {'0' '0' '1'});
    fprintf('   OK Eb set via cell\n');
catch ME
    fprintf('   [WARN] cell failed: %s\n', ME.message);
    try
        phys.prop('BackgroundField').set('Eb', [0 0 1]);
        fprintf('   OK Eb set via vector (fallback)\n');
    catch ME2
        fprintf('   FAIL: %s\n', ME2.message);
    end
end

%% 3. 确认
fprintf('\n=== 确认 ===\n');
try fprintf('  Eb = %s\n', char(phys.prop('BackgroundField').getString('Eb'))); catch, end
try fprintf('  Ebg = %s\n', char(phys.prop('BackgroundField').getString('Ebg'))); catch, end
fprintf('  Features:\n');
ft = phys.feature().tags();
for i = 1:length(ft)
    fn = char(ft(i));
    fprintf('    %s', fn);
    try
        je = char(phys.feature(fn).getString('Je'));
        if length(je) > 0
            fprintf('  [Je=%s]', je);
        end
    catch, end
    fprintf('\n');
end

%% 4. 保存
fprintf('\n=== 保存 ===\n');
try
    model.save('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model_fixed2.mph');
    fprintf('   OK saved livelink_model_fixed2.mph\n');
catch ME
    fprintf('   FAIL: %s\n', ME.message);
end

try ModelUtil.remove('Model'); catch, end
