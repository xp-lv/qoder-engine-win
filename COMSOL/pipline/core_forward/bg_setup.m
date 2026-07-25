function bg_setup(model, bg, p)
%BG_SETUP 将背景场配置写入 COMSOL 模型
%   bg_setup(model, bg, p)
%   根据 bg.type 修改 mph 模型中的背景场设置。
%
%   平面波: 修改 sctr1 (ScatteredField) 的入射波参数
%   高斯波束: 需通过 External Field / User Defined 实现（更复杂）

if isempty(model)
    fprintf('[bg_setup] 模型为空，跳过背景场设置\n');
    return;
end

fprintf('[bg_setup] 设置背景场: %s\n', bg.description);

switch bg.type
    case 'planewave'
        bg_setup_planewave(model, bg, p);
    case 'gaussian'
        bg_setup_gaussian(model, bg, p);
    otherwise
        error('bg_setup: 未知背景场类型: %s', bg.type);
end

end

%% ---- 平面波设置 ----
function bg_setup_planewave(model, bg, p)
% 修改散射场公式中的入射平面波参数
% COMSOL 散射场公式 (scattered-field formulation):
%   E_total = E_scat + E_inc
%   其中 E_inc 由 sctr1 特征定义

try
    phys = model.physics('emw');
    
    % 设置入射波电场幅度
    % COMSOL 中 sctr1 的 E0 字段期望 [Ex0, Ey0, Ez0] (V/m)
    try
        phys.feature('sctr1').set('E0', {num2str(bg.E0(1)), ...
                                          num2str(bg.E0(2)), ...
                                          num2str(bg.E0(3))});
    catch
        % 如果模型中没有 sctr1，尝试 port 特征
        try
            phys.feature('port1').set('E0', {num2str(bg.E0(1)), ...
                                              num2str(bg.E0(2)), ...
                                              num2str(bg.E0(3))});
        catch
            fprintf('[bg_setup] 无法设置 E0: 模型缺少 sctr1 或 port1 特征\n');
        end
    end
    
    % 设置入射波传播方向（k 方向）
    % 在 COMSOL 中通常通过 port 的方位角/仰角指定
    % 如果模型使用 sctr1 + 用户自定义，则需要设置 k 矢量
    theta = acosd(bg.k_dir(3));
    phi   = atan2d(bg.k_dir(2), bg.k_dir(1));
    
    try
        phys.feature('sctr1').set('theta0', num2str(theta));
        phys.feature('sctr1').set('phi0', num2str(phi));
    catch
        fprintf('[bg_setup] 无法设置入射角 theta/phi\n');
    end
    
    fprintf('[bg_setup] 平面波: E0=[%.1f,%.1f,%.1f] V/m, θ=%.1f°, φ=%.1f°\n', ...
        bg.E0(1), bg.E0(2), bg.E0(3), theta, phi);
    
catch ME
    fprintf('[bg_setup] 平面波设置失败: %s\n', ME.message);
end

end

%% ---- 高斯波束设置 ----
function bg_setup_gaussian(model, bg, p)
% 高斯波束需要用户在 COMSOL 模型中预定义
% "User Defined" 类型的外部场，或通过解析表达式注入

fprintf('[bg_setup] 高斯波束: 需要 COMSOL 模型中预置 UserDefined 背景场\n');
fprintf('  参数: waist=%.2fm, focus=[%.2f,%.2f,%.2f]\n', ...
    bg.waist, bg.focus(1), bg.focus(2), bg.focus(3));

try
    phys = model.physics('emw');
    
    % 尝试设置 sctr1 为 user defined 模式
    try
        phys.feature('sctr1').set('type', 'userdefined');
    catch
        fprintf('[bg_setup] 模型不支持 userdefined 背景场，请手动配置\n');
    end
    
catch ME
    fprintf('[bg_setup] 高斯波束设置失败: %s\n', ME.message);
end

end
