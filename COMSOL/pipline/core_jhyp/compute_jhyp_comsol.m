function J_hyp = compute_jhyp_comsol(model, lc, p)
%COMPUTE_JHYP_COMSOL 使用 COMSOL mphint2 Gauss 积分计算 J_hyp
%   J_hyp = compute_jhyp_comsol(model, lc, p)
%
%   使用 COMSOL 内置 Gauss 积分（intorder=4）对 FEM 体积进行 Born FT:
%     J_tilde(k) = intV( J_eq(r) * exp(-i*k0*k_hat·r) ) dV
%     其中 J_eq = -i*omega*(D - eps0*E)
%   然后进行横向投影。
%
%   输入:
%       model   COMSOL 模型对象（已 solve）
%       lc      LightConeData（含 k_dir）
%       p       config
%   输出:
%       J_hyp   [N_k × 3] complex — 横向投影后的光锥分量

N_k = size(lc.k_dir, 1);
k0 = p.k0;
eps0 = p.eps0;
omega = p.omega(1);

% Spatial filter: restrict to scatterer volume (sphere of radius a_scatter)
R2 = p.a_scatter^2;
vol_filter = sprintf('(x^2+y^2+z^2<%.15e)', R2);

fprintf('[compute_jhyp_comsol] COMSOL Gauss integration: %d k-dirs, R=%.4f m...\n', ...
    N_k, p.a_scatter);

J_tilde = zeros(N_k, 3);
field_names = {'emw.Ex', 'emw.Ey', 'emw.Ez'};
d_names    = {'emw.Dx', 'emw.Dy', 'emw.Dz'};

t_start = tic;

for i = 1:N_k
    kx = lc.k_dir(i, 1);
    ky = lc.k_dir(i, 2);
    kz = lc.k_dir(i, 3);
    
    phase = sprintf('exp(-i*%.15e*(%.15e*x+%.15e*y+%.15e*z))', k0, kx, ky, kz);
    
    % Build and evaluate each component individually
    % NOTE: mphint2 with cell array only returns first expression!
    for d = 1:3
        expr = sprintf('(-i*%.15e*(%s - %.15e*%s))*%s*%s', ...
            omega, d_names{d}, eps0, field_names{d}, phase, vol_filter);
        J_tilde(i, d) = mphint2(model, expr, 'volume', 'dataset', 'dset1', ...
                                'intorder', 4);
    end
end

t_elapsed = toc(t_start);
fprintf('[compute_jhyp_comsol] Done: %.1f s (%.2f s/k-dir)\n', t_elapsed, t_elapsed/N_k);

% Transverse projection
J_hyp = zeros(N_k, 3);
for i = 1:N_k
    if ~any(isnan(J_tilde(i, :)))
        J_hyp(i, :) = transverse_project(J_tilde(i, :), lc.k_dir(i, :));
    end
end

fprintf('[compute_jhyp_comsol] |J_hyp| mean=%.4e\n', mean(vecnorm(J_hyp, 2, 2)));

end
