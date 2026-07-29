function compare_model_settings()
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  两个模型的完整设置对比\n');
fprintf('############################################################\n\n');

mphstart(2036);

%% 管线1
fprintf('===== 管线 1: livelink_model.mph =====\n');
m1 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
phys1 = m1.physics('emw');

fprintf('\n--- Geometry ---\n');
try
    sph1 = m1.geom('geom1').feature('sph1');
    fprintf('  sph1.r = %s\n', char(sph1.getString('r')));
catch, fprintf('  no sph1\n'); end

fprintf('\n--- Physics Features ---\n');
ft1 = phys1.feature().tags();
for i = 1:length(ft1)
    fn = char(ft1(i));
    fprintf('  feature %d: %s\n', i, fn);
end

fprintf('\n--- BackgroundField ---\n');
try
    bf1 = phys1.prop('BackgroundField');
    bfprops = bf1.properties();
    for i = 1:length(bfprops)
        pn = char(bfprops(i));
        try
            pv = char(bf1.getString(pn));
            fprintf('  %s = %s\n', pn, pv);
        catch
            try
                pvd = bf1.getDouble(pn);
                fprintf('  %s = %g\n', pn, pvd);
            catch, end
        end
    end
catch ME
    fprintf('  No BackgroundField: %s\n', ME.message);
end

fprintf('\n--- sctr1 (Scattering) ---\n');
try
    sctr1 = phys1.feature('sctr1');
    scprops = sctr1.properties();
    for i = 1:length(scprops)
        pn = char(scprops(i));
        try
            pv = char(sctr1.getString(pn));
            fprintf('  sctr1.%s = %s\n', pn, pv);
        catch
            try
                pvd = sctr1.getDouble(pn);
                fprintf('  sctr1.%s = %g\n', pn, pvd);
            catch, end
        end
    end
catch
    fprintf('  No sctr1\n');
end

fprintf('\n--- wee1 (Wave Equation) ---\n');
try
    wee1 = phys1.feature('wee1');
    weprops = wee1.properties();
    for i = 1:length(weprops)
        pn = char(weprops(i));
        try
            pv = char(wee1.getString(pn));
            if length(pv) > 0
                fprintf('  wee1.%s = %s\n', pn, pv);
            end
        catch, end
    end
catch
end

fprintf('\n--- Model Parameters ---\n');
try
    pnames = m1.param().tags();
    for i = 1:length(pnames)
        pn = char(pnames(i));
        try
            pv = char(m1.param().get(pn));
            fprintf('  %s = %s\n', pn, pv);
        catch, end
    end
catch, end

fprintf('\n--- Coordinate Systems (PML) ---\n');
try
    cs_tags = m1.coordSystem().tags();
    for i = 1:length(cs_tags)
        cn = char(cs_tags(i));
        fprintf('  coordSystem %d: %s\n', i, cn);
        try
            st = char(m1.coordSystem(cn).getString('ScalingType'));
            fprintf('    ScalingType = %s\n', st);
        catch, end
        try
            sel = m1.coordSystem(cn).selection;
            domains = sel.set();
            fprintf('    domains = %s\n', mat2str(domains));
        catch
            fprintf('    domains = (all)\n');
        end
    end
catch, end

fprintf('\n--- Mesh ---\n');
try
    msh1 = m1.mesh('mesh1');
    fprintf('  tet = %d\n', msh1.getNumElem('tet'));
    ft_m = msh1.feature().tags();
    for i = 1:length(ft_m)
        fn = char(ft_m(i));
        fprintf('  mesh feature %d: %s\n', i, fn);
        try
            hmax = char(msh1.feature(fn).getString('hmax'));
            fprintf('    hmax = %s\n', hmax);
        catch, end
        try
            hmin = char(msh1.feature(fn).getString('hmin'));
            fprintf('    hmin = %s\n', hmin);
        catch, end
    end
catch, end

