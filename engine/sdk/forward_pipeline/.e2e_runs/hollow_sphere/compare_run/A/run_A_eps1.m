
addpath('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/matlab');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

params = struct();
params.model_path = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph';
params.eps_real_csv = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/compare_run/uniform_eps1.csv';
params.freq_list = [1e9];
params.n_directions = 64;
params.measurement_R = 0.26;
params.output_path = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/compare_run/A/A_eps1_scatter.mat';

% 简化：用 CSV 自身的前 3 列作为 voxel positions（只取前 100 个加速）
csv_data = readmatrix('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/compare_run/uniform_eps1.csv');
params.voxel_positions = csv_data(1:min(100, size(csv_data,1)), 1:3);
fprintf('[A_eps1] voxel_positions: %d x %d\n', size(params.voxel_positions));

result = simple_forward_solve(params);

fprintf('\n[A_eps1] === Result ===\n');
fprintf('[A_eps1] status: %s\n', result.status);
if strcmp(result.status, 'error')
    fprintf('[A_eps1] error: %s\n', result.error_msg);
end
if isfield(result, 'scattered_field')
    Es = result.scattered_field.E_s;
    fprintf('[A_eps1] ||E_s|| = %.4e\n', sqrt(sum(abs(Es(:)).^2)));
end

fid = fopen('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/compare_run/A/A_eps1_scatter.flag', 'w');
fprintf(fid, '%d\n', strcmp(result.status, 'success'));
fclose(fid);

clearvars m result;
fprintf('[A_eps1] DONE\n');
