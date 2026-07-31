function diag_boundary_voxel3_field()
%DIAG_BOUNDARY_VOXEL3_FIELD 对比第3体素质心与相邻FEM节点的场值差异
%   验证: 边界附近的 mphinterp 插值精度是否退化

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  边界体素场值精度诊断: 第3体素(r=0.048) vs 第2体素(r=0.036)\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
grid_meas = build_measurement_grid(p);
try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[DIAG] [FAIL] mphstart\n'); return; end
end
try; tags=ModelUtil.tags(); for ti=1:length(tags), ModelUtil.remove(char(tags(ti))); end; catch; end

model = mphload(p.comsol_model_path);
try model.geom('geom1').run; catch; end
try model.mesh('mesh1').run; catch; end
phys = model.physics('emw');
try phys.feature('vec1'); catch
    phys.feature().create('vec1','ExternalCurrentDensity',3);
    phys.feature('vec1').set('Je',{'0','0','0'});
    try phys.feature('vec1').selection().all(); catch; end
end
try model.param.set('adjoint_mode','1'); catch; end

voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior; inner_idx = find(inner); N_inner = sum(inner);

%% 2. 正演 eps_r=3-1j
for vi=1:N_inner
    xx = voxel.pos(inner_idx(vi),1);
    voxel.epsilon_r(inner_idx(vi)) = (3.0 + 1.5*xx/p.R_inner) - 1.0i;
end
update_epsilon(model, voxel, p);
[E_total, ~, ~] = solve_forward(model, voxel, p);

%% 3. 定位第2和第3体素
r_inner = vecnorm(voxel.pos(inner_idx,:), 2, 2);
[~, sort_order] = sort(r_inner);
step_sz = floor(N_inner / 4);
sample_idx = sort_order(1:step_sz:N_inner);
sample_idx = sample_idx(1:min(4, length(sample_idx)));
vi2 = sample_idx(2);  % 第2体素 (r≈0.036, 内部)
vi3 = sample_idx(3);  % 第3体素 (r≈0.048, 近边界)

for target_vi = [vi2, vi3]
    v_global = inner_idx(target_vi);
    center = voxel.pos(v_global, :);
    r = norm(center);
    fprintf('===== 体素 vi=%d, r=%.4f, dV=%.4e =====\n', target_vi, r, voxel.dV(v_global));
    fprintf('  质心坐标: (%.6f, %.6f, %.6f)\n', center(1), center(2), center(3));
    fprintf('  距边界: R_inner - r = %.4f m (%.1f%% of R)\n\n', p.R_inner - r, (p.R_inner-r)/p.R_inner*100);

    %% 4. 在质心周围采样多个点的场值
    % 在质心 ± 一个小偏移范围内采样
    offsets = [0, 0, 0;            % 质心本身
               0.005, 0, 0;         % +x
              -0.005, 0, 0;         % -x
               0, 0.005, 0;         % +y
               0, -0.005, 0;        % -y
               0, 0, 0.005;         % +z
               0, 0, -0.005];       % -z
    
    fprintf('  采样点 E 场值 (mphinterp):\n');
    fprintf('    offset           Ex                       Ey                       Ez\n');
    E_samples = zeros(size(offsets,1), 3);
    for oi = 1:size(offsets,1)
        pt = (center + offsets(oi,:))';
        Ex = mphinterp(model, 'emw.Ex', 'coord', pt);
        Ey = mphinterp(model, 'emw.Ey', 'coord', pt);
        Ez = mphinterp(model, 'emw.Ez', 'coord', pt);
        E_samples(oi,:) = [Ex(1), Ey(1), Ez(1)];
        fprintf('    (%+.3f,%+.3f,%+.3f)  %+.4e%+.4ei  %+.4e%+.4ei  %+.4e%+.4ei\n', ...
            offsets(oi,1), offsets(oi,2), offsets(oi,3), ...
            real(Ex(1)), imag(Ex(1)), real(Ey(1)), imag(Ey(1)), real(Ez(1)), imag(Ez(1)));
    end
    
    % 计算场值的空间变化率（梯度）
    E_center = E_samples(1,:);
    dE = zeros(6, 3);
    for oi = 2:7
        dE(oi-1,:) = (E_samples(oi,:) - E_center) / 0.005;
    end
    fprintf('\n  场值空间变化率 |dE/dx| (各方向):\n');
    for oi = 1:6
        dir_names = {'+x', '-x', '+y', '-y', '+z', '-z'};
        fprintf('    %s: |dE|=%.4e\n', dir_names{oi}, vecnorm(dE(oi,:), 2));
    end
    
    % 计算场值在该体素范围内的变化幅度
    max_dE = max(vecnorm(dE, 2, 2));
    E_mag = vecnorm(E_center, 2);
    variation = max_dE * 0.005 / E_mag * 100;  % 在 ±0.005m 范围内的相对变化
    fprintf('\n  场值在 ±5mm 范围内的相对变化: %.2f%%\n', variation);
    fprintf('  (变化>10%% 表明场在体素内非均匀，质心取值可能有误差)\n\n');
