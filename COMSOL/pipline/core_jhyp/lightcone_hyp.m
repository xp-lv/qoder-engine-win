function J_hyp = lightcone_hyp(voxel, J_equi, lc, p)
%LIGHTCONE_HYP 体积等效源 → 假设光锥横向分量 J_hyp
%   J_hyp = lightcone_hyp(voxel, J_equi, lc, p)
%
%   Born 傅里叶变换（体积求和）:
%     J_hyp(k̂) = Σ_v J_equi(r_v) ΔV e^{-ikr_v}
%   然后横向投影:
%     J_hyp_perp(k̂) = [Ī − k̂k̂] · J̃_hyp(k̂)
%
%   输入:
%       voxel   体素网格（pos, mask_interior, dV）
%       J_equi  [N_v × 3] complex — 等效源
%       lc      LightConeData（k_dir, k_vec）
%       p       config
%   输出:
%       J_hyp   [N_k × 3] complex — 横向光锥分量

N_k = size(lc.k_dir, 1);
k0 = p.k0;

% 仅内部体素
inner = voxel.mask_interior;
pos_inner = voxel.pos(inner, :);
J_equi_inner = J_equi(inner, :);
dV_inner = voxel.dV(inner);

% 1. Born FT
J_tilde = zeros(N_k, 3);
for i = 1:N_k
    ki = lc.k_dir(i, :);
    k_vec_i = k0 * ki;
    phase = exp(-1i * pos_inner * k_vec_i(:));
    
    for d = 1:3
        J_tilde(i, d) = sum(dV_inner .* J_equi_inner(:, d) .* phase);
    end
end

% 2. 横向投影
J_hyp = zeros(N_k, 3);
for i = 1:N_k
    J_hyp(i, :) = transverse_project(J_tilde(i, :), lc.k_dir(i, :));
end

fprintf('[lightcone_hyp] |J_hyp| mean=%.4e\n', mean(vecnorm(J_hyp, 2, 2)));

end
