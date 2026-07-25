function [E_r, E_theta, E_phi] = cart2sph_field(E_cart, r_hat, theta_hat, phi_hat)
%CART2SPH_FIELD 电场笛卡尔 → 球坐标变换
%   [E_r, E_theta, E_phi] = cart2sph_field(E_cart, r_hat, theta_hat, phi_hat)
%
%   输入:
%       E_cart     [N × 3] — 笛卡尔分量 (Ex, Ey, Ez)
%       r_hat      [N × 3] — 径向单位向量
%       theta_hat  [N × 3] — theta 单位向量
%       phi_hat    [N × 3] — phi 单位向量
%   输出:
%       E_r, E_theta, E_phi — [N × 1] 各球坐标分量

E_r     = dot(E_cart, r_hat, 2);
E_theta = dot(E_cart, theta_hat, 2);
E_phi   = dot(E_cart, phi_hat, 2);

end

function E_cart = sph2cart_field(E_r, E_theta, E_phi, r_hat, theta_hat, phi_hat)
%SPH2CART_FIELD 电场球坐标 → 笛卡尔变换
%   E_cart = sph2cart_field(E_r, E_theta, E_phi, r_hat, theta_hat, phi_hat)
%
%   E_cart = E_r·r̂ + E_theta·θ̂ + E_phi·φ̂

E_cart = E_r .* r_hat + E_theta .* theta_hat + E_phi .* phi_hat;

end
