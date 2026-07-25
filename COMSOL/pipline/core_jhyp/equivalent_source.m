function J_equi = equivalent_source(voxel, E_total, p)
%EQUIVALENT_SOURCE 体积等效原理：J_equi = -iωε₀(ε_r-1)E_total
%   J_equi = equivalent_source(voxel, E_total, p)
%
%   输入:
%       voxel   体素网格（epsilon_r, mask_interior）
%       E_total [N_inner × 3] complex — 内部体素中心全场
%       p       config
%   输出:
%       J_equi  [N_v × 3] complex — 全体素的等效电流密度

N_v = length(voxel.epsilon_r);
N_in = sum(voxel.mask_interior);
inner = voxel.mask_interior;

% 将 E_total 映射到全体素网格
E_vox = zeros(N_v, 3);
if size(E_total, 1) == N_in
    E_vox(inner, :) = E_total;
else
    error('equivalent_source: E_total 行数 (%d) != 内部体素数 (%d)', ...
        size(E_total,1), N_in);
end

% J_equi = -iωε₀(ε_r - 1)E
omega = p.omega(1);
delta_eps = voxel.epsilon_r - 1;
J_equi = zeros(N_v, 3);

for d = 1:3
    J_equi(inner, d) = -1i * omega * p.eps0 * delta_eps(inner) .* E_vox(inner, d);
end

fprintf('[equivalent_source] |J_equi| mean=%.4e\n', ...
    mean(vecnorm(J_equi(inner,:), 2, 2)));

end
