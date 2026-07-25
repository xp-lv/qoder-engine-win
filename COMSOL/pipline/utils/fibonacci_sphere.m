function [points, dOmega] = fibonacci_sphere(N)
%FIBONACCI_SPHERE 斐波那契球面均匀采样
%   [points, dOmega] = fibonacci_sphere(N)
%
%   输入:
%       N  采样点数
%   输出:
%       points  [N × 3] — 单位球面上的点（单位向量）
%       dOmega  [N × 1] — 每点的立体角权重

points = zeros(N, 3);
phi = pi * (3 - sqrt(5));  % 黄金角

for i = 1:N
    y = 1 - (i - 0.5) * 2 / N;  % y 从 1 到 -1 均匀分布
    radius = sqrt(1 - y^2);
    theta = phi * (i - 1);
    
    points(i, :) = [cos(theta) * radius, sin(theta) * radius, y];
end

% 均匀立体角权重
dOmega = (4 * pi / N) * ones(N, 1);

end
