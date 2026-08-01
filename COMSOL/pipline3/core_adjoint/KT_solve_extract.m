function lambda_vox = KT_solve_extract(model, voxel, p, f_adj, source_pos)
%KT_SOLVE_EXTRACT K^T 伴随求解 + 纯 MATLAB 场值提取
%   绕过 COMSOL mphinterp/setU 限制，直接从 DOF 解提取体素中心场值

inner = voxel.mask_interior;
inner_pos = voxel.pos(inner, :);

% 1. 写入伴随源（体积路径，已在调用前完成）
% 2. mphmatrix 提取 Kc, Lc
MA = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');

% 3. K^T \ Lc（正确伴随求解）
Uc = MA.Kc' \ MA.Lc;

% 4. 还原完整 DOF 解
U0 = MA.Null * Uc + MA.ud;
U_full = U0 .* MA.uscale;

% 5. 提取 DOF 索引和节点坐标
% COMSOL EMW 的 DOF 排列: Ex(1), Ey(1), Ez(1), Ex(2), Ey(2), Ez(2), ...
% 每个节点 3 个 DOF（x,y,z 分量）
N_dof = length(U_full);
N_nodes = N_dof / 3;

% 获取网格节点坐标
mesh = model.mesh('mesh1');
verts = mesh.getVertex()';  % [N_vert x 3]
fprintf('[KT_extract] N_dof=%d, N_nodes_est=%d, N_vert=%d\n', N_dof, N_nodes, size(verts,1));

% U_full 的排列: [Ex1, Ey1, Ez1, Ex2, Ey2, Ez2, ...]
Ux = U_full(1:3:end);
Uy = U_full(2:3:end);
Uz = U_full(3:3:end);

% 6. 用 mphinterp 提取（先尝试 setU + mphinterp）
fprintf('[KT_extract] 尝试 setU(1) + mphinterp...\n');
try
    model.sol('sol1').setU(1, U_full);
    Ex_v = mphinterp(model, 'emw.Ex', 'coord', inner_pos');
    Ey_v = mphinterp(model, 'emw.Ey', 'coord', inner_pos');
    Ez_v = mphinterp(model, 'emw.Ez', 'coord', inner_pos');
    lambda_vox = [Ex_v(:), Ey_v(:), Ez_v(:)];
    fprintf('[KT_extract] mphinterp 成功: %d points\n', size(lambda_vox, 1));
    return;
catch ME
    fprintf('[KT_extract] mphinterp 失败: %s\n', ME.message);
end

% 7. 回退: 用 dsearchn 最近邻插值
fprintf('[KT_extract] 回退到最近邻映射...\n');
% 节点场值
node_E = [Ux, Uy, Uz];
% 找每个体素质心最近的网格节点
idx = dsearchn(verts, inner_pos);
lambda_vox = node_E(idx, :);
fprintf('[KT_extract] 最近邻映射完成: %d points\n', size(lambda_vox, 1));
fprintf('  |lambda| range [%.4e, %.4e]\n', min(vecnorm(lambda_vox,2,2)), max(vecnorm(lambda_vox,2,2)));

end
