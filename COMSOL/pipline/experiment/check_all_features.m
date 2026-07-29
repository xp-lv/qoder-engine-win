function check_all_features()
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);

fprintf('=== 管线1 (fixed) 所有 feature 详情 ===\n');
model = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model_fixed.mph');
phys = model.physics('emw');
ft = phys.feature().tags();
for i = 1:length(ft)
    fn = char(ft(i));
    fprintf('\n--- %s ---\n', fn);
    props = phys.feature(fn).properties();
    for pi = 1:length(props)
        pn = char(props(pi));
        try
            pv = char(phys.feature(fn).getString(pn));
            if length(pv) > 0 && ~strcmp(pv, '0')
                fprintf('  %s = %s\n', pn, pv);
            end
        catch, end
    end
end

fprintf('\n\n=== 管线2 所有 feature 详情 ===\n');
model2 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint\2layer.mph');
phys2 = model2.physics('emw');
ft2 = phys2.feature().tags();
for i = 1:length(ft2)
    fn = char(ft2(i));
    fprintf('\n--- %s ---\n', fn);
    props2 = phys2.feature(fn).properties();
    for pi = 1:length(props2)
        pn = char(props2(pi));
        try
            pv = char(phys2.feature(fn).getString(pn));
            if length(pv) > 0 && ~strcmp(pv, '0')
                fprintf('  %s = %s\n', pn, pv);
            end
        catch, end
    end
end

try ModelUtil.remove('Model'); catch, end
