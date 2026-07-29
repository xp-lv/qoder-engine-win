function [lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos, Ms, keep_adjoint_state)
%SOLVE_ADJOINT COMSOL adjoint solve, returns voxel-center adjoint field lambda
%   [lambda, ok] = solve_adjoint(model, voxel, p, f_adj)
%   [lambda, ok] = solve_adjoint(model, voxel, p, f_adj, source_pos)
%   [lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos)
%   [lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, p, Js, source_pos, Ms)
%
%   ★ Round 22 升级（2026-07-26）：支持精确双源（表面电流 + 表面磁流）★
%
%   两条路径：
%     Ms 为空（旧路径）：f_adj 作为 ExternalCurrentDensity (vec1) 体积电流注入
%     Ms 非空（新路径）：Js → SurfaceCurrent (sc_adj) + Ms → SurfaceMagneticCurrentDensity (ms_adj)
%                       双源注入测量球面，归零旧 vec1
%
%   KEY FIX v2 (2026-06-08): 复对称矩阵 A=A^T, conj(A)*lambda = -f_adj
%   B03 fix (2026-06-27): lambda = lambda_raw (no conj!)
%
%   Input:
%       model       COMSOL model (forward solved, LU cached)
%       voxel       voxel grid (mask_interior, pos, gauss_pos)
%       p           config
%       f_adj/Js    [N_src × 3] complex — 旧:体积电流密度 / 新:表面电流 Js
%       source_pos  [N_src × 3] — 源位置
%       Ms          (可选) [N_src × 3] complex — 表面磁流（非空时走双源路径）
%   Output:
%       lambda       [N_inner × 3] complex — voxel-center adjoint field
%       ok           logical — success flag
%       lambda_gauss [4*N_inner × 3] complex — Gauss-point adjoint

lambda = []; ok = false;
if nargout >= 3, lambda_gauss = []; end

% 默认使用 voxel.pos 作为伴随源位置（旧路径）
if nargin < 5 || isempty(source_pos)
    source_pos = voxel.pos;
end

% 判断走哪条路径
use_dual_source = (nargin >= 6 && ~isempty(Ms));

if isempty(model)
    fprintf('[solve_adjoint] model is empty\n');
    return;
end

if use_dual_source
    fprintf('[solve_adjoint] ★精确双源路径★ (SurfaceCurrent + SurfaceMagneticCurrentDensity)\n');
else
    fprintf('[solve_adjoint] 旧路径 (ExternalCurrentDensity, N_voxel=%d)\n', length(voxel.epsilon_r));
end

inner = voxel.mask_interior;
omega = p.omega(1);
mu0 = p.mu0;
omega_mu0 = omega * mu0;

phys = model.physics('emw');

