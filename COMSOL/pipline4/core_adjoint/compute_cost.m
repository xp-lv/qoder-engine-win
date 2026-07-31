function F = compute_cost(probe, E_hyp, E_truth, p)
%COMPUTE_COST 近场 L2 代价函数（极简标量）
%   F = compute_cost(probe, E_hyp, E_truth, p)
%
%   F = Σ_p w_p |E(r_p) - E*(r_p)|²  /  Σ_p w_p |E*(r_p)|²
%
%   输入:
%       probe    探针点结构（pos, weight）
%       E_hyp    [N_probe × 3] 当前 ε_r 下的探针点电场
%       E_truth  [N_probe × 3] 真值电场
%       p        config
%   输出:
%       F        double — 归一化残差（标量）

w = probe.weight;

residual = E_hyp - E_truth;
F_norm = sum(w .* sum(abs(E_truth).^2, 2));

if F_norm < p.F_norm_min
    F_norm = 1.0;
end

F = sum(w .* sum(abs(residual).^2, 2)) / F_norm;

end
