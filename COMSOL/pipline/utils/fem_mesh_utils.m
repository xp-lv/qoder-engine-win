function voxel = fem_mesh_utils(model, p, R_scatter)
%FEM_MESH_UTILS 从 COMSOL 模型提取 FEM 网格，替代均匀体素
%   voxel = fem_mesh_utils(model, p, R_scatter)
%
%   使用 model.mesh('mesh1') Java API 获取顶点和单元连接，
%   计算每个单元的质心位置和体积，标记内部单元。
%
%   输出 voxel 结构与 mesh_utils 兼容：
%       .pos            [N_elem x 3] 单元质心坐标
%       .dV             [N_elem x 1] 单元体积
%       .epsilon_r      [N_elem x 1] 介电常数分布
%       .mask_interior  [N_elem x 1] 内部单元标记 (r < R_scatter)
%       .gauss_pos      [4*N_inner x 3] Gauss积分点坐标（仅tet内部单元）
%       .gauss_w        [4 x 1] Gauss积分权重
%
%   输入:
%       model       COMSOL 模型对象
%       p           config（使用 p.a_scatter 作为散射体半径）
%       R_scatter   散射体球半径 [m]

fprintf('[fem_mesh_utils] 提取 COMSOL FEM 网格...\n');

if isempty(model)
    error('fem_mesh_utils: 模型为空');
end

%% 1. 获取网格数据（COMSOL 6.2 Java API）
try
    mesh = model.mesh('mesh1');
    verts = mesh.getVertex()';   % [N_vert x 3] double
catch ME
    error('fem_mesh_utils: 获取顶点失败: %s', ME.message);
end

N_vert = size(verts, 1);

%% 2. 提取体积单元（tet + prism）
elem_data = {};  % 每行: {conn_matrix, nodes_per_elem}

% 四面体
if mesh.getNumElem('tet') > 0
    conn = mesh.getElem('tet');             % [4 x N_tet] int32, 0-indexed
    conn = double(conn)' + 1;               % [N_tet x 4], 1-indexed
    elem_data{end+1} = {conn, 4};
    fprintf('  tet: %d 单元\n', size(conn, 1));
end

% 三棱柱
if mesh.getNumElem('prism') > 0
    conn = mesh.getElem('prism');           % [6 x N_prism] int32, 0-indexed
    conn = double(conn)' + 1;               % [N_prism x 6], 1-indexed
    elem_data{end+1} = {conn, 6};
    fprintf('  prism: %d 单元\n', size(conn, 1));
end

if isempty(elem_data)
    error('fem_mesh_utils: 无体积单元');
end

fprintf('  总顶点: %d\n', N_vert);

%% 3. 逐单元计算质心和体积
N_total = 0;
for k = 1:length(elem_data)
    N_total = N_total + size(elem_data{k}{1}, 1);
end

pos_all = zeros(N_total, 3);
dV_all  = zeros(N_total, 1);
count   = 0;

for k = 1:length(elem_data)
    conn = elem_data{k}{1};  % [N_elem x npe]
    npe  = elem_data{k}{2};
    N_e  = size(conn, 1);
    
    for e = 1:N_e
        count = count + 1;
        c = verts(conn(e, :), :);           % [npe x 3]
        pos_all(count, :) = mean(c, 1);     % 质心
        dV_all(count) = elem_volume(c, npe);
    end
end

%% 4. 过滤无效单元（零体积，通常为退化单元）
valid = dV_all > eps;
if ~all(valid)
    fprintf('  过滤 %d 个零体积单元\n', sum(~valid));
end
voxel.pos = pos_all(valid, :);
voxel.dV  = dV_all(valid);
N_v = size(voxel.pos, 1);

%% 5. 标记内部单元（球体内部：r < R_scatter）
R2 = sum(voxel.pos.^2, 2);
voxel.mask_interior = R2 < R_scatter^2;

%% 6. 初始化 epsilon_r
voxel.epsilon_r = ones(N_v, 1);
if isfield(p, 'cavity_eps_r_true')
    voxel.epsilon_r(voxel.mask_interior) = p.cavity_eps_r_true;
else
    voxel.epsilon_r(voxel.mask_interior) = 5.0;
end

