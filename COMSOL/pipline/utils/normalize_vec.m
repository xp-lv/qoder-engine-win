function v_out = normalize_vec(v_in, target_dir)
%NORMALIZE_VEC 向量方向归一化工具——防止 MATLAB horzcat/vertcat 维度崩溃
%   v_out = normalize_vec(v_in, target_dir)
%
%   背景: MATLAB 向量索引的「源方向继承」语义——A(I) 与 A 同方向而非与 I 同方向，
%   导致 horzcat(A(I), (c:d)) 在 A 为列向量时崩溃（H022 + H024 两起同类 bug）。
%   本工具提供显式归一化，消除方向歧义。
%
%   输入:
%       v_in        [N×1] 或 [1×N] — 输入向量（任意方向）
%       target_dir  'row' 或 'col'  — 目标方向
%   输出:
%       v_out       [1×N]（target_dir='row'）或 [N×1]（target_dir='col'）
%
%   用法:
%       % 替代手工 A(:).' —— 在 horzcat 前统一方向:
%       idx_row = normalize_vec(sort_idx, 'row');
%       result  = [idx_row(1:k), idx_row(k+1:end), (a:b)];
%
%       % 替代手工 A(:) —— 在 vertcat 前统一方向:
%       col_vec = normalize_vec(data, 'col');
%
%   设计原则: 纯维度鲁棒化，零逻辑变更。等价于 A(:).' 或 A(:)，
%   但提供语义化的函数名，使代码审查时方向意图一目了然。
%
%   关联 bug:
%     - H022: hole_true.' → hole_true(:).'  (C01_cavity_inversion_loop.m line 204)
%     - H024: d_sort_idx  → d_sort_idx(:).'  (C01_cavity_inversion_loop.m line 594)

if nargin < 2
    target_dir = 'row';  % 默认行向量（horzcat 最常见场景）
end

switch lower(target_dir)
    case 'row'
        v_out = v_in(:).';   % 强制行向量 [1×N]
    case 'col'
        v_out = v_in(:);     % 强制列向量 [N×1]
    otherwise
        error('normalize_vec:invalidDir', ...
            'target_dir 必须为 ''row'' 或 ''col''，收到 ''%s''', target_dir);
end

end
