function [g_re, g_im] = compute_gradient_kmatrix(model, voxel, p, lambda_dof, u_dof, delta)
%COMPUTE_GRADIENT_KMATRIX K 矩阵差分法精确梯度（pipline4）
%
%   绕过所有解析公式近似，直接用 K 矩阵差分计算精确梯度:
%     dF/dε = -2·Re(λ^T · dK · u)   (Wirtinger 因子 2)
%
%   其中 dK 通过 ε_r ± δ 的两次 mphmatrix 提取差分获得，
%   λ 和 u 通过 COMSOL Java API getU() 直接获取 DOF 向量。
%
%   用法（在 verify 脚本中内联调用，或作为独立函数）:
%     [g_re, g_im] = compute_gradient_kmatrix(model, voxel, p, lambda_dof, u_dof, delta)
%
%   输入:
%       model       COMSOL 模型（已求解，当前 ε_r 状态）
%       voxel       体素结构
%       p           config
%       lambda_dof  伴随解 DOF 向量 [N_dof × 1] complex
%       u_dof       正演解 DOF 向量 [N_dof × 1] complex
%       delta       FD 步长（默认 0.01）
%   输出:
%       g_re  dF/dε'（全局均匀扰动）
%       g_im  dF/dε''

if nargin < 6, delta = 0.01; end

inner = voxel.mask_interior;
inner_idx = find(inner);
eps_re_base = real(voxel.epsilon_r);
eps_im_base = imag(voxel.epsilon_r);

%% dK/dε' （全局均匀扰动）
% ε' + δ
voxel.epsilon_r(inner_idx) = (eps_re_base(inner_idx) + delta) + 1j * eps_im_base(inner_idx);
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolution();
model.sol('sol1').runAll();
MA_p = mphmatrix(model, 'sol1', 'out', {'K'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

% ε' - δ
voxel.epsilon_r(inner_idx) = (eps_re_base(inner_idx) - delta) + 1j * eps_im_base(inner_idx);
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolution();
model.sol('sol1').runAll();
MA_m = mphmatrix(model, 'sol1', 'out', {'K'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

dK_re = (MA_p.K - MA_m.K) / (2 * delta);

%% dK/dε''
% ε'' + δ
voxel.epsilon_r(inner_idx) = eps_re_base(inner_idx) + 1j * (eps_im_base(inner_idx) + delta);
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolution();
model.sol('sol1').runAll();
MA_p = mphmatrix(model, 'sol1', 'out', {'K'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

% ε'' - δ
voxel.epsilon_r(inner_idx) = eps_re_base(inner_idx) + 1j * (eps_im_base(inner_idx) - delta);
update_epsilon(model, voxel, p);
model.sol('sol1').clearSolution();
model.sol('sol1').runAll();
MA_m = mphmatrix(model, 'sol1', 'out', {'K'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', 'symmetry', 'off');

dK_im = (MA_p.K - MA_m.K) / (2 * delta);

%% 恢复 ε_r
voxel.epsilon_r(inner_idx) = eps_re_base(inner_idx) + 1j * eps_im_base(inner_idx);
update_epsilon(model, voxel, p);

%% 精确梯度: dF/dε = -2·Re(λ^T · dK · u)
g_re = -2 * real(lambda_dof' * dK_re * u_dof);
g_im = -2 * real(lambda_dof' * dK_im * u_dof);

fprintf('[compute_gradient_kmatrix] g_re=%+.6e, g_im=%+.6e\n', g_re, g_im);

end
