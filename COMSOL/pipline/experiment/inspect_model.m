function inspect_model()
%INSPECT_MODEL 检查 livelink_model.mph 的几何/PML/物理设置
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
import com.comsol.model.util.*

p_path = 'd:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph';
mphstart(2036);
model = mphload(p_path);

fprintf('\n=== Geometry Features ===\n');
try
    g = model.geom('geom1');
    ft = g.feature().tags();
    for i = 1:length(ft)
        fn = char(ft(i));
        fprintf('  feature %d: %s\n', i, fn);
        try
            typ = char(g.feature(fn).getString('type'));
            fprintf('    type: %s\n', typ);
        catch
        end
        try
            r = char(g.feature(fn).getString('r'));
            fprintf('    r: %s\n', r);
        catch
        end
        try
            layers = g.feature(fn).getString('layer');
            for li = 0:length(layers)-1
                lw = char(g.feature(fn).getStringIndex('layer', li));
                fprintf('    layer(%d): %s\n', li, lw);
            end
        catch
        end
    end
catch ME
    fprintf('Error: %s\n', ME.message);
end

fprintf('\n=== Coordinate Systems (PML) ===\n');
try
    cs_tags = model.coordSystem().tags();
    for i = 1:length(cs_tags)
        cn = char(cs_tags(i));
        fprintf('  coordSystem %d: %s\n', i, cn);
        try
            st = char(model.coordSystem(cn).getString('ScalingType'));
            fprintf('    ScalingType: %s\n', st);
        catch
        end
        try
            domains = model.coordSystem(cn).selection.set();
            fprintf('    domains: %s\n', mat2str(domains));
        catch
            fprintf('    domains: (all)\n');
        end
    end
catch ME
    fprintf('Error: %s\n', ME.message);
end

fprintf('\n=== Domains ===\n');
try
    geom.run;
    bd = model.geom('geom1').boundingBox();
    fprintf('  Bounding box: %s\n', mat2str(bd));
catch ME
    fprintf('  boundingBox error: %s\n', ME.message);
end

fprintf('\n=== Physics Features ===\n');
try
    phys = model.physics('emw');
    ft = phys.feature().tags();
    for i = 1:length(ft)
        fn = char(ft(i));
        ftype = '';
        try ftype = char(phys.feature(fn).getType()); catch, end
        fprintf('  feature %d: %s (%s)\n', i, fn, ftype);
    end
catch ME
    fprintf('Error: %s\n', ME.message);
end

fprintf('\n=== Background Field ===\n');
try
    bf = model.physics('emw').prop('BackgroundField');
    eb = char(bf.getString('Eb'));
    fprintf('  Eb: %s\n', eb);
catch ME
    fprintf('  No BackgroundField prop: %s\n', ME.message);
end

fprintf('\n=== Mesh ===\n');
try
    m = model.mesh('mesh1');
    fprintf('  tet elements: %d\n', m.getNumElem('tet'));
catch
end

ModelUtil.remove('Model');