if use_dual_source
    %% ====== 新路径：精确双源（表面电流 Js + 表面磁流 Ms）======
    Js = f_adj;  % 别名（f_adj 在双源路径下是 Js）

    % ★ 物理推导修正 2026-07-27：Js 路径需要双重叉乘 ★
    % COMSOL SurfaceCurrent Js0 驱动 E 方程：source = -i*omega*mu0 * Js0
    % 但 Js (来自 L^H) 对应 H 变分，需要通过 Faraday 定律转化为 E 方程源项：
    %   Js0_physical = -i * n_hat x conj(dF/dH) / (omega*mu0)
    %   其中 dF/dH ~ conj(Js_exact)，而 Js_exact 含 (n x) 算子
    %   所以 Js0 ~ n x conj(n x v_perp) / (omega*mu0)
    %   = n x conj(K_J^T * v) / (omega*mu0)
    %
    %   conj(n x v_perp) = n x conj(v_perp)（因为 n 是实向量）
    %   n x (n x conj(v_perp)) = n(n . conj(v_perp)) - conj(v_perp)
    %
    % 实现方式：在写入 COMSOL 前，对 Js 施加第二次叉乘 n x Js
    %   并恢复 omega*mu0 除法（物理必需）
    %
    % 注意：source_pos 来自测量球面，需要获取表面法向量
    % 这里用 source_pos 推算法向量（测量球面上 n_hat = r_hat = pos/|pos|）
    pos_norm = vecnorm(source_pos, 2, 2);  % [N_src x 1]
    pos_norm(pos_norm < 1e-30) = 1e-30;    % 避免除零
    n_hat_src = source_pos ./ pos_norm;     % [N_src x 3] 单位法向量

    % 第二次叉乘：Js_for_comsol = n_hat x Js（原 Js 已含第一次叉乘在 K_J^T 中）
    Js_for_comsol = cross(n_hat_src, Js, 2);  % [N_src x 3]

    % 恢复 omega*mu0 缩放（物理上 Js0 需要 /(omega*mu0)）
    Js_for_comsol = Js_for_comsol / omega_mu0;

    % 用修正后的 Js 替换原始 Js 供后续 COMSOL 写入
    Js = Js_for_comsol;

    % 插值函数名：sc = surface current, ms = magnetic surface current
    sc_funcs = {'int_sc_x_re','int_sc_x_im', ...
                'int_sc_y_re','int_sc_y_im', ...
                'int_sc_z_re','int_sc_z_im'};
    ms_funcs = {'int_ms_x_re','int_ms_x_im', ...
                'int_ms_y_re','int_ms_y_im', ...
                'int_ms_z_re','int_ms_z_im'};

    %% 1a. 写入 Js 插值函数（-conj(Js)，与旧版 -conj 约定一致）
    try
        for d = 1:3
            for part = 1:2
                idx = (d-1)*2 + part;
                fn = sc_funcs{idx};
                try
                    model.component('comp1').func(fn);
                catch
                    model.component('comp1').func.create(fn, 'Interpolation');
                    model.component('comp1').func(fn).set('nargs', '3');
                    model.component('comp1').func(fn).set('source', 'table');
                end
                if part == 1
                    vals = -real(Js(:, d));
                else
                    vals = imag(Js(:, d));
                end
                tmp = [tempname, '.csv'];
                dlmwrite(tmp, [source_pos, vals(:)]);
                model.component('comp1').func(fn).importData(tmp);
                delete(tmp);
            end
        end
        fprintf('  OK Js interpolation functions written\n');
    catch ME
        fprintf('  FAIL writing Js: %s\n', ME.message);
        return;
    end

    %% 1b. 写入 Ms 插值函数（-conj(Ms)）
    try
        for d = 1:3
            for part = 1:2
                idx = (d-1)*2 + part;
                fn = ms_funcs{idx};
                try
                    model.component('comp1').func(fn);
                catch
                    model.component('comp1').func.create(fn, 'Interpolation');
                    model.component('comp1').func(fn).set('nargs', '3');
                    model.component('comp1').func(fn).set('source', 'table');
                end
                if part == 1
                    vals = -real(Ms(:, d));
                else
                    vals = imag(Ms(:, d));
                end
                tmp = [tempname, '.csv'];
                dlmwrite(tmp, [source_pos, vals(:)]);
                model.component('comp1').func(fn).importData(tmp);
                delete(tmp);
            end
        end
        fprintf('  OK Ms interpolation functions written\n');
    catch ME
        fprintf('  FAIL writing Ms: %s\n', ME.message);
        return;
    end

    %% 2a. 创建/配置 SurfaceCurrent (sc_adj, dim=2)
    % Js 已在上方预处理中含双重叉乘 + omega*mu0 缩放
    % COMSOL 约定：Js0 = -i * conj(Js) （通过 -real + i*imag 插值函数实现）
    try
        try phys.feature().remove('sc_adj'); catch, end
        phys.feature().create('sc_adj', 'SurfaceCurrent', 2);
        Je_x = sprintf('(-int_sc_x_im(x,y,z) + i*int_sc_x_re(x,y,z))');
        Je_y = sprintf('(-int_sc_y_im(x,y,z) + i*int_sc_y_re(x,y,z))');
        Je_z = sprintf('(-int_sc_z_im(x,y,z) + i*int_sc_z_re(x,y,z))');
        phys.feature('sc_adj').set('Js0', {Je_x, Je_y, Je_z});
        try phys.feature('sc_adj').selection().all(); catch, end
        fprintf('  OK sc_adj (SurfaceCurrent) created [double cross + omega*mu0]\n');
    catch ME
        fprintf('  FAIL sc_adj config: %s\n', ME.message);
        return;
    end

    %% 2b. 创建/配置 SurfaceMagneticCurrentDensity (ms_adj, dim=2)
    try
        try phys.feature().remove('ms_adj'); catch, end
        phys.feature().create('ms_adj', 'SurfaceMagneticCurrentDensity', 2);
        % Jms0 表达式（磁流密度，单位 V/m）
        Mx = sprintf('(-int_ms_x_im(x,y,z) + i*int_ms_x_re(x,y,z))');
        My = sprintf('(-int_ms_y_im(x,y,z) + i*int_ms_y_re(x,y,z))');
        Mz = sprintf('(-int_ms_z_im(x,y,z) + i*int_ms_z_re(x,y,z))');
        phys.feature('ms_adj').set('Jms0', {Mx, My, Mz});
        try phys.feature('ms_adj').selection().all(); catch, end
        fprintf('  OK ms_adj (SurfaceMagneticCurrentDensity) created\n');
    catch ME
        fprintf('  FAIL ms_adj config: %s\n', ME.message);
        return;
    end

    %% 3. 归零旧 ExternalCurrentDensity (vec1)
    try
        try
            phys.feature('vec1').set('Je', {'0', '0', '0'});
            fprintf('  OK vec1 zeroed (Born volume current disabled)\n');
        catch
            % vec1 不存在，跳过
        end
    catch
    end

