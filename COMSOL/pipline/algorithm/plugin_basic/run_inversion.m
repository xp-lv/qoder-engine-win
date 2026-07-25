function state = run_inversion(model, voxel, lc, grid, p)
%RUN_INVERSION basic 插件统一入口
%   将 core_inversion/inversion_loop 封装为统一签名
%
%   输入:
%       model   COMSOL 模型对象（须已 mphload）
%       voxel   体素结构（须已 fem_mesh_utils）
%       lc      LightConeData（含 J_obs_perp）
%       grid    测量网格
%       p       config
%   输出:
%       state   反演状态（含 history_residual, epsilon_r, converged 等）

fprintf('========== [plugin_basic] 反演启动 ==========\n');

% basic 插件直接调用 core_inversion/inversion_loop
addpath(fullfile(p.base_path, 'core_inversion'));
addpath(fullfile(p.base_path, 'core_jhyp'));
addpath(fullfile(p.base_path, 'core_adjoint'));

state = inversion_loop(voxel, lc, model, p);

fprintf('========== [plugin_basic] 反演完成 ==========\n');
fprintf('  最终残差: %.6e, 收敛: %d\n', state.residual, state.converged);

end
