function [lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos)
%SOLVE_ADJOINT COMSOL adjoint solve, returns voxel-center adjoint field lambda
%   [lambda, ok] = solve_adjoint(model, voxel, p, f_adj)
%   [lambda, ok] = solve_adjoint(model, voxel, p, f_adj, source_pos)
%   [lambda, ok, lambda_gauss] = solve_adjoint(model, voxel, p, f_adj, source_pos)
%
%   Automatically configures COMSOL model's adjoint source:
%     1. Write complex adjoint source f_adj via 6 interpolation functions
%     2. Create/update External Current Density (vec1)
%     3. Disable scattering background (sctr1)
%     4. Reuse forward LU factorization for solving
%     5. Restore model state
%
%   KEY FIX v2 (2026-06-08, exp63 v1 failed -> v2):
%     COMSOL FEM system matrix A is exactly complex-symmetric (A=A^T, exp61).
%     Standard Wirtinger adjoint equation: A^H*lambda = -f_adj.
%     Since A^H = conj(A), we have: conj(A)*lambda = -f_adj
%     Taking conjugate: A*conj(lambda) = -conj(f_adj)
%     So COMSOL must solve A * lambda_raw = -conj(f_adj).
%     Then lambda = conj(lambda_raw) satisfies A^H*lambda = -f_adj.
%     Fix: write -conj(f_adj) to interpolation functions,
%     then lambda = conj(lambda_raw).
%
%   Input:
%       model   COMSOL model (forward solved, LU cached)
%       voxel   voxel grid (mask_interior, pos, gauss_pos)
%       p       config
%       f_adj   [N_src x 3] complex -- adjoint source (domain current density)
%       source_pos [N_src x 3] -- positions for adjoint source (default: voxel.pos)
%   Output:
%       lambda       [N_inner x 3] complex -- voxel-center adjoint field
%       ok           logical -- success flag
%       lambda_gauss [4*N_inner x 3] complex -- Gauss-point adjoint (conj'd)

lambda = []; ok = false;
if nargout >= 3, lambda_gauss = []; end

% 默认使用 voxel.pos 作为伴随源位置（Born FT），可选 source_pos（Full Maxwell）
if nargin < 5 || isempty(source_pos)
    source_pos = voxel.pos;
end

if isempty(model)
    fprintf('[solve_adjoint] model is empty\n');
    return;
end

fprintf('[solve_adjoint] starting adjoint solve (N_voxel=%d)...\n', length(voxel.epsilon_r));

inner = voxel.mask_interior;
omega = p.omega(1);
mu0 = p.mu0;
omega_mu0 = omega * mu0;

% Interpolation function names: int_adj_{component}_{re/im}
func_names = {'int_adj_x_re','int_adj_x_im', ...
              'int_adj_y_re','int_adj_y_im', ...
              'int_adj_z_re','int_adj_z_im'};

%% 1. Write adjoint source interpolation functions (-conj(f_adj))
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
            
            % Write -conj(f_adj): flip both real sign and imag sign
            if part == 1
                vals = -real(f_adj(:, d));
            else
                vals = imag(f_adj(:, d));
            end
            
            tmp = [tempname, '.csv'];
            dlmwrite(tmp, [source_pos, vals(:)]);
            model.component('comp1').func(fn).importData(tmp);
            delete(tmp);
        end
    end
    fprintf('  OK adjoint source interpolation functions written (-conj)\n');
catch ME
    fprintf('  FAIL writing adjoint source: %s\n', ME.message);
    return;
end

%% 2. Configure External Current Density (vec1)
phys = model.physics('emw');
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
        fprintf('  OK vec1 assigned to all domains\n');
    catch
        fprintf('  WARN vec1 domain selection failed, continuing\n');
    end
    
    denom = sprintf('%.15e', omega_mu0);
    Je_x = sprintf('(-int_adj_x_im(x,y,z) + i*int_adj_x_re(x,y,z)) / %s', denom);
    Je_y = sprintf('(-int_adj_y_im(x,y,z) + i*int_adj_y_re(x,y,z)) / %s', denom);
    Je_z = sprintf('(-int_adj_z_im(x,y,z) + i*int_adj_z_re(x,y,z)) / %s', denom);
    phys.feature('vec1').set('Je', {Je_x, Je_y, Je_z});
catch ME
    fprintf('  FAIL vec1 config: %s\n', ME.message);
    if vec_new
        try; phys.feature().remove('vec1'); end
    end
    return;
end

%% 3. Zero background field (adjoint_mode=0)
model.param.set('adjoint_mode', '0');
fprintf('  OK background field zeroed (adjoint_mode=0)\n');

%% 4. Adjoint solve (reuse forward LU, B03 修复: runAll 替代 study.run)
try
    model.sol('sol1').runAll();
    fprintf('  OK adjoint solve completed (runAll)\n');
    ok = true;
catch ME
    fprintf('  FAIL adjoint solve: %s\n', ME.message);
end

%% 5. Extract lambda field
% B03 修正 2026-06-27: 移除 conj()
% 对于复对称矩阵 A: A^T=A, A^H=conj(A)
% COMSOL 求解: A * lambda_raw = -conj(f_adj)
% 梯度公式 g = -k0^2 dV dot(E, lambda) 需要 lambda = lambda_raw (非共轭)
%   dot(E, lambda_raw) = sum(conj(E) .* lambda_raw)
%   这直接给出 Born 梯度: g_Born = omega*eps0 * E* * sum(...)
% 旧代码用 conj(lambda_raw) 导致梯度旋转 90° (实部↔虚部互换且符号反)
if ok
    try
        [lambda_raw, ~] = read_field(model, voxel.pos(inner, :));
        lambda = lambda_raw;  % B03 fix: no conj()!
        fprintf('  OK lambda field: %d voxels, |lambda| mean=%.4e\n', ...
            size(lambda,1), mean(vecnorm(lambda,2,2)));
    catch ME
        fprintf('  FAIL lambda extraction: %s\n', ME.message);
        ok = false;
    end
    
    % Extract lambda at Gauss points (must be done BEFORE model restore)
    if ok && nargout >= 3 && ~isempty(voxel.gauss_pos)
        try
            [lambda_raw_g, ~] = read_field(model, voxel.gauss_pos);
            lambda_gauss = lambda_raw_g;  % B03 fix: no conj()!
            fprintf('  OK lambda_gauss: %d Gauss points\n', size(lambda_gauss,1));
        catch ME
            fprintf('  FAIL lambda_gauss extraction: %s\n', ME.message);
            lambda_gauss = [];
        end
    end
end

%% 6. Restore model
try
    model.param.set('adjoint_mode', '1');
    fprintf('  OK background field restored (adjoint_mode=1)\n');
    phys.feature('vec1').set('Je', {'0', '0', '0'});
    fprintf('  OK model restored\n');
catch
end

end
