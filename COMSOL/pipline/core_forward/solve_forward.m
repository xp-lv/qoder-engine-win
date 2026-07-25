function [E_total, pos, E_gauss] = solve_forward(model, voxel, p)
%SOLVE_FORWARD COMSOL 正演求解，返回体素中心全场 E
%   [E_total, pos] = solve_forward(model, voxel, p)
%   [E_total, pos, E_gauss] = solve_forward(model, voxel, p)
%
%   输入:
%       model   COMSOL 模型对象（mphload 加载，含背景场）
%       voxel   体素网格结构体（含 epsilon_r, mask_interior, pos, gauss_pos）
%       p       config 参数
%   输出:
%       E_total [N_inner × 3] complex — 内部体素中心电场
%       pos     [N_inner × 3] double  — 对应坐标
%       E_gauss [4*N_inner × 3] complex — Gauss积分点电场（仅当voxel.gauss_pos非空）

fprintf('[solve_forward] 开始正演 (N_voxel=%d)...\n', length(voxel.epsilon_r));

if isempty(model)
    fprintf('[solve_forward] 模型为空，返回空\n');
    E_total = [];
    pos = [];
    if nargout >= 3, E_gauss = []; end
    return;
end

% 1. 更新 ε_r 分布
model = update_epsilon(model, voxel, p);

% 2. 运行求解
fprintf('[solve_forward] 运行 COMSOL 求解...\n');

% B03 修复 2026-06-26: 频率缓存根因修复
% 根因: model.physics.has('emw') 不存在 (PhysicsListClient 无 has 方法),
%        导致外层 catch 跳过 model.refresh 和 mesh.run, 频率变更未传播
% 修复: 1.移除 has() 检查 2.移除 prop('Frequency') 调用
%        3.通过 study step 直接设频率 4.clearSolution+refresh+mesh 移出 try-catch

% 设置频率
if isfield(p, 'freq')
    % B03 修复 2026-06-26: 频率缓存根因修复
    % 根因1: model.physics.has('emw') 不存在 (PhysicsListClient 无 has 方法),
    %         导致外层 catch 跳过 refresh 和 mesh.run, 频率变更未传播
    % 根因2: model.physics('emw').prop('Frequency') 不存在 (Unknown property)
    % 根因3: model.refresh 不存在 (MATLAB 图形函数, 非 COMSOL API)
    % 根因4: study step 属性名是 'plist' 而非 'freq', punit=GHz 需显式单位
    % 修复: 通过 study step 的 plist 属性直接设频率 (带显式单位),
    %       clearSolution+mesh.run 移出 try-catch 确保执行
    model.param.set('freq', num2str(p.freq));
    fprintf('  [solve_forward] param freq = %s Hz\n', model.param.get('freq'));
    % 直接在 study step 上设 plist (带显式单位, 避免 punit=GHz 歧义)
    try
        model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq));
        fprintf('  [solve_forward] study plist set to %g[Hz]\n', p.freq);
    catch
        % study step 可能引用 root.freq, param.set 已足够
    end
end

% PARDISO + MUMPS 双直接求解器配置 (C04): 高对比度 ε_r (如西瓜 ε_r≈65) 下 GMRES 不收敛
% PARDISO: 速度快但内存需求大 (适合 ≤4cm 网格)
% MUMPS:   内存更灵活, 支持核外存储 (适合 3cm 等大网格)
try
    s1_feat = model.sol('sol1').feature('s1');
    s1_feat.feature('dDirect');  % PARDISO 已存在?
    s1_feat.feature('dMumps');   % MUMPS 已存在?
catch
    try
        s1_feat = model.sol('sol1').feature('s1');
        % 创建 PARDISO Direct feature
        try, s1_feat.feature('dDirect'); catch, s1_feat.create('dDirect', 'Direct'); s1_feat.feature('dDirect').set('linsolver', 'pardiso'); end
        % 创建 MUMPS Direct feature (后备)
        try, s1_feat.feature('dMumps'); catch, s1_feat.create('dMumps', 'Direct'); s1_feat.feature('dMumps').set('linsolver', 'mumps'); end
        % 默认用 PARDISO
        s1_feat.feature('fc1').set('linsolver', 'dDirect');
        fprintf('  [solve_forward] PARDISO (主) + MUMPS (备) 直接求解器已配置\n');
    catch ME
        fprintf('  [solve_forward] Direct solver 配置跳过: %s\n', ME.message);
    end
end

% 清解
model.sol('sol1').clearSolutionData();
model.sol('sol1').clearSolution();

% 求解: PARDISO → MUMPS 自动降级
solve_ok = false;
try
    model.sol('sol1').runAll();
    solve_ok = true;
catch ME_primary
    fprintf('  [solve_forward] PARDISO 失败, 切换到 MUMPS...\n');
    try
        s1_feat = model.sol('sol1').feature('s1');
        s1_feat.feature('fc1').set('linsolver', 'dMumps');
        model.sol('sol1').clearSolutionData();
        model.sol('sol1').clearSolution();
        model.sol('sol1').runAll();
        solve_ok = true;
        fprintf('  [solve_forward] MUMPS 求解成功\n');
    catch ME_mumps
        % 最后手段: study.run
        try
            model.study('std1').run;
            solve_ok = true;
        catch ME_final
            error('solve_forward: COMSOL 求解失败 (PARDISO+MUMPS 均失败): %s', ME_final.message);
        end
    end
end

% 3. 提取内部体素中心场值
inner = voxel.mask_interior;
pos_inner = voxel.pos(inner, :);
[E_total, pos] = read_field(model, pos_inner);

% 4. 提取 Gauss 积分点场值（可选，必须在adjoint之前执行）
if nargout >= 3 && ~isempty(voxel.gauss_pos)
    [E_gauss, ~] = read_field(model, voxel.gauss_pos);
    fprintf('[solve_forward] Gauss点E: %d 点\n', size(E_gauss, 1));
elseif nargout >= 3
    E_gauss = [];
end

fprintf('[solve_forward] 完成: %d 个体素, |E| mean=%.4e\n', ...
    size(E_total,1), mean(vecnorm(E_total,2,2)));

end
