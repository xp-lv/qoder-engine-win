function compare_bg_field()
%COMPARE_BG_FIELD 对比两个模型的背景场配置是否一致

this_dir = fileparts(mfilename('fullpath'));
cd(this_dir);
addpath('config','utils');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  背景场配置对比\n');
fprintf('############################################################\n\n');

try mphstart(2036); catch ME
    if ~contains(ME.message, 'Already connected')
        fprintf('[FAIL] mphstart\n'); return;
    end
end

%% 检查函数
check_model_bg = @(model, name) deal_with_model(model, name);

%% 1. 管线2 (2layer.mph)
fprintf('===== 管线2 (2layer.mph) =====\n');
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

p = config();
model2 = mphload(p.comsol_model_path);
try model2.geom('geom1').run; catch, end
try model2.mesh('mesh1').run; catch, end

bg2 = deal_with_model(model2, '2layer.mph');

%% 2. 主管线 (livelink_model.mph)
fprintf('\n===== 主管线 (livelink_model.mph) =====\n');
try
    tags = ModelUtil.tags();
    for ti = 1:length(tags), ModelUtil.remove(char(tags(ti))); end
catch
end

model1 = mphload('d:\ZJU\PROJECT\2026-07-02-qoder-engine\COMSOL\livelink_model.mph');
try model1.geom('geom1').run; catch, end
try model1.mesh('mesh1').run; catch, end

bg1 = deal_with_model(model1, 'livelink_model.mph');

%% 3. 对比
fprintf('\n############################################################\n');
fprintf('#  背景场对比\n');
fprintf('############################################################\n');

fields = {'Eb', 'BackgroundFieldType', 'E0x', 'E0y', 'E0z', 'k_dir_x', 'k_dir_y', 'k_dir_z'};
match_count = 0;
for fi = 1:length(fields)
    f = fields{fi};
    v2 = '';
    v1 = '';
    if isfield(bg2, f), v2 = bg2.(f); end
    if isfield(bg1, f), v1 = bg1.(f); end
    
    match = strcmp(v2, v1);
    if match, match_count = match_count + 1; end
    
    fprintf('  %-22s | %-20s | %-20s | %s\n', f, v2, v1, ternary_s(match, '==', '!='));
end
fprintf('\n  匹配: %d/%d\n', match_count, length(fields));
fprintf('############################################################\n');

% 清理
try ModelUtil.remove('Model'); catch, end

end

function bg = deal_with_model(model, name)
    bg = struct();
    phys = model.physics('emw');
    
    % BackgroundField 属性
    try
        bg.Eb = mat2str(cell2mat(phys.prop('BackgroundField').get('Eb')));
    catch
        try
            bg.Eb = char(phys.prop('BackgroundField').getString('Eb'));
        catch
            bg.Eb = 'N/A';
        end
    end
    fprintf('  Eb = %s\n', bg.Eb);
    
    % 尝试其他属性
    props_to_check = {'BackgroundFieldType', 'E0x', 'E0y', 'E0z', ...
        'kx', 'ky', 'kz', 'theta0', 'phi0'};
    for pi = 1:length(props_to_check)
        pn = props_to_check{pi};
        try
            val = phys.prop('BackgroundField').get(pn);
            if isnumeric(val), val = mat2str(val); else, val = char(val); end
            bg.(pn) = val;
        catch
            % 不存在，跳过
        end
    end
    
    % 背景场类型
    try
        bf_type = phys.prop('BackgroundField').getString('BackgroundFieldType');
        bg.BackgroundFieldType = char(bf_type);
    catch
        try
            bg.BackgroundFieldType = char(phys.prop('BackgroundField').getString('WaveType'));
        catch
            bg.BackgroundFieldType = 'N/A';
        end
    end
    fprintf('  BgType = %s\n', bg.BackgroundFieldType);
    
    % E0 分量（参数变量）
    for d = {'x','y','z'}
        try
            val = model.param.get(['E0' d{1}]);
            bg.(['E0' d{1}]) = char(val);
        catch
            bg.(['E0' d{1}]) = 'N/A';
        end
    end
    
    % 全局参数 freq
    try
        bg.freq = char(model.param.get('freq'));
    catch
        bg.freq = 'N/A';
    end
    fprintf('  freq = %s\n', bg.freq);
    
    % adjoint_mode
    try
        bg.adjoint_mode = char(model.param.get('adjoint_mode'));
    catch
        bg.adjoint_mode = 'N/A';
    end
    fprintf('  adjoint_mode = %s\n', bg.adjoint_mode);
    
    % k_direction 参数
    % 检查是否有 sctr1 (Scattering) 的 theta0/phi0
    try
        bg.sctr1_theta0 = char(phys.feature('sctr1').getString('theta0'));
    catch
        bg.sctr1_theta0 = 'N/A';
    end
    try
        bg.sctr1_phi0 = char(phys.feature('sctr1').getString('phi0'));
    catch
        bg.sctr1_phi0 = 'N/A';
    end
    fprintf('  sctr1 theta0=%s, phi0=%s\n', bg.sctr1_theta0, bg.sctr1_phi0);
    
    % 尝试 E0 参数
    for d = {'x','y','z'}
        pn = ['E0' d{1}];
        try
            bg.(pn) = char(model.param.get(pn));
            fprintf('  %s = %s\n', pn, bg.(pn));
        catch
            bg.(pn) = 'N/A';
        end
    end
end

function s = ternary_s(cond, a, b)
    if cond, s=a; else, s=b; end
end
