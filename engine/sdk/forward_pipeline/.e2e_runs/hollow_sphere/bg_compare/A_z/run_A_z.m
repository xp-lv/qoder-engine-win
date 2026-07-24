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
params.output_path = 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/bg_compare/A_z/A_z_scatter.mat';
params.bg_E = [[0.0, 0.0, 1.0]];   % 背景场 [Ex, Ey, Ez] V/m

csv_data = readmatrix('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/hollow_sphere_eps.csv');
params.voxel_positions = csv_data(1:min(100, size(csv_data,1)), 1:3);
fprintf('[A_z] voxel_positions: %d x %d\n', size(params.voxel_positions));

result = simple_forward_solve(params);

fprintf('\n[A_z] === Result ===\n');
fprintf('[A_z] status: %s\n', result.status);
if strcmp(result.status, 'error')
    fprintf('[A_z] error: %s\n', result.error_msg);
end
if isfield(result, 'scattered_field')
    Es = result.scattered_field.E_s;
    Es_norm = sqrt(sum(abs(Es(:)).^2));
    fprintf('[A_z] ||E_s|| = %.4e\n', Es_norm);

    % 保存 E_s 数组的前 10 个值用于跨 run 对比
    Es_vec = Es(:);
    fprintf('[A_z] E_s first 10 (real): ');
    for i = 1:min(10, numel(Es_vec))
        fprintf('%.4f ', real(Es_vec(i)));
    end
    fprintf('\n');
end

fid = fopen('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/bg_compare/A_z/A_z_scatter.flag', 'w');
fprintf(fid, '%d\n', strcmp(result.status, 'success'));
fclose(fid);

clearvars m result;
fprintf('[A_z] DONE\n');
