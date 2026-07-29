function p = config()
%CONFIG 极简伴随法开发配置（pipline_adjoint）
%   ★ 目标：降规模快速验证伴随法精确性，验证通过后再提升规模 ★
%
%   与原 pipline/config.m 的核心差异：
%     1. 2层几何模型（内球散射体 + 外球空气PML），替代3层复杂结构
%     2. 大幅降规模：体素~30、测量点~200、k方向~16
%     3. 程序化构建模型（build_lightweight_model.m），不依赖预设 .mph
%     4. 专注于单参数（eps_r）验证，暂不含 cavity/hole 几何参数

%% ---- 物理常数 ----
p.c       = 299792458;
p.eps0    = 8.854187817e-12;
p.mu0     = 4*pi*1e-7;
p.eta0    = sqrt(p.mu0/p.eps0);

%% ---- 频率 ----
p.freq     = 1e9;
p.omega    = 2*pi*p.freq;
p.k0       = p.omega / p.c;
p.lambda   = p.c / p.freq;

%% ---- ★ 极简 2 层几何模型 ----
% 内层球：散射体区域
p.R_inner   = 0.06;     % 散射体内球半径 [m]
% 外层球：空气 + PML
p.R_air     = 0.12;     % 空气层外边界 [m]
p.pml_thick = 0.04;     % PML 层厚度 [m]
p.R_outer   = p.R_air + p.pml_thick;  % 总外半径 = 0.16m
% 测量球面（在空气层内）
p.R_sphere  = 0.09;     % 测量球面半径 [m]

%% ---- 降规模采样 ----
p.N_theta   = 12;       % theta 采样数（原 48 → 12）
p.N_phi     = 24;       % phi 采样数（原 96 → 24）
p.N_surface = p.N_theta * p.N_phi;  % = 288 个测量点（原 4608）

%% ---- k 空间光锥采样 ----
p.N_k       = 16;       % 光锥方向数（原 64 → 16）

%% ---- 散射体与体素 ----
p.a_scatter  = p.R_inner;  % 散射体球半径 = 内层球半径
p.voxel_size = 0.02;       % 体素边长（原 0.01 → 0.02，更粗网格）
% 预计内部体素：球体积 / 体素体积 ≈ (4/3π·0.06³) / 0.02³ ≈ 113
% 实际 FEM 单元数取决于网格划分

%% ---- 背景场配置 ----
p.background.type        = 'planewave';
p.background.amplitude   = 1.0;
p.background.polarization = [0, 0, 1];  % E along Z
p.background.k_direction  = [1, 0, 0];  % k along X

%% ---- 验证参数 ----
% 真值配置：均匀球 eps_r_true
p.eps_r_true  = 5.0;    % 真值介电常数
p.eps_r_init  = 3.0;    % 初始猜测

%% ---- 数值保护 ----
p.E_threshold = 1e-6;
p.F_obs_min   = 1e-60;

%% ---- 项目路径 ----
p.base_path = fileparts(fileparts(mfilename('fullpath')));

%% ---- COMSOL LiveLink ----
p.comsol_port = 2036;
% 模型文件（程序化构建后保存）
p.comsol_model_path = fullfile(p.base_path, '2layer.mph');

%% ---- 数据路径 ----
p.dir_data   = fullfile(p.base_path, 'data');
p.dir_result = fullfile(p.dir_data, 'results');
for d = {p.dir_data, p.dir_result}
    if ~exist(d{1}, 'dir'), mkdir(d{1}); end
end

%% ---- 梯度公式选择 ----
% 'bilinear'  = Re(E·λ)   无共轭（COMSOL 复对称刚度矩阵正确公式）
% 'hermitian' = Re(conj(E)·λ)  共轭（旧版，已知错误）
p.gradient_dot = 'bilinear';

%% ---- FD 验证参数 ----
p.fd_deltas_eps = [0.1, 0.01, 0.001];   % eps_r FD 步长序列
p.fd_delta_ref  = 0.001;                  % 参考步长（最小）

end