%% 7. 为内部tet单元预计算Gauss积分点坐标
% 仅对tet单元（4节点四面体）使用4-pt Gauss规则
% 非tet内部单元在compute_gradient中回退到质心近似
voxel.gauss_w = 0.25 * ones(4, 1);  % 4-pt rule weights
voxel.gauss_pos = [];  % [4*N_inner_tet x 3], 仅内部tet

if mesh.getNumElem('tet') > 0
    tet_conn = double(mesh.getElem('tet'))' + 1;  % [N_tet x 4], 1-indexed
    % 确定哪些tet是内部单元（基于质心位置，与mask_interior一致）
    is_tet = false(N_total, 1);
    tet_start = 1;  % tet 总是第一批（先于prism）
    is_tet(tet_start:tet_start+size(tet_conn,1)-1) = true;
    inner_tet = voxel.mask_interior & is_tet;
    N_inner_tet = sum(inner_tet);
    
    if N_inner_tet > 0
        % 4-pt Gauss: barycentric coords = permutations of (a,b,b,b)
        a = (5 + 3*sqrt(5)) / 20;
        b = (5 - sqrt(5)) / 20;
        gauss_bary = [a b b b; b a b b; b b a b; b b b a];
        
        inner_tet_idx = find(inner_tet);
        gauss_pos_all = zeros(4 * N_inner_tet, 3);
        for gi = 1:N_inner_tet
            elem_idx = inner_tet_idx(gi);
            tv = verts(tet_conn(elem_idx, :), :);  % [4 x 3]
            gr = (4*(gi-1)+1):(4*gi);
            for gp = 1:4
                gauss_pos_all(gr(gp), :) = gauss_bary(gp, :) * tv;
            end
        end
        voxel.gauss_pos = gauss_pos_all;
        fprintf('  Gauss: %d 内部tet, %d Gauss积分点\n', N_inner_tet, 4*N_inner_tet);
    end
end

if isempty(voxel.gauss_pos)
    fprintf('  [WARN] 无内部tet，Gauss积分不可用，将回退到质心近似\n');
end

fprintf('[fem_mesh_utils] 完成: %d 单元, %d 内部 (%.1f%%), dV range [%.2e, %.2e]\n', ...
    N_v, sum(voxel.mask_interior), 100*sum(voxel.mask_interior)/N_v, ...
    min(voxel.dV), max(voxel.dV));

end

%% ========== 局部函数：单元体积计算 ==========

function V = elem_volume(coords, npe)
% 根据单元节点数选择体积算法
    switch npe
        case 4  % 四面体
            V = tet_vol(coords);
        case 6  % 三棱柱
            V = prism_vol(coords);
        case 8  % 六面体
            V = hex_vol(coords);
        case 5  % 金字塔
            V = pyramid_vol(coords);
        otherwise
            V = 0;  % 未知类型或非3D单元
    end
end

function V = tet_vol(c)
% 四面体体积: |det(v2-v1, v3-v1, v4-v1)| / 6
    v1 = c(2,:) - c(1,:);
    v2 = c(3,:) - c(1,:);
    v3 = c(4,:) - c(1,:);
    V = abs(det([v1; v2; v3])) / 6;
end

function V = prism_vol(c)
% 三棱柱 → 3 四面体分解（体对角线 1-6）
% COMSOL 节点序: 底面 1,2,3 CCW; 顶面 4,5,6 CCW (4在1上方,5在2上方,6在3上方)
    V = tet_vol(c([1,2,3,6], :)) ...
      + tet_vol(c([1,2,6,5], :)) ...
      + tet_vol(c([1,5,6,4], :));
end

function V = hex_vol(c)
% 六面体 → 5 四面体分解（标准中心剖分）
% COMSOL 节点序: 底面 1-4 CCW, 顶面 5-8 CCW
    V = tet_vol(c([1,2,3,6], :)) ...
      + tet_vol(c([1,3,8,6], :)) ...
      + tet_vol(c([1,3,4,8], :)) ...
      + tet_vol(c([1,6,8,5], :)) ...
      + tet_vol(c([3,6,7,8], :));
end

function V = pyramid_vol(c)
% 金字塔 → 2 四面体分解
% 底面 1-4 CCW, 顶点 5
    V = tet_vol(c([1,2,3,5], :)) ...
      + tet_vol(c([1,3,4,5], :));
end
