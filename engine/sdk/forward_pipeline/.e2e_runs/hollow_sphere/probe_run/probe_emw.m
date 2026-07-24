
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');

% 1. func 列表（看 int2/int3 是否存在）
fprintf('[probe] === func tags ===\n');
disp(m.func.tags);

% 2. 看 int2 的当前 table（前 5 行）
try
    t = m.func('int2').get('table');
    fprintf('[probe] int2 table size: %s\n', mat2str(size(t)));
    fprintf('[probe] int2 first 5 rows:\n');
    disp(t(1:min(5, size(t,1)), :));
    fprintf('[probe] int2 argstr: %s\n', m.func('int2').get('argstr'));
    fprintf('[probe] int2 funcname: %s\n', m.func('int2').get('funcname'));
catch ME
    fprintf('[probe] int2 not found or no table: %s\n', ME.message);
end

% 3. emw 的 feature tags
fprintf('\n[probe] === emw features ===\n');
emw_feat_tags = m.physics('emw').feature.tags;
disp(emw_feat_tags);

% 4. 每个 feature 的属性中含 'epsilonr' 的
for i = 1:length(emw_feat_tags)
    tag = emw_feat_tags{i};
    fprintf('[probe] --- feature: %s ---\n', tag);
    feat = m.physics('emw').feature(tag);
    try
        feat_type = feat.type;
        fprintf('[probe]   type: %s\n', feat_type);
    catch
    end
    try
        propnames = feat.propnames;
        eps_props = {};
        for j = 1:length(propnames)
            pn = propnames{j};
            if contains(lower(pn), 'epsilon') || contains(lower(pn), 'permitt') || contains(lower(pn), 'material')
                eps_props{end+1} = pn;
            end
        end
        if ~isempty(eps_props)
            fprintf('[probe]   epsilon-related props:\n');
            for k = 1:length(eps_props)
                try
                    val = feat.get(eps_props{k});
                    fprintf('[probe]     %s = %s\n', eps_props{k}, char(val));
                catch
                    fprintf('[probe]     %s = (no value)\n', eps_props{k});
                end
            end
        end
    catch ME
        fprintf('[probe]   propnames query failed: %s\n', ME.message);
    end
end

% 5. 材料列表
fprintf('\n[probe] === materials ===\n');
mat_tags = m.material.tags;
disp(mat_tags);
for i = 1:length(mat_tags)
    tag = mat_tags{i};
    try
        rp = m.material(tag).propertyGroup('def').get('relpermittivity');
        sel = m.material(tag).selection.defined;
        fprintf('[probe] mat(%s): relpermittivity=%s, domains=%s\n', tag, char(rp), mat2str(sel));
    catch ME
        fprintf('[probe] mat(%s) info failed: %s\n', tag, ME.message);
    end
end

% 6. domainti 物理属性（直接看 wee1/wave equation）
fprintf('\n[probe] === try wee1 ===\n');
try
    wee1 = m.physics('emw').feature('wee1');
    fprintf('[probe] wee1 type: %s\n', wee1.type);
    em_mat = wee1.get('epsilonr_mat');
    fprintf('[probe] wee1.epsilonr_mat = %s\n', char(em_mat));
    if strcmp(em_mat, 'userdef')
        em_val = wee1.get('epsilonr');
        fprintf('[probe] wee1.epsilonr = %s\n', char(em_val));
    end
catch ME
    fprintf('[probe] wee1 not found: %s\n', ME.message);
end

clearvars m;
fprintf('\n[probe] === DONE ===\n');
