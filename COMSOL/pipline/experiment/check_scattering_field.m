function check_scattering_field()
%CHECK_SCATTERING_FIELD 检查两条管线散射场公式的背景场设置差异
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
import com.comsol.model.util.*

fprintf('\n=== 管线1 livelink_model.mph ===\n');
mphstart(2036);
m1 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');

% 散射场公式设置
phys1 = m1.physics('emw');
try
    bf1 = phys1.prop('BackgroundField');
    eb1 = char(bf1.getString('Eb'));
    fprintf('  BackgroundField Eb: [%s]\n', eb1);
catch ME
    fprintf('  No BackgroundField prop: %s\n', ME.message);
end

% 检查 sctr1 (Scattering) feature
try
    sctr1 = phys1.feature('sctr1');
    fprintf('  sctr1 (Scattering) exists\n');
    % 检查背景场在 Scattering feature 中如何设置
    try
        eb_sctr = char(sctr1.getString('Eb'));
        fprintf('  sctr1.Eb: [%s]\n', eb_sctr);
    catch
    end
    try
        btype = char(sctr1.getString('Btype'));
        fprintf('  sctr1.Btype: %s\n', btype);
    catch
    end
    % 列出所有属性
    try
        props = sctr1.properties();
        fprintf('  sctr1 properties:\n');
        for pi = 1:length(props)
            pn = char(props(pi));
            try
                pv = char(sctr1.getString(pn));
                fprintf('    %s = %s\n', pn, pv);
            catch
            end
        end
    catch
    end
catch
    fprintf('  No sctr1 feature\n');
end

% 检查 wee1 的 epsilonr 设置
try
    wee1 = phys1.feature('wee1');
    eps_val = char(wee1.getString('epsilonr'));
    fprintf('  wee1.epsilonr: %s\n', eps_val);
catch
end

% 检查所有 mesh features 的域选择
fprintf('\n  Mesh features:\n');
msh1 = m1.mesh('mesh1');
ft1 = msh1.feature().tags();
for i = 1:length(ft1)
    fn = char(ft1(i));
    fprintf('    feature %d: %s\n', i, fn);
    try
        hmax = char(msh1.feature(fn).getString('hmax'));
        fprintf('      hmax: %s\n', hmax);
    catch
    end
    try
        hmin = char(msh1.feature(fn).getString('hmin'));
        fprintf('      hmin: %s\n', hmin);
    catch
    end
    % 检查域选择
    try
        sel = msh1.feature(fn).selection;
        domains = sel.set();
        fprintf('      domains: %s\n', mat2str(domains));
    catch
        fprintf('      domains: (all or undefined)\n');
    end
end

ModelUtil.remove('Model');

fprintf('\n\n=== 管线2 2layer.mph ===\n');
try
    m2 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\pipline_adjoint\2layer.mph');
    
    phys2 = m2.physics('emw');
    try
        bf2 = phys2.prop('BackgroundField');
        eb2 = char(bf2.getString('Eb'));
        fprintf('  BackgroundField Eb: [%s]\n', eb2);
    catch ME
        fprintf('  No BackgroundField prop: %s\n', ME.message);
    end
    
    try
        sctr2 = phys2.feature('sctr1');
        fprintf('  sctr1 (Scattering) exists\n');
        try
            eb_sctr2 = char(sctr2.getString('Eb'));
            fprintf('  sctr1.Eb: [%s]\n', eb_sctr2);
        catch
        end
        try
            props2 = sctr2.properties();
            fprintf('  sctr1 properties:\n');
            for pi = 1:length(props2)
                pn = char(props2(pi));
                try
                    pv = char(sctr2.getString(pn));
                    fprintf('    %s = %s\n', pn, pv);
                catch
                end
            end
        catch
        end
    catch
        fprintf('  No sctr1 feature\n');
    end
    
    try
        wee2 = phys2.feature('wee1');
        eps_val2 = char(wee2.getString('epsilonr'));
        fprintf('  wee1.epsilonr: %s\n', eps_val2);
    catch
    end
    
    fprintf('\n  Mesh features:\n');
    msh2 = m2.mesh('mesh1');
    ft2 = msh2.feature().tags();
    for i = 1:length(ft2)
        fn = char(ft2(i));
        fprintf('    feature %d: %s\n', i, fn);
        try
            hmax2 = char(msh2.feature(fn).getString('hmax'));
            fprintf('      hmax: %s\n', hmax2);
        catch
        end
    end
    
    ModelUtil.remove('Model');
catch ME
    fprintf('  Cannot load 2layer.mph: %s\n', ME.message);
end
