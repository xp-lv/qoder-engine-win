% 从 COMSOL 模型中提取 SurfaceCurrent 和 SurfaceMagneticCurrentDensity 的弱形式方程
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

p = config();
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message, 'Already connected')
        error('mphstart: %s', ME.message);
    end
end
model = mphload(p.comsol_model_path);
phys = model.physics('emw');

fprintf('\n========== EMW Physics Features ==========\n');

% 列出所有 feature
features = phys.feature();
nfeat = features.size();
fprintf('Total features: %d\n', nfeat);

for i = 1:nfeat
    try
        ft = features.get(i-1);  % Java 0-based
        tag = ft.getTag();
        ftype = ft.getType();
        fprintf('\n--- Feature %d: %s (type=%s) ---\n', i, tag, ftype);

        % 列出所有属性
        props = ft.properties();
        nprop = props.size();
        for j = 1:nprop
            try
                prop = props.get(j-1);
                pname = prop.getKey();
                pval = prop.get();
                if ischar(pval) || isstring(pval)
                    fprintf('  %s = %s\n', pname, pval);
                elseif isnumeric(pval) && isscalar(pval)
                    fprintf('  %s = %g\n', pname, pval);
                else
                    fprintf('  %s = [%s]\n', pname, class(pval));
                end
            catch
            end
        end

        % 尝试获取方程视图
        try
            eqview = ft.get('equationview');
            fprintf('  Equation View found\n');
        catch
        end
    catch
    end
end

% 特别检查 SurfaceCurrent (sc_adj) 和 SurfaceMagneticCurrentDensity (ms_adj)
% 需要先创建它们
fprintf('\n========== 创建并检查 sc_adj ==========\n');
try phys.feature().remove('sc_adj'); catch, end
phys.feature().create('sc_adj', 'SurfaceCurrent', 2);
sc = phys.feature('sc_adj');
try sc.selection().all(); catch, end

% 尝试读取弱形式
try
    weak = sc.getString('weak');
    fprintf('sc_adj weak = %s\n', weak);
catch ME
    fprintf('sc_adj weak failed: %s\n', ME.message);
end
try
    constr = sc.getString('constraint');
    fprintf('sc_adj constraint = %s\n', constr);
catch
end

% 列出 sc_adj 的所有字符串属性
fprintf('sc_adj properties:\n');
props_sc = sc.properties();
for j = 1:props_sc.size()
    try
        prop = props_sc.get(j-1);
        pname = prop.getKey();
        try
            pval = sc.getString(pname);
            if strlen(pval) > 0 && strlen(pval) < 200
                fprintf('  %s = %s\n', pname, pval);
            end
        catch
        end
    catch
    end
end

fprintf('\n========== 创建并检查 ms_adj ==========\n');
try phys.feature().remove('ms_adj'); catch, end
phys.feature().create('ms_adj', 'SurfaceMagneticCurrentDensity', 2);
ms = phys.feature('ms_adj');
try ms.selection().all(); catch, end

try
    weak_ms = ms.getString('weak');
    fprintf('ms_adj weak = %s\n', weak_ms);
catch ME
    fprintf('ms_adj weak failed: %s\n', ME.message);
end

fprintf('ms_adj properties:\n');
props_ms = ms.properties();
for j = 1:props_ms.size()
    try
        prop = props_ms.get(j-1);
        pname = prop.getKey();
        try
            pval = ms.getString(pname);
            if strlen(pval) > 0 && strlen(pval) < 200
                fprintf('  %s = %s\n', pname, pval);
            end
        catch
        end
    catch
    end
end

% 清理
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end

fprintf('\n========== 检查 emw 接口的弱形式 ==========\n');
% 检查 EMW 接口本身的弱形式
try
    weak_emw = phys.getString('weak');
    fprintf('emw weak = %s\n', weak_emw);
catch ME
    fprintf('emw weak failed: %s\n', ME.message);
end

% 检查 we1 (Wave Equation) feature 的弱形式
try
    we1 = phys.feature('wee1');
    weak_we1 = we1.getString('weak');
    fprintf('wee1 weak = %s\n', weak_we1);
catch ME
    fprintf('wee1 weak failed: %s\n', ME.message);
end

fprintf('\n========== 完成 ==========\n');
