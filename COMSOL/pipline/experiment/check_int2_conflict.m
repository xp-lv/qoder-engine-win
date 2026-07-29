function check_int2_conflict()
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
import com.comsol.model.util.*

mphstart(2036);
model = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');

fprintf('=== All interpolation functions in comp1 ===\n');
try
    funcs = model.component('comp1').func().tags();
    for i = 1:length(funcs)
        fn = char(funcs(i));
        fprintf('  func %d: %s\n', i, fn);
        try
            src = char(model.component('comp1').func(fn).getString('source'));
            fprintf('    source: %s\n', src);
        catch
        end
        try
            nargs = char(model.component('comp1').func(fn).getString('nargs'));
            fprintf('    nargs: %s\n', nargs);
        catch
        end
    end
catch ME
    fprintf('Error: %s\n', ME.message);
end

fprintf('\n=== Search for int2/int3 references in physics ===\n');
phys = model.physics('emw');
ft = phys.feature().tags();
for i = 1:length(ft)
    fn = char(ft(i));
    props = phys.feature(fn).properties();
    for pi = 1:length(props)
        pn = char(props(pi));
        try
            pv = char(phys.feature(fn).getString(pn));
            if contains(pv, 'int2') || contains(pv, 'int3') || contains(pv, 'int1')
                fprintf('  emw/%s.%s = %s\n', fn, pn, pv);
            end
        catch
        end
    end
end

fprintf('\n=== Check wee1.epsilonr details ===\n');
try
    eps_val = phys.feature('wee1').getString('epsilonr');
    fprintf('  wee1.epsilonr (raw): ');
    for k = 1:length(eps_val)
        fprintf('%s ', char(eps_val(k)));
    end
    fprintf('\n');
catch ME
    fprintf('  Error: %s\n', ME.message);
end

fprintf('\n=== Check dcont1 (Continuity) ===\n');
try
    dcont1 = phys.feature('dcont1');
    props_dc = dcont1.properties();
    for pi = 1:length(props_dc)
        pn = char(props_dc(pi));
        try
            pv = char(dcont1.getString(pn));
            if length(pv) > 0
                fprintf('  dcont1.%s = %s\n', pn, pv);
            end
        catch
        end
    end
catch
end

ModelUtil.remove('Model');
