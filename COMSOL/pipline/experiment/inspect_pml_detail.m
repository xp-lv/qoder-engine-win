function inspect_pml_detail()
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
import com.comsol.model.util.*

mphstart(2036);
model = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');

fprintf('\n=== Sphere layers ===\n');
sph = model.geom('geom1').feature('sph1');
r = str2double(char(sph.getString('r')));
fprintf('Outer radius r = %.3f m\n', r);

n_layers = 0;
try
    layers = sph.getString('layer');
    n_layers = length(layers);
    fprintf('Number of layers: %d\n', n_layers);
    for li = 0:n_layers-1
        lw = char(sph.getStringIndex('layer', li));
        fprintf('  layer(%d) thickness: %s m\n', li, lw);
    end
catch
    fprintf('No layers defined (solid sphere)\n');
end

% Try to get layer names
try
    lnames = sph.getString('layername');
    fprintf('Layer names:\n');
    for li = 1:length(lnames)
        fprintf('  %d: %s\n', li, char(lnames(li)));
    end
catch
end

fprintf('\n=== PML selection domains ===\n');
try
    pml = model.coordSystem('pml1');
    sel = pml.selection;
    % Try to get domain numbers
    try
        domains = sel.set();
        fprintf('PML domains (set): %s\n', mat2str(domains));
    catch
        try
            sel.geom('geom1', 3);
            domains = sel.set();
            fprintf('PML domains (geom1,3): %s\n', mat2str(domains));
        catch
            try
                sel.all();
                fprintf('PML selection: all\n');
            catch
            end
            try
                % Try input entities
                ent = sel.inputEntities();
                fprintf('PML input entities: %s\n', mat2str(ent));
            catch
                fprintf('Cannot determine PML selection\n');
            end
        end
    end
catch ME
    fprintf('PML error: %s\n', ME.message);
end

fprintf('\n=== Mesh size features ===\n');
try
    m = model.mesh('mesh1');
    ft = m.feature().tags();
    for i = 1:length(ft)
        fn = char(ft(i));
        fprintf('  mesh feature %d: %s\n', i, fn);
        try
            hmax = char(m.feature(fn).getString('hmax'));
            fprintf('    hmax: %s\n', hmax);
        catch
        end
        try
            hmin = char(m.feature(fn).getString('hmin'));
            fprintf('    hmin: %s\n', hmin);
        catch
        end
        try
            % Check selection
            sel = m.feature(fn).selection;
            domains = sel.set();
            fprintf('    domains: %s\n', mat2str(domains));
        catch
        end
    end
catch ME
    fprintf('Mesh error: %s\n', ME.message);
end

fprintf('\n=== Measurement sphere R=0.26m vs model R=0.4m ===\n');
fprintf('Model outer radius: %.3f m\n', r);
fprintf('Measurement sphere: 0.260 m\n');
if n_layers > 0
    fprintf('PML layers:\n');
    cumul = r;
    for li = n_layers:-1:1
        lw_str = char(sph.getStringIndex('layer', li-1));
        lw = str2double(lw_str);
        cumul_inner = cumul - lw;
        fprintf('  layer %d: [%.3f, %.3f] (thickness %.3f)\n', li, cumul_inner, cumul, lw);
        if 0.26 >= cumul_inner && 0.26 < cumul
            fprintf('  *** R=0.26 is INSIDE PML layer %d! ***\n', li);
        end
        cumul = cumul_inner;
    end
    fprintf('  Inner region: [0, %.3f]\n', cumul);
    if 0.26 < cumul
        fprintf('  R=0.26 is in the inner (non-PML) region\n');
    end
else
    fprintf('No layers - cannot determine PML boundary\n');
    fprintf('PML coord system covers all domains (potential issue)\n');
end

ModelUtil.remove('Model');