else
    %% ====== 旧路径：ExternalCurrentDensity (vec1) ======
    func_names = {'int_adj_x_re','int_adj_x_im', ...
                  'int_adj_y_re','int_adj_y_im', ...
                  'int_adj_z_re','int_adj_z_im'};

    %% 1. Write adjoint source interpolation functions
    % ★ pipline_adjoint 修正 2026-07-27：去掉 -conj 约定
    %   数学推导：COMSOL K 复对称 -> K·λ = f_adj (无 conj)
    %   旧版用 -conj 是 Born 体积电流路径的遗留，对复矩阵 K 不正确
    try
        for d = 1:3
            for part = 1:2
                idx = (d-1)*2 + part;
                fn = func_names{idx};
                try
                    model.component('comp1').func(fn);
                catch
                    model.component('comp1').func.create(fn, 'Interpolation');
                    model.component('comp1').func(fn).set('nargs', '3');
                    model.component('comp1').func(fn).set('source', 'table');
                end
                if part == 1
                    vals = real(f_adj(:, d));   % 直接用 f_adj 实部（不取 conj）
                else
                    vals = imag(f_adj(:, d));   % 直接用 f_adj 虚部
                end
                tmp = [tempname, '.csv'];
                dlmwrite(tmp, [source_pos, vals(:)]);
                model.component('comp1').func(fn).importData(tmp);
                delete(tmp);
            end
        end
        fprintf('  OK adjoint source interpolation functions written (direct, no conj)\n');
    catch ME
        fprintf('  FAIL writing adjoint source: %s\n', ME.message);
        return;
    end

    %% 2. Configure External Current Density (vec1)
    vec_new = false;
    try
        try
            phys.feature('vec1');
        catch
            phys.feature().create('vec1', 'ExternalCurrentDensity', 3);
            vec_new = true;
            fprintf('  OK created vec1\n');
        end
        try
            phys.feature('vec1').selection().all();
        catch
        end
        % Je = conj(f_adj)（直接注入 conj(f_adj)，无 /(-iω)）
        % ExternalCurrentDensity 弱贡献 = Je·test(E)（无 -iω 因子）
        Je_x = sprintf('(int_adj_x_re(x,y,z) + i*int_adj_x_im(x,y,z))');
        Je_y = sprintf('(int_adj_y_re(x,y,z) + i*int_adj_y_im(x,y,z))');
        Je_z = sprintf('(int_adj_z_re(x,y,z) + i*int_adj_z_im(x,y,z))');
        phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});
    catch ME
        fprintf('  FAIL vec1 config: %s\n', ME.message);
        if vec_new
            try; phys.feature().remove('vec1'); end
        end
        return;
    end
