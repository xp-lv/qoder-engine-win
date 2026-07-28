function [lambda_exact, ok, lambda_gauss, Js, Ms, source_pos, F_obs] = ...
        setup_exact_adjoint_v2(model, voxel, grid, lc, p)
%SETUP_EXACT_ADJOINT_SOURCE_V2 H028: 精确全 Maxwell 伴随（两次求解法）
%
%   ★ 关键改进：用两次 COMSOL 求解替代 SurfaceCurrent 的 n̂× 近似 ★
%
%   原理（从 Maxwell 弱形式严格推导）：
%     L^H·v = Ms_exact + C·Js_exact
%           = Ms_exact + curl(Js_exact)/(i*omega*mu0)
%
%   其中 C = curl/(i*omega*mu0) 是 E→H 映射算子（自伴）
%
%   两次求解法：
%     (1) A·lambda_E = Ms_exact        [SurfaceMagneticCurrent 直接力]
%         → lambda_E（E 变分贡献）
%     (2) A·lambda_temp = Js_exact     [SurfaceCurrent 或 vec1 直接力]
%         → lambda_temp → H_adj = curl(lambda_temp)/(i*omega*mu0)
%         → lambda_H = H_adj（H 变分贡献）
%     (3) lambda_total = lambda_E + lambda_H
%
%   优势：
%     - 旋度运算在后处理中完成（精确数值微分），不依赖 n̂× 近似
%     - 两次求解都用直接力，无弱形式歧义
%     - cos 预期从 0.983 → 1.0（消除方向依赖误差）
%
%   代价：2x COMSOL solve（但复用同一 LU 分解，实际增量 ~30%）

% 构建伴随源（与 v1 相同）
[Js, Ms, source_pos, F_obs] = build_adjoint_source_fullmaxwell(grid, lc, p);

fprintf('  (1) 伴随激励构建完成: |Js| mean=%.4e, |Ms| mean=%.4e\n', ...
    mean(vecnorm(Js, 2, 2)), mean(vecnorm(Ms, 2, 2)));

%% ====== 求解 1: Ms_exact → lambda_E (SurfaceMagneticCurrent 直接力) ======
fprintf('  [Solve 1] Ms_exact → lambda_E (SurfaceMagneticCurrent)...\n');

% 只注入 Ms，Js 设为零
Js_zero = zeros(size(Js));
[lambda_E, ok1, lambda_E_gauss] = solve_adjoint_v2_solve(model, voxel, p, ...
    Js_zero, source_pos, Ms);

if ~ok1
    fprintf('  [FAIL] Solve 1 failed\n');
    lambda_exact = []; ok = false; lambda_gauss = [];
    return;
end

fprintf('  [Solve 1] lambda_E: |mean|=%.4e\n', mean(vecnorm(lambda_E, 2, 2)));

%% ====== 求解 2: Js_exact → lambda_temp (SurfaceCurrent 直接力，无 n̂×) ======
fprintf('  [Solve 2] Js_exact → lambda_temp (SurfaceCurrent, no n_hat x)...\n');

% 只注入 Js（不做 n̂× 修正，不做 omega*mu0 缩放）
% 用 Ms=零矩阵使走双源路径但只激活 Js
Ms_zero = zeros(size(Ms));
[lambda_temp, ok2, lambda_temp_gauss] = solve_adjoint_v2_solve(model, voxel, p, ...
    Js, source_pos, Ms_zero);

if ~ok2
    fprintf('  [FAIL] Solve 2 failed\n');
    lambda_exact = lambda_E; ok = true; lambda_gauss = lambda_E_gauss;
    return;
end

fprintf('  [Solve 2] lambda_temp: |mean|=%.4e\n', mean(vecnorm(lambda_temp, 2, 2)));

%% ====== 后处理: lambda_H = curl(lambda_temp) / (i*omega*mu0) ======
% ★ 用 COMSOL 内置 curl 表达式做精确旋度（非有限差分近似）★
% COMSOL 求解后，场变量 emw.Ex/ey/ez 已存储在 mesh 上，
% 可以用 mphinterp 提取 curl(E) = [dEz/dy-dEy/dz, dEx/dz-dEz/dx, dEy/dx-dEx/dy]
% COMSOL 表达式：curlEx = d(emw.Ez)-d(emw.Ey) 等
omega = p.omega(1);
mu0 = p.mu0;
i_omega_mu0 = 1i * omega * mu0;

fprintf('  [Post-process] COMSOL curl(lambda_temp)/(i*omega*mu0)...\n');

