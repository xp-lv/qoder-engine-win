function [G_EE, G_EH, G_HE, G_HH] = green_function(r, k0)
%GREEN_FUNCTION 自由空间并矢格林函数
%   [G_EE, G_EH, G_HE, G_HH] = green_function(r, k0)
%
%   G_EE(r) = (I + grad(grad)/k0^2) * exp(ikr) / (4*pi*r)
%   简化为远场近似或全波形式，取决于需求。
%
%   输入:
%       r   [N × 3] — 观测点坐标
%       k0  double  — 自由空间波数
%   输出:
%       各并矢分量 [N × 3 × 3]

N = size(r, 1);
r_mag = vecnorm(r, 2, 2);

% 自由空间标量格林函数
g0 = exp(1i * k0 * r_mag) ./ (4 * pi * r_mag);

% 单位张量 I (3×3)
I = eye(3);

% 预分配
G_EE = zeros(N, 3, 3);

for i = 1:N
    ri = r(i, :);
    r_norm = r_mag(i);
    r_hat = ri / r_norm;
    rr = r_hat' * r_hat;  % 3×3
    
    % 近场项
    G_EE(i, :, :) = g0(i) * (I - rr) ...
        + g0(i) * (1i / (k0 * r_norm) - 1 / (k0 * r_norm)^2) * (I - 3 * rr);
end

G_EH = []; G_HE = []; G_HH = [];
end
