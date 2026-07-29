function check_sctr1_detail()
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
import com.comsol.model.util.*

mphstart(2036);

fprintf('=== Pipeline 1: livelink_model.mph ===\n');
m1 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
phys1 = m1.physics('emw');
sctr1 = phys1.feature('sctr1');

fprintf('sctr1 all properties:\n');
props = sctr1.properties();
for i = 1:length(props)
    pn = char(props(i));
    try
        pv = char(sctr1.getString(pn));
        fprintf('  %s = %s\n', pn, pv);
    catch
        try
            pv_num = sctr1.getDouble(pn);
            fprintf('  %s = %g (double)\n', pn, pv_num);
        catch
            fprintf('  %s = (unreadable)\n', pn);
        end
    end
end

fprintf('\nModel params:\n');
try
    pnames = m1.param().tags();
    for i = 1:length(pnames)
        pn = char(pnames(i));
        try
            pv = char(m1.param().get(pn));
            fprintf('  %s = %s\n', pn, pv);
        catch
        end
    end
catch
end

fprintf('\n\nBackgroundField props:\n');
try
    bf = phys1.prop('BackgroundField');
    bfprops = bf.properties();
    for i = 1:length(bfprops)
        pn = char(bfprops(i));
        try
            pv = char(bf.getString(pn));
            fprintf('  %s = %s\n', pn, pv);
        catch
        end
    end
catch ME
    fprintf('  Error: %s\n', ME.message);
end

% Check what E_inc actually is
fprintf('\n=== Verify: what does emw.Ex return in empty space? ===\n');
try
    m1.geom('geom1').run;
    m1.mesh('mesh1').run;
    m1.sol('sol1').runAll();
    
    % Query at a point far from scatterer (r=0.2, inside air region)
    test_pts = [0.2, 0, 0; -0.2, 0, 0; 0, 0.2, 0];
    Ex = mphinterp(m1, 'emw.Ex', 'coord', test_pts');
    Ey = mphinterp(m1, 'emw.Ey', 'coord', test_pts');
    Ez = mphinterp(m1, 'emw.Ez', 'coord', test_pts');
    rEx = mphinterp(m1, 'emw.relEx', 'coord', test_pts');
    rEy = mphinterp(m1, 'emw.relEy', 'coord', test_pts');
    rEz = mphinterp(m1, 'emw.relEz', 'coord', test_pts');
    
    for i = 1:size(test_pts,1)
        fprintf('  pt=[%.2f,%.2f,%.2f]: E_total=[%.6f,%.6f,%.6f] E_scat=[%.6f,%.6f,%.6f]\n', ...
            test_pts(i,1), test_pts(i,2), test_pts(i,3), ...
            Ex(i), Ey(i), Ez(i), rEx(i), rEy(i), rEz(i));
    end
catch ME
    fprintf('  Solve/query error: %s\n', ME.message);
end

ModelUtil.remove('Model');
