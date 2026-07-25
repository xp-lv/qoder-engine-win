function lc = lightcone_project(grid, sf, p)
%LIGHTCONE_PROJECT 表面等效定理 → 观测光锥横向分量 J_obs
%   lc = lightcone_project(grid, sf, p)
%
%   等效面源: J_s = n̂×H^s, M_s = E^s×n̂
%   光锥投影积分核（横向）:
%     J_obs(k̂) = ∫ { [Ī−k̂k̂]·(n̂×H^s) + [n̂(E^s·k̂) − E^s(n̂·k̂)]/η₀ } e^{-ikr} dS
%
%   输入:
%       grid  测量网格（pos, norm, weight）
%       sf    散射场（E_cart, H_cart）
%       p     config
%   输出:
%       lc    LightConeData（k_dir, k_vec, dOmega, J_obs_perp）

N_surface = size(grid.pos, 1);
N_k = p.N_k;

% 1. k 方向采样（斐波那契球面）
[k_dir, dOmega] = fibonacci_sphere(N_k);
k_vec = p.k0 * k_dir;

% 2. 预计算表面量
w     = grid.weight(:);
n_hat = grid.norm;
pos   = grid.pos;
E_cart = sf.E_cart;
H_cart = sf.H_cart;
eta0   = p.eta0;

n_cross_H = cross(n_hat, H_cart, 2);  % [N_surface × 3]

% 3. 逐 k 方向积分
J_obs_perp = zeros(N_k, 3);

for i = 1:N_k
    ki = k_dir(i, :);  % [1 × 3] k̂
    
    E_dot_k = E_cart * ki(:);     % [N_surface × 1]
    n_dot_k = n_hat * ki(:);      % [N_surface × 1]
    k_dot_nH = (ki * n_cross_H')'; % [N_surface × 1]
    
    % 积分核（已横向）: [Ī−k̂k̂]·(n̂×H) + [...E...]/η₀
    integrand = (k_dot_nH .* ki - n_cross_H) ...
              + (n_hat .* E_dot_k - n_dot_k .* E_cart) / eta0;
    
    % 面积分
    phase = exp(-1i * pos * (p.k0 * ki(:)));
    J_obs_perp(i, :) = sum(w .* integrand .* phase, 1);
end

% 4. 输出
lc.k_dir      = k_dir;
lc.k_vec      = k_vec;
lc.dOmega     = dOmega;
lc.J_obs_perp = J_obs_perp;
lc.J_hyp_perp = [];
lc.Delta_J_perp = [];

fprintf('[lightcone_project] J_obs 光锥投影完成: N_k=%d\n', N_k);
fprintf('  |J_obs_perp| mean=%.4e\n', mean(vecnorm(J_obs_perp, 2, 2)));

end
