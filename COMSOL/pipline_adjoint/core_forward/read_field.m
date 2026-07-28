function [E, pos] = read_field(model, eval_pos, solnum)
%READ_FIELD 从已求解的 COMSOL 模型中插值提取电场
%   [E, pos] = read_field(model, eval_pos)
%
%   输入:
%       model     COMSOL 模型（已求解）
%       eval_pos  [N × 3] 评估点坐标
%       solnum    (可选) 解编号, 用于多频解
%   输出:
%       E         [N × 3] complex — 各分量电场
%       pos       [N × 3] — 评估点坐标（原样返回）

fprintf('[read_field] 提取 %d 个评估点...\n', size(eval_pos, 1));

if nargin < 3, solnum = []; end

try
    % 使用 mphinterp 在指定坐标插值
    if isempty(solnum)
        Ex = mphinterp(model, 'emw.Ex', 'coord', eval_pos');
        Ey = mphinterp(model, 'emw.Ey', 'coord', eval_pos');
        Ez = mphinterp(model, 'emw.Ez', 'coord', eval_pos');
    else
        Ex = mphinterp(model, 'emw.Ex', 'coord', eval_pos', 'solnum', solnum);
        Ey = mphinterp(model, 'emw.Ey', 'coord', eval_pos', 'solnum', solnum);
        Ez = mphinterp(model, 'emw.Ez', 'coord', eval_pos', 'solnum', solnum);
    end
    pos = eval_pos;
    E = [Ex(:), Ey(:), Ez(:)];
catch
    % mphinterp 失败，回退到 mpheval + 最近邻映射
    fprintf('  mphinterp 失败，使用 mpheval + 最近邻...\n');
    Ex_d = mpheval(model, 'emw.Ex');
    Ey_d = mpheval(model, 'emw.Ey');
    Ez_d = mpheval(model, 'emw.Ez');
    
    comsol_pos = Ex_d.p';
    comsol_E = [Ex_d.d1(:), Ey_d.d1(:), Ez_d.d1(:)];
    
    idx = dsearchn(comsol_pos, eval_pos);
    pos = eval_pos;
    E = comsol_E(idx, :);
end

fprintf('[read_field] 完成: |E| range [%.4e, %.4e]\n', ...
    min(vecnorm(E,2,2)), max(vecnorm(E,2,2)));

end