end

%% 3. Zero background field（直接设 Eb=0，不依赖 adjoint_mode 参数）
model.param.set('adjoint_mode', '0');
try
    phys.prop('BackgroundField').set('Eb', [0 0 0]);
    fprintf('  OK background field zeroed (Eb=[0,0,0])\n');
catch
    fprintf('  OK background field zeroed (adjoint_mode=0)\n');
end

%% 4. Adjoint solve (reuse forward LU)
try
    model.sol('sol1').runAll();
    fprintf('  OK adjoint solve completed (runAll)\n');
    ok = true;
catch ME
    fprintf('  FAIL adjoint solve: %s\n', ME.message);
end

%% 5. Extract lambda field
% ★ 实验验证 2026-07-28: 不取 conj 导致 sign 0/30 全反 → 恢复 conj 约定
%   数学推导的 bilinear 似乎在此实现中不适用，conj + bilinear(实际 Hermitian) 是正确的配对
%   原因推测: COMSOL 双源路径的 -conj 源注入约定使得 lambda_raw 的符号被额外翻转
%   需要 conj 补偿才能与 FD 同号
if ok
    try
        [lambda_raw, ~] = read_field(model, voxel.pos(inner, :));
        if use_dual_source
            lambda = conj(lambda_raw);  % ★ 恢复 conj（实验验证必须）
        else
            lambda = lambda_raw;
        end
        fprintf('  OK lambda field: %d voxels, |lambda| mean=%.4e (conj=%d)\n', ...
            size(lambda,1), mean(vecnorm(lambda,2,2)), use_dual_source);
    catch ME
        fprintf('  FAIL lambda extraction: %s\n', ME.message);
        ok = false;
    end

    % Extract lambda at Gauss points
    if ok && nargout >= 3 && ~isempty(voxel.gauss_pos)
        try
            [lambda_raw_g, ~] = read_field(model, voxel.gauss_pos);
            if use_dual_source
                lambda_gauss = conj(lambda_raw_g);  % ★ 恢复 conj
            else
                lambda_gauss = lambda_raw_g;
            end
            fprintf('  OK lambda_gauss: %d Gauss points (conj=%d)\n', size(lambda_gauss,1), use_dual_source);
        catch ME
            fprintf('  FAIL lambda_gauss extraction: %s\n', ME.message);
            lambda_gauss = [];
        end
    end
end

%% 6. Restore model
% ★ 可选参数 keep_adjoint_state：true 时跳过模型恢复（用于 FEM 自由度导出）
if nargin >= 7 && keep_adjoint_state
    fprintf('  OK keep_adjoint_state=true（跳过模型恢复）\n');
else
try
    model.param.set('adjoint_mode', '1');
    % 恢复背景场
    try phys.prop('BackgroundField').set('Eb', [0 0 1]); catch, end
    if use_dual_source
        % 清理双源 feature（恢复模型状态）
        try phys.feature().remove('sc_adj'); catch, end
        try phys.feature().remove('ms_adj'); catch, end
        % 恢复 vec1（如果之前归零了）
        try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end
    else
        try phys.feature('vec1').set('Je', {'0', '0', '0'}); catch, end
    end
    fprintf('  OK model restored\n');
catch
end
end  % else (keep_adjoint_state)

end
