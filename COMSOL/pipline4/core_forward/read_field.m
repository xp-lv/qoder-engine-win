function [E, pos] = read_field(model, eval_pos, solnum, use_scattered)
%READ_FIELD 从已求解的 COMSOL 模型中插值提取电场
%   [E, pos] = read_field(model, eval_pos)
%   [E, pos] = read_field(model, eval_pos, solnum)
%   [E, pos] = read_field(model, eval_pos, solnum, use_scattered)
%
%   输入:
%       model          COMSOL 模型（已求解）
%       eval_pos       [N × 3] 评估点坐标
%       solnum         (可选) 解编号
%       use_scattered  (可选) true=读取散射场 Esx/Esy/Esz (FEM DOF)
%                                  false=读取总场 Ex/Ey/Ez (默认)
%   输出:
%       E         [N × 3] complex — 各分量电场
%       pos       [N × 3] — 评估点坐标（原样返回）

fprintf('[read_field] 提取 %d 个评估点...\n', size(eval_pos, 1));

if nargin < 3, solnum = []; end
if nargin < 4, use_scattered = false; end

% 选择场变量名
if use_scattered
    var_x = 'emw.Esx'; var_y = 'emw.Esy'; var_z = 'emw.Esz';
    fprintf('  模式: 散射场 (Esx/Esy/Esz)\n');
else
    var_x = 'emw.Ex'; var_y = 'emw.Ey'; var_z = 'emw.Ez';
end

try
    % 使用 mphinterp 在指定坐标插值
    if isempty(solnum)
        Ex = mphinterp(model, var_x, 'coord', eval_pos');
        Ey = mphinterp(model, var_y, 'coord', eval_pos');
        Ez = mphinterp(model, var_z, 'coord', eval_pos');
    else
        Ex = mphinterp(model, var_x, 'coord', eval_pos', 'solnum', solnum);
        Ey = mphinterp(model, var_y, 'coord', eval_pos', 'solnum', solnum);
        Ez = mphinterp(model, var_z, 'coord', eval_pos', 'solnum', solnum);
    end
    pos = eval_pos;
    E = [Ex(:), Ey(:), Ez(:)];
catch ME_interp
    % mphinterp 失败，回退到 mpheval + 最近邻映射
    fprintf('  mphinterp 失败: %s\n', ME_interp.message);
    fprintf('  使用 mpheval + 最近邻...\n');
    Ex_d = mpheval(model, var_x);
    Ey_d = mpheval(model, var_y);
    Ez_d = mpheval(model, var_z);
    
    comsol_pos = Ex_d.p';
    comsol_E = [Ex_d.d1(:), Ey_d.d1(:), Ez_d.d1(:)];
    
    idx = dsearchn(comsol_pos, eval_pos);
    pos = eval_pos;
    E = comsol_E(idx, :);
end

fprintf('[read_field] 完成: |E| range [%.4e, %.4e]\n', ...
    min(vecnorm(E,2,2)), max(vecnorm(E,2,2)));

end
