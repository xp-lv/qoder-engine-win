function J_perp = transverse_project(J, k_hat)
%TRANSVERSE_PROJECT 横向投影算子: J_perp = (I - k̂k̂) · J
%   J_perp = transverse_project(J, k_hat)
%
%   消除矢量中沿 k̂ 方向的分量，保留横向部分。
%
%   输入:
%       J     [1 × 3] or [N × 3] — 待投影矢量
%       k_hat [1 × 3] or [N × 3] — 单位方向向量
%   输出:
%       J_perp 与 J 同形状

N = size(J, 1);

if size(k_hat, 1) == 1
    k_hat = repmat(k_hat, N, 1);
end

J_k = sum(J .* k_hat, 2);  % [N × 1] — J 沿 k̂ 的分量 (不取共轭, 线性投影算子)
J_perp = J - J_k .* k_hat;

end