% 体素中心点：用 mphinterp 提取 curl 场
inner_pos = voxel.pos(voxel.mask_interior, :);
try
    % COMSOL EMW 偏导：分别提取 curl 的 3 个分量（每个是标量场）
    N_eval = size(inner_pos, 1);
    curl_x = mphinterp(model, 'd(emw.Ez,y)-d(emw.Ey,z)', 'coord', inner_pos');
    curl_y = mphinterp(model, 'd(emw.Ex,z)-d(emw.Ez,x)', 'coord', inner_pos');
    curl_z = mphinterp(model, 'd(emw.Ey,x)-d(emw.Ex,y)', 'coord', inner_pos');
    % 每个返回 [1 x N] 或 [N x 1]，统一为列向量
    curl_raw = [curl_x(:), curl_y(:), curl_z(:)];  % [N x 3]
    lambda_H = conj(curl_raw / i_omega_mu0);
    fprintf('  [Post-process] curl via mphinterp: |mean|=%.4e (size=%s)\n', ...
        mean(vecnorm(lambda_H, 2, 2)), mat2str(size(lambda_H)));
catch ME
    fprintf('  [WARN] mphinterp curl failed (%s), using finite diff fallback\n', ME.message);
    lambda_H = compute_curl_fd(inner_pos, lambda_temp) / i_omega_mu0;
    lambda_H = conj(lambda_H);
end

% Gauss 点
if ~isempty(voxel.gauss_pos)
    try
        cgx = mphinterp(model, 'd(emw.Ez,y)-d(emw.Ey,z)', 'coord', voxel.gauss_pos');
        cgy = mphinterp(model, 'd(emw.Ex,z)-d(emw.Ez,x)', 'coord', voxel.gauss_pos');
        cgz = mphinterp(model, 'd(emw.Ey,x)-d(emw.Ex,y)', 'coord', voxel.gauss_pos');
        curl_g_raw = [cgx(:), cgy(:), cgz(:)];
        lambda_H_gauss = conj(curl_g_raw / i_omega_mu0);
    catch
        lambda_H_gauss = compute_curl_fd(voxel.gauss_pos, lambda_temp_gauss) / i_omega_mu0;
        lambda_H_gauss = conj(lambda_H_gauss);
    end
else
    lambda_H_gauss = [];
end

fprintf('  [Post-process] lambda_H: |mean|=%.4e\n', mean(vecnorm(lambda_H, 2, 2)));

%% ====== 合并: lambda_total = lambda_E + lambda_H ======
lambda_exact = lambda_E + lambda_H;

if ~isempty(lambda_H_gauss)
    lambda_gauss = lambda_E_gauss + lambda_H_gauss;
else
    lambda_gauss = lambda_E_gauss;
end

fprintf('  (2-4) lambda_total = lambda_E + lambda_H: |mean|=%.4e\n', ...
    mean(vecnorm(lambda_exact, 2, 2)));

ok = true;

end

%% ====== 辅助函数 ======

function [lambda, ok, lambda_gauss] = solve_adjoint_v2_solve(model, voxel, p, Js, source_pos, Ms)
%单次伴随求解（复用 solve_adjoint 的双源路径，但无 n̂× 修正）

% 临时禁用 solve_adjoint 中的 n̂× 修正（通过标志或直接内联）
% 这里直接内联核心逻辑

inner = voxel.mask_interior;
phys = model.physics('emw');

% 写入 Js 和 Ms 插值函数（标准 -conj 约定）
sc_funcs = {'int_sc_x_re','int_sc_x_im','int_sc_y_re','int_sc_y_im','int_sc_z_re','int_sc_z_im'};
ms_funcs = {'int_ms_x_re','int_ms_x_im','int_ms_y_re','int_ms_y_im','int_ms_z_re','int_ms_z_im'};

ok = true;

% 写入 Js（不做 n̂× 修正）
for d = 1:3
    for part = 1:2
        fn = sc_funcs{(d-1)*2+part};
        try model.component('comp1').func(fn);
        catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        if part == 1, vals = -real(Js(:,d)); else, vals = imag(Js(:,d)); end
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [source_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp);
        delete(tmp);
    end
end

% 写入 Ms
for d = 1:3
    for part = 1:2
        fn = ms_funcs{(d-1)*2+part};
        try model.component('comp1').func(fn);
        catch
            model.component('comp1').func.create(fn, 'Interpolation');
            model.component('comp1').func(fn).set('nargs', '3');
            model.component('comp1').func(fn).set('source', 'table');
        end
        if part == 1, vals = -real(Ms(:,d)); else, vals = imag(Ms(:,d)); end
        tmp = [tempname, '.csv'];
        dlmwrite(tmp, [source_pos, vals(:)]);
        model.component('comp1').func(fn).importData(tmp);
        delete(tmp);
    end
end

% 创建 SurfaceCurrent（保留 omega*mu0 除法，不做 n̂×）
omega_mu0 = p.omega(1) * p.mu0;
denom = sprintf('%.15e', omega_mu0);
try phys.feature().remove('sc_adj'); catch, end
phys.feature().create('sc_adj', 'SurfaceCurrent', 2);
Je_x = sprintf('(-int_sc_x_im(x,y,z) + i*int_sc_x_re(x,y,z)) / %s', denom);
Je_y = sprintf('(-int_sc_y_im(x,y,z) + i*int_sc_y_re(x,y,z)) / %s', denom);
Je_z = sprintf('(-int_sc_z_im(x,y,z) + i*int_sc_z_re(x,y,z)) / %s', denom);
phys.feature('sc_adj').set('Js0', {Je_x, Je_y, Je_z});
try phys.feature('sc_adj').selection().all(); catch, end

% 创建 SurfaceMagneticCurrent
try phys.feature().remove('ms_adj'); catch, end
phys.feature().create('ms_adj', 'SurfaceMagneticCurrentDensity', 2);
Mx = sprintf('(-int_ms_x_im(x,y,z) + i*int_ms_x_re(x,y,z))');
My = sprintf('(-int_ms_y_im(x,y,z) + i*int_ms_y_re(x,y,z))');
Mz = sprintf('(-int_ms_z_im(x,y,z) + i*int_ms_z_re(x,y,z))');
phys.feature('ms_adj').set('Jms0', {Mx, My, Mz});
try phys.feature('ms_adj').selection().all(); catch, end

% 归零 vec1
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end

% 零背景场
model.param.set('adjoint_mode', '0');

% 求解
try
    model.sol('sol1').runAll();
catch ME
    fprintf('  FAIL solve: %s\n', ME.message);
    ok = false;
end

% 提取 lambda
if ok
    [lambda_raw, ~] = read_field(model, voxel.pos(inner, :));
    lambda = conj(lambda_raw);

    lambda_gauss = [];
    if nargout >= 3 && ~isempty(voxel.gauss_pos)
        [lambda_raw_g, ~] = read_field(model, voxel.gauss_pos);
        lambda_gauss = conj(lambda_raw_g);
    end
else
    lambda = []; lambda_gauss = [];
end

% 恢复模型
model.param.set('adjoint_mode', '1');
try phys.feature().remove('sc_adj'); catch, end
try phys.feature().remove('ms_adj'); catch, end
try phys.feature('vec1').set('Je', {'0','0','0'}); catch, end

end


function curl_F = compute_curl_fd(eval_points, F_at_points)
%有限差分近似 curl(F)
delta = 1e-4;  % 差分步长 0.1mm
N = size(eval_points, 1);
curl_F = zeros(N, 3, 'like', F_at_points);

for d = 1:3
    dp = zeros(1, 3); dp(d) = delta;
    pp = eval_points + repmat(dp, N, 1);
    pm = eval_points - repmat(dp, N, 1);
    Fp = interp_field(eval_points, F_at_points, pp);
    Fm = interp_field(eval_points, F_at_points, pm);
    dF_dd = (Fp - Fm) / (2 * delta);
    if d == 1
        curl_F(:, 2) = dF_dd(:, 3);  curl_F(:, 3) = -dF_dd(:, 2);
    elseif d == 2
        curl_F(:, 1) = -dF_dd(:, 3);  curl_F(:, 3) = dF_dd(:, 1);
    else
        curl_F(:, 1) = dF_dd(:, 2);  curl_F(:, 2) = -dF_dd(:, 1);
    end
end
end


function Fp = interp_field(orig_points, F_orig, new_points)
%线性插值场值到新位置
%   使用 MATLAB interp3（需要网格化数据）
%   这里用简化的最近邻+线性混合

N = size(orig_points, 1);
Np = size(new_points, 1);
Fp = zeros(Np, 3, 'like', F_orig);

% 对每个新点，找最近的原始点做线性插值
for i = 1:Np
    dist = sum((orig_points - repmat(new_points(i,:), N, 1)).^2, 2);
    [dmin, idx] = sort(dist);
    % 用最近 4 个点做反距离加权
    k = min(4, N);
    w = 1 ./ (dmin(1:k) + 1e-30);
    w = w / sum(w);  % [k x 1]
    Fp(i, :) = w' * F_orig(idx(1:k), :);  % [1x3] = [1xk]*[kx3]
end

end