try ModelUtil.remove('Model'); catch, end

%% 管线2
fprintf('\n\n===== 管线 2: 2layer.mph =====\n');
m2 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint\2layer.mph');
phys2 = m2.physics('emw');

fprintf('\n--- Geometry ---\n');
try
    sph2 = m2.geom('geom1').feature('sph1');
    fprintf('  sph1.r = %s\n', char(sph2.getString('r')));
catch, end

fprintf('\n--- Physics Features ---\n');
ft2 = phys2.feature().tags();
for i = 1:length(ft2)
    fn = char(ft2(i));
    fprintf('  feature %d: %s\n', i, fn);
end

fprintf('\n--- BackgroundField ---\n');
try
    bf2 = phys2.prop('BackgroundField');
    bfprops2 = bf2.properties();
    for i = 1:length(bfprops2)
        pn = char(bfprops2(i));
        try
            pv = char(bf2.getString(pn));
            fprintf('  %s = %s\n', pn, pv);
        catch
            try
                pvd = bf2.getDouble(pn);
                fprintf('  %s = %g\n', pn, pvd);
            catch, end
        end
    end
catch ME
    fprintf('  No BackgroundField: %s\n', ME.message);
end

fprintf('\n--- sctr1 (Scattering) ---\n');
try
    sctr2 = phys2.feature('sctr1');
    scprops2 = sctr2.properties();
    for i = 1:length(scprops2)
        pn = char(scprops2(i));
        try
            pv = char(sctr2.getString(pn));
            fprintf('  sctr1.%s = %s\n', pn, pv);
        catch
            try
                pvd = sctr2.getDouble(pn);
                fprintf('  sctr1.%s = %g\n', pn, pvd);
            catch, end
        end
    end
catch
    fprintf('  No sctr1\n');
end

fprintf('\n--- wee1 (Wave Equation) ---\n');
try
    wee2 = phys2.feature('wee1');
    weprops2 = wee2.properties();
    for i = 1:length(weprops2)
        pn = char(weprops2(i));
        try
            pv = char(wee2.getString(pn));
            if length(pv) > 0
                fprintf('  wee1.%s = %s\n', pn, pv);
            end
        catch, end
    end
catch, end

fprintf('\n--- Model Parameters ---\n');
try
    pnames2 = m2.param().tags();
    for i = 1:length(pnames2)
        pn = char(pnames2(i));
        try
            pv = char(m2.param().get(pn));
            fprintf('  %s = %s\n', pn, pv);
        catch, end
    end
catch, end

fprintf('\n--- Coordinate Systems (PML) ---\n');
try
    cs_tags2 = m2.coordSystem().tags();
    for i = 1:length(cs_tags2)
        cn = char(cs_tags2(i));
        fprintf('  coordSystem %d: %s\n', i, cn);
        try
            st = char(m2.coordSystem(cn).getString('ScalingType'));
            fprintf('    ScalingType = %s\n', st);
        catch, end
        try
            sel = m2.coordSystem(cn).selection;
            domains = sel.set();
            fprintf('    domains = %s\n', mat2str(domains));
        catch
            fprintf('    domains = (all)\n');
        end
    end
catch, end

fprintf('\n--- Mesh ---\n');
try
    msh2 = m2.mesh('mesh1');
    fprintf('  tet = %d\n', msh2.getNumElem('tet'));
    ft_m2 = msh2.feature().tags();
    for i = 1:length(ft_m2)
        fn = char(ft_m2(i));
        fprintf('  mesh feature %d: %s\n', i, fn);
        try
            hmax = char(msh2.feature(fn).getString('hmax'));
            fprintf('    hmax = %s\n', hmax);
        catch, end
        try
            hmin = char(msh2.feature(fn).getString('hmin'));
            fprintf('    hmin = %s\n', hmin);
        catch, end
    end
catch, end

try ModelUtil.remove('Model'); catch, end