end

%% 5. 额外检查: 对比 mphinterp 在质心 vs FEM 节点
fprintf('===== FEM 节点 vs 质心插值对比 =====\n');
% 获取内部 tet 的节点坐标
mesh = model.mesh('mesh1');
verts = mesh.getVertex()';
tet_conn = double(mesh.getElem('tet'))' + 1;

for target_vi = [vi2, vi3]
    v_global = inner_idx(target_vi);
    center = voxel.pos(v_global, :);
    r = norm(center);
    
    % 找最近的 tet 单元（遍历内部 tet）
    inner_tet_idx = find(voxel.mask_interior(1:size(tet_conn,1)));
    min_dist = inf; closest_tet = 0;
    for ti = 1:length(inner_tet_idx)
        tet_v = inner_tet_idx(ti);
        tc = verts(tet_conn(tet_v, :), :);
        tc_center = mean(tc, 1);
        d = norm(tc_center - center);
        if d < min_dist
            min_dist = d;
            closest_tet = tet_v;
        end
    end
    
    % 读取该 tet 的 4 个节点场值
    node_coords = verts(tet_conn(closest_tet, :), :)';
    Ex_node = mphinterp(model, 'emw.Ex', 'coord', node_coords);
    Ey_node = mphinterp(model, 'emw.Ey', 'coord', node_coords);
    Ez_node = mphinterp(model, 'emw.Ez', 'coord', node_coords);
    
    E_nodes = [Ex_node(:), Ey_node(:), Ez_node(:)];  % [4 x 3]
    E_node_avg = mean(E_nodes, 1);  % 节点平均（= 质心值 for linear）
    E_center_interp = mphinterp(model, ['emw.Ex'; 'emw.Ey'; 'emw.Ez'], 'coord', center');
    
    fprintf('\n  体素 vi=%d (r=%.4f), 最近 tet#%d (d=%.4e):\n', target_vi, r, closest_tet, min_dist);
    fprintf('    节点场值:\n');
    for ni = 1:4
        fprintf('      node[%d] (%.4f,%.4f,%.4f): |E|=%.4e\n', ...
            ni, node_coords(1,ni), node_coords(2,ni), node_coords(3,ni), vecnorm(E_nodes(ni,:), 2));
    end
    
    % 节点间场值差异
    E_node_mags = vecnorm(E_nodes, 2, 2);
    fprintf('    节点 |E| 范围: [%.4e, %.4e], 变异系数=%.2f%%\n', ...
        min(E_node_mags), max(E_node_mags), std(E_node_mags)/mean(E_node_mags)*100);
    fprintf('    质心 |E| = %.4e (节点平均=%.4e)\n', vecnorm(E_center_interp, 2), vecnorm(E_node_avg, 2));
end

fprintf('\n############################################################\n');
fprintf('#  结论\n');
fprintf('#  如果第3体素(r=0.048)的节点变异系数远大于第2体素(r=0.036)，\n');
fprintf('#  说明边界附近场梯度大，质心取值精度下降。\n');
fprintf('############################################################\n');

end
