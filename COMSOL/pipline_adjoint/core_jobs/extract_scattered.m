function sf = extract_scattered(model, grid)
%EXTRACT_SCATTERED Extract scattered field directly from COMSOL model
%   sf = extract_scattered(model, grid)
%
%   Extracts COMSOL native emw.relE (scattered field) and emw.relH at
%   measurement sphere grid points. No ratio method, no analytic E_inc.
%
%   Input:
%       model   solved COMSOL model (with scattered-field formulation)
%       grid    measurement grid (pos, r_hat, theta_hat, phi_hat)
%   Output:
%       sf      scattered field struct (E_cart, H_cart, E_theta, etc.)

N_surface = size(grid.pos, 1);
coords = grid.pos';  % [3 x N] for mphinterp

%% Extract COMSOL scattered field (Cartesian)
rEx = mphinterp(model, 'emw.relEx', 'coord', coords);
rEy = mphinterp(model, 'emw.relEy', 'coord', coords);
rEz = mphinterp(model, 'emw.relEz', 'coord', coords);
E_cart = [rEx(:), rEy(:), rEz(:)];

rHx = mphinterp(model, 'emw.relHx', 'coord', coords);
rHy = mphinterp(model, 'emw.relHy', 'coord', coords);
rHz = mphinterp(model, 'emw.relHz', 'coord', coords);
H_cart = [rHx(:), rHy(:), rHz(:)];

%% Convert to spherical (theta/phi) for backward compatibility
E_theta = zeros(N_surface, 1);
E_phi   = zeros(N_surface, 1);
H_theta = zeros(N_surface, 1);
H_phi   = zeros(N_surface, 1);

for i = 1:N_surface
    E_theta(i) = dot(E_cart(i,:), grid.theta_hat(i,:));
    E_phi(i)   = dot(E_cart(i,:), grid.phi_hat(i,:));
    H_theta(i) = dot(H_cart(i,:), grid.theta_hat(i,:));
    H_phi(i)   = dot(H_cart(i,:), grid.phi_hat(i,:));
end

%% Output
sf.E_cart  = E_cart;
sf.H_cart  = H_cart;
sf.E_theta = E_theta;
sf.E_phi   = E_phi;
sf.H_theta = H_theta;
sf.H_phi   = H_phi;

fprintf('[extract_scattered] COMSOL relE extracted: %d points, |E_scat| mean=%.4e\n', ...
    N_surface, mean(vecnorm(E_cart, 2, 2)));

end
