function setup()
%SETUP INVERSE_SCATTER3.0 正演管线路径初始化（pipline 自包含版）
%   Usage: setup()
%   把 pipline 根目录及其子目录加入 MATLAB path, 初始化随机种子, 显示欢迎信息。
%
%   改造说明（2026-07-20 自包含适配）:
%     - 原 setup.m 向上查找 .research/ 目录（原项目结构），pipline 无此目录
%     - pipline 已将 core/ 重组为 core_forward/core_adjoint/core_inversion/core_jhyp/core_jobs
%     - env.json 真理源从 .research/env.json 改为 pipline/config/env.json
%     - 删除 core/background、custom/* 等原项目独有路径

    %% ---- 1. pipline 根路径定位（config 所在目录的上级）----
    this_file = mfilename('fullpath');
    project_root = fileparts(this_file);  % config/ 目录
    project_root = fileparts(project_root);  % pipline/ 目录

    %% ---- 2. 添加 pipline 子目录到 MATLAB path ----
    addpath(project_root);
    sub_dirs = {'config', 'utils', 'viz', 'algorithm', ...
                'core_forward', 'core_adjoint', 'core_inversion', ...
                'core_jhyp', 'core_jobs', 'experiment'};
    for i = 1:numel(sub_dirs)
        d = fullfile(project_root, sub_dirs{i});
        if exist(d, 'dir')
            addpath(d);
        end
    end

    % 读取 env.json 加入 COMSOL LiveLink mli 路径（pipline/config/env.json）
    env_json_path = fullfile(project_root, 'config', 'env.json');
    if exist(env_json_path, 'file')
        env_cfg = jsondecode(fileread(env_json_path));
        if isfield(env_cfg.tools, 'comsol_mli') && ~isempty(env_cfg.tools.comsol_mli)
            addpath(env_cfg.tools.comsol_mli);
            fprintf('  COMSOL mli: %s\n', env_cfg.tools.comsol_mli);
        end
    else
        warning('setup:EnvNotFound', '未找到 config/env.json: %s', env_json_path);
    end

    %% ---- 3. 固定随机种子（可复现性，强制）----
    rng(42);

    %% ---- 4. 切换工作目录到 pipline 根 ----
    cd(project_root);

    %% ---- 5. 加载全局配置 ----
    p = config();
    fprintf('==========================================\n');
    fprintf('  INVERSE_SCATTER3.0 正演管线 路径初始化完成\n');
    fprintf('==========================================\n');
    fprintf('  pipline 根: %s\n', project_root);
    fprintf('  MATLAB: %s\n', version);
    fprintf('  COMSOL 模型: %s\n', p.comsol_model_path);
    fprintf('  N_k 光锥方向: %d\n', p.N_k);
    fprintf('  体素尺寸: %.3f m (~lambda/%.0f)\n', p.voxel_size, p.lambda/p.voxel_size);
    fprintf('  测量球面半径: %.2f m\n', p.R_sphere);
    fprintf('==========================================\n');
    fprintf('  后续跑: verify_forward_pipeline()\n');
    fprintf('==========================================\n');
end
