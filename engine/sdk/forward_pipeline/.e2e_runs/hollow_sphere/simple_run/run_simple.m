
addpath('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/matlab');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

params = struct();
params.model_path = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph';
params.eps_real_csv = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/hollow_sphere_eps.csv';
params.freq_list = [1e9];
params.n_directions = 64;
params.measurement_R = 0.26;
params.output_path = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/simple_run/scatter_field.mat';

% 加载体素位置
v = load('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/simple_run/voxel_positions.mat');
params.voxel_positions = v.voxel_positions;
fprintf('[main] voxel_positions: %d x %d\n', size(params.voxel_positions));

result = simple_forward_solve(params);

fprintf('\n[main] === Result ===\n');
fprintf('[main] status: %s\n', result.status);
if strcmp(result.status, 'error')
    fprintf('[main] error: %s\n', result.error_msg);
end
if isfield(result, 'scattered_field')
    Es = result.scattered_field.E_s;
    fprintf('[main] E_s shape: %s\n', mat2str(size(Es)));
    fprintf('[main] ||E_s|| = %.4e\n', sqrt(sum(abs(Es(:)).^2)));
end
if isfield(result, 'total_field')
    Et = result.total_field.E_total;
    fprintf('[main] E_total shape: %s\n', mat2str(size(Et)));
    fprintf('[main] ||E_total_voxel|| = %.4e\n', sqrt(sum(abs(Et(:)).^2)));
end

% 写 exit flag
fid = fopen('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/simple_run/exit.flag', 'w');
fprintf(fid, '%d\n', (strcmp(result.status, 'success')));
fclose(fid);

% 不调 ModelUtil.disconnect（会杀 Server）；只清除 model 引用
clearvars m result;
fprintf('[main] === DONE ===\n');
