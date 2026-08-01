function export_truth_field_csv()
%EXPORT_TRUTH_FIELD_CSV 导出真值场为 CSV 文件（供 COMSOL Desktop 使用）

this_dir = fileparts(mfilename('fullpath'));
pipline3_dir = fileparts(this_dir);
cd(pipline3_dir);
addpath('config','utils','core_forward','core_jobs','core_jhyp','core_adjoint');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');

p = config();

fprintf('\n############################################################\n');
fprintf('#  导出真值场 CSV（供 COMSOL Sensitivity 构建）\n');
fprintf('############################################################\n\n');

try mphstart(p.comsol_port); catch ME
    if ~contains(ME.message,'Already connected'), fprintf('[FAIL] mphstart\n'); return; end
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
inner_pos = voxel.pos(inner_idx, :);  % [N_inner × 3]

%% 正演 eps_r=5-3j
fprintf('正演 eps_r=5-3j...\n');
voxel.epsilon_r(inner) = 5.0 - 3.0i;
update_epsilon(model, voxel, p);
model.param.set('freq', num2str(p.freq));
try model.study('std1').feature('freq').set('plist', sprintf('%g[Hz]', p.freq)); catch; end
try model.sol('sol1').clearSolutionData(); catch; end
try model.sol('sol1').clearSolution(); catch; end
model.sol('sol1').runAll();
[E_truth, ~, ~] = solve_forward(model, voxel, p);
fprintf('  |E_truth| mean=%.4e\n', mean(vecnorm(E_truth,2,2)));

%% 导出 6 个 CSV
out_dir = p.base_path;  % pipline3 根目录
files = {'Et_x_re.csv','Et_x_im.csv','Et_y_re.csv','Et_y_im.csv','Et_z_re.csv','Et_z_im.csv'};

for d = 1:3
    % 实部
    fn = fullfile(out_dir, files{(d-1)*2+1});
    data = [inner_pos, real(E_truth(:,d))];
    dlmwrite(fn, data, 'precision', '%.12e');
    fprintf('  %s: %d 行\n', files{(d-1)*2+1}, size(data,1));
    
    % 虚部
    fn = fullfile(out_dir, files{(d-1)*2+2});
    data = [inner_pos, imag(E_truth(:,d))];
    dlmwrite(fn, data, 'precision', '%.12e');
    fprintf('  %s: %d 行\n', files{(d-1)*2+2}, size(data,1));
end

fprintf('\n★ 6 个 CSV 文件已导出到:\n  %s\n', out_dir);
fprintf('  CSV 格式: x,y,z,value（%d 行数据点）\n', N_inner);
fprintf('\n在 COMSOL Desktop 中创建插值函数时:\n');
fprintf('  数据源 → 文件 → 选择对应 CSV\n');
fprintf('  参数数 → 3\n');
fprintf('  外推 → 具体值 → 0\n');
fprintf('############################################################\n');

%% 恢复 + 断开
model.param.set('adjoint_mode','1');
try phys.prop('BackgroundField').set('Eb',[0 0 1]); catch; end
try phys.feature('vec1').set('Je',{'0','0','0'}); catch; end
try ModelUtil.remove('Model'); catch; end
fprintf('\nCOMSOL 已断开。\n');

end
