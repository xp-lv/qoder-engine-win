function lc = compute_jobs(model, grid, p)
%COMPUTE_JOBS 完整 J_obs 计算流水线（COMSOL 原生散射场）
%   lc = compute_jobs(model, grid, p)
%
%   流程:
%     1. COMSOL relE 散射场提取
%     2. 光锥投影 → J_obs
%
%   输入:
%       model   已求解的 COMSOL 模型
%       grid    测量网格
%       p       config
%   输出:
%       lc      LightConeData（含 J_obs_perp）

fprintf('========== J_obs 计算 ==========\n');

% Step 1: 提取 COMSOL 原生散射场
sf = extract_scattered(model, grid);

% Step 2: 光锥投影
lc = lightcone_project(grid, sf, p);

fprintf('========== J_obs 计算完成 ==========\n');

end
