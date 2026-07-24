addpath('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/matlab');
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

params = struct();
params.model_path = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph';
params.eps_real_csv = 'D:\ZJU\PROJECT\2026-07-02-qoder-engine\engine\sdk\forward_pipeline\.e2e_runs\hollow_sphere\dbim_test\eps_r_1.csv';
params.freq_list = [1000000000.0];
params.n_directions = 64;
params.measurement_R = 0.26;
params.bg_csv = 'D:\ZJU\PROJECT\2026-07-02-qoder-engine\engine\sdk\forward_pipeline\.e2e_runs\hollow_sphere\dbim_test\bg_from_step1.csv';

params.output_path = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/dbim_test/step2/step2_scatter.mat';

csv_data = readmatrix(params.eps_real_csv);
params.voxel_positions = csv_data(:, 1:3);
fprintf('[step2] voxel_positions: %d x %d\n', size(params.voxel_positions));

result = simple_forward_solve(params);

fprintf('\n[step2] === Result ===\n');
fprintf('[step2] status: %s\n', result.status);
if strcmp(result.status, 'error')
    fprintf('[step2] error: %s\n', result.error_msg);
end
if isfield(result, 'scattered_field')
    Es = result.scattered_field.E_s;
    fprintf('[step2] ||E_s|| = %.4e\n', sqrt(sum(abs(Es(:)).^2)));
end
if isfield(result, 'total_field')
    Et = result.total_field.E_total;
    fprintf('[step2] ||E_total_voxel|| = %.4e\n', sqrt(sum(abs(Et(:)).^2)));
end

fid = fopen('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/dbim_test/step2/step2_scatter.flag', 'w');
fprintf(fid, '%d\n', strcmp(result.status, 'success'));
fclose(fid);

clearvars m result;
fprintf('[step2] DONE\n');
