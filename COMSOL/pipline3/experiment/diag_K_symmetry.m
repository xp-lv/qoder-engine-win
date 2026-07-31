function diag_K_symmetry()
%DIAG_K_SYMMETRY 专门检查 K 矩阵的对称性
%   导出正演 Kc，检查 Kc vs Kc^T 的差异模式

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  K 矩阵对称性专项检查\n');
fprintf('############################################################\n\n');

%% 1. 初始化
p = config();
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
inner = voxel.mask_interior;

%% 2. 设置 eps_r=3（均匀实数）并正演
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();

%% 3. 导出 Kc（三种 symmetry 参数对比）
fprintf('===== 导出 Kc 矩阵（对比 symmetry 参数）=====\n\n');

for sym = {'on', 'off', 'auto'}
    fprintf('  symmetry = "%s":\n', sym{1});
    try
        MA = mphmatrix(model, 'sol1', ...
            'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
            'initmethod', 'sol', 'initsol', 'sol1', ...
            'symmetry', sym{1});
        Kc = MA.Kc;
        n = size(Kc, 1);
        fprintf('    Kc: %dx%d, nnz=%d\n', n, n, nnz(Kc));
        
        % 检查对称性（稀疏矩阵，逐非零元素检查）
        % Kc(i,j) vs Kc(j,i)
        dK = Kc - Kc';  % 不对称差异
        nnz_dK = nnz(dK);
        max_dK = full(max(abs(dK(:))));
        fprintf('    nnz(Kc - Kc'') = %d (不对称非零元素数)\n', nnz_dK);
        fprintf('    max|Kc - Kc''| = %.4e\n', max_dK);
        
        % 对称性比例
        sym_ratio = 1 - nnz_dK / max(nnz(Kc), 1);
        fprintf('    对称性: %.2f%% (nnz 重叠)\n', sym_ratio * 100);
        
        % 检查 Kc 是实还是复
        im_max = full(max(abs(imag(Kc(:)))));
        fprintf('    max|Im(Kc)| = %.4e\n', im_max);
        if im_max < 1e-14
            fprintf('    → Kc 是实矩阵\n');
        else
            fprintf('    → Kc 含虚部（即使 eps_r=3 纯实数）\n');
        end
        
        % 如果不对称，分析不对称的模式
        if max_dK > 1e-10
            % 找出不对称最严重的行/列
            row_asym = full(sum(abs(dK), 2));  % 每行的不对称量
            [val, idx] = sort(row_asym, 'descend');
            fprintf('    不对称最严重的 10 行（DOF 索引）:\n');
            for ki = 1:min(10, length(idx))
                fprintf('      DOF %d: 不对称量=%.4e\n', idx(ki), val(ki));
            end
        end
        
        fprintf('\n');
    catch ME
        fprintf('    FAIL: %s\n\n', ME.message);
    end
end

%% 4. 导出完整 K（不经消约束）
fprintf('===== 导出完整 K 矩阵（不经消约束）=====\n');
try
    MA_full = mphmatrix(model, 'sol1', ...
        'out', {'K', 'L', 'Null', 'ud', 'uscale'}, ...
        'initmethod', 'sol', 'initsol', 'sol1');
    K_full = MA_full.K;
    fprintf('  K (完整): %dx%d, nnz=%d\n', size(K_full,1), size(K_full,2), nnz(K_full));
    
    dK_full = K_full - K_full';
    max_dK_full = full(max(abs(dK_full(:))));
    fprintf('  max|K - K''| = %.4e\n', max_dK_full);
    
    im_full = full(max(abs(imag(K_full(:)))));
    fprintf('  max|Im(K)| = %.4e\n', im_full);
catch ME
    fprintf('  FAIL: %s\n', ME.message);
end

%% 5. 验证: 用 K^T 求解 vs K 求解，对比 lambda
fprintf('\n===== K vs K^T 求解对比 =====\n');

% 用 symmetry='off' 的 Kc
MA_off = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc', 'Null', 'ud', 'uscale'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
Kc = MA_off.Kc;

% 构造一个简单测试源（单位向量在第一个 DOF）
n = size(Kc, 1);
b_test = zeros(n, 1); b_test(1) = 1;

% K \ b
lambda_K = Kc \ b_test;
% K^T \ b
lambda_KT = Kc' \ b_test;

% 对比
diff_lambda = abs(lambda_K - lambda_KT);
fprintf('  |lambda_K - lambda_KT| max = %.4e\n', full(max(diff_lambda)));
fprintf('  |lambda_K|   max = %.4e\n', full(max(abs(lambda_K))));
fprintf('  |lambda_KT|  max = %.4e\n', full(max(abs(lambda_KT))));
fprintf('  相对差异 = %.4f%%\n', full(max(diff_lambda)) / max(full(max(abs(lambda_K))), 1e-30) * 100);

% 如果差异显著，说明 K 不对称确实导致不同的解
if full(max(diff_lambda)) / max(full(max(abs(lambda_K))), 1e-30) > 0.01
    fprintf('  ★ K 和 K^T 给出显著不同的解 → 伴随求解需要用 K^T\n');
else
    fprintf('  → K 和 K^T 解几乎相同 → K 近似对称\n');
end

fprintf('\n############################################################\n');

end
