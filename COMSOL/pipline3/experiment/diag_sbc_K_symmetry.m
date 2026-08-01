function diag_sbc_K_symmetry()
%DIAG_SBC_K_SYMMETRY 检查用户修改后的 mph 模型的 K 对称性
%   用户已在 COMSOL Desktop 中去掉 PML 并添加了散射边界条件

this_dir = fileparts(mfilename('fullpath'));
pipline_dir = fileparts(this_dir);
cd(pipline_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

fprintf('\n############################################################\n');
fprintf('#  K 对称性检查（用户修改后的 SBC 模型）\n');
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

% 设置 eps_r=3 并正演
voxel = fem_mesh_utils(model, p, p.R_inner);
inner = voxel.mask_interior;
voxel.epsilon_r(inner) = 3.0;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
fprintf('正演完成\n\n');

%% 2. 检查物理特征列表（确认 PML 已移除、SBC 已添加）
fprintf('=== EMW 物理特征列表 ===\n');
feat_tags = phys.feature().tags();
for fi = 1:length(feat_tags)
    ft = char(feat_tags(fi));
    fprintf('  feature[%d]: %s\n', fi, ft);
end

% 检查坐标系（PML 坐标系是否还存在）
try
    cs_tags = model.coordSystem().tags();
    fprintf('\n坐标系: ');
    for ci = 1:length(cs_tags)
        fprintf('%s ', cs_tags{ci});
    end
    fprintf('\n');
catch
end

%% 3. K 对称性检查
fprintf('\n=== K 对称性检查 ===\n');
MA = mphmatrix(model, 'sol1', ...
    'out', {'Kc', 'Lc'}, ...
    'initmethod', 'sol', 'initsol', 'sol1', ...
    'symmetry', 'off');
Kc = MA.Kc;
fprintf('Kc: %dx%d, nnz=%d\n', size(Kc,1), size(Kc,2), nnz(Kc));

% 复对称性: K = K^T?
dK = Kc - Kc';
max_dK = full(max(max(abs(dK))));
nnz_dK = nnz(dK);
fprintf('max|K-K''| = %.4e\n', max_dK);
fprintf('nnz(K-K'') = %d (不对称非零元素)\n', nnz_dK);

if max_dK < 1e-10
    fprintf('\n  ★★★ K 对称！PML 移除 + SBC 成功 ★★★\n');
elseif max_dK < 0.1
    fprintf('\n  K 近似对称（max=%.2e），比 PML 模型（max=4.4）大幅改善\n', max_dK);
else
    fprintf('\n  K 仍不对称（max=%.2e）\n', max_dK);
end

% 额外: K 含虚部?
im_max = full(max(abs(imag(Kc(:)))));
fprintf('max|Im(K)| = %.4e\n', im_max);
if im_max < 1e-14
    fprintf('  K 是实矩阵（实数 eps_r 下）\n');
else
    fprintf('  K 含虚部\n');
end

%% 4. 对比 PML 模型的 K
fprintf('\n=== 与 PML 模型对比 ===\n');
fprintf('  PML 模型: max|K-K''|=4.40, max|Im(K)|=0.97\n');
fprintf('  SBC 模型: max|K-K''|=%.2e, max|Im(K)|=%.2e\n', max_dK, im_max);

fprintf('\n############################################################\n');

end
