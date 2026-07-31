function p = config()
%CONFIG pipline4 极简近场伴随法诊断管线
%   ★ 目标：单体素 + 近场探针 + 复数ε_r，隔离 COMSOL求解+梯度组装两层 ★
%
%   与管线3的核心差异：
%     1. 无远场光锥投影（删除 lightcone_project / Stratton-Chu）
%     2. 无 Born FT 反投影（伴随源直接来自 L2 残差，解析可推导）
%     3. 无双源路径（仅体积路径 ExternalCurrentDensity）
%     4. 代价函数退化为标量 L2: F = Σ|E(r_p) - E*(r_p)|² / Σ|E*|²
%     5. 单体素梯度公式（无空间循环，无 Gauss 复杂度）

%% ---- 物理常数 ----
p.c       = 299792458;
p.eps0    = 8.854187817e-12;
p.mu0     = 4*pi*1e-7;
p.eta0    = sqrt(p.mu0/p.eps0);

%% ---- 频率 ----
p.freq     = 1e9;        % 1 GHz
p.omega    = 2*pi*p.freq;
p.k0       = p.omega / p.c;
p.lambda   = p.c / p.freq;

%% ---- 2层几何模型（复用管线3的 2layer.mph）----
p.R_inner   = 0.06;      % 散射体内球半径 [m]
p.R_air     = 0.12;      % 空气层外边界 [m]
p.pml_thick = 0.04;      % PML 层厚度 [m]
p.R_outer   = p.R_air + p.pml_thick;  % 总外半径 = 0.16m
p.a_scatter = p.R_inner; % 散射体球半径

%% ---- 背景场配置 ----
p.background.type         = 'planewave';
p.background.amplitude    = 1.0;
p.background.polarization = [0, 0, 1];  % E along Z
p.background.k_direction  = [1, 0, 0];  % k along X

%% ---- ★ 近场探针点配置 ----
% 探针点在散射体内部，直接读 E 场，不做远场投影
p.N_probe     = 8;       % 探针点数量
p.probe_R_max = 0.04;    % 探针点最大半径 [m]（球内，远离边界）
p.probe_R_min = 0.005;   % 探针点最小半径 [m]（远离球心奇点）

%% ---- ★ 复数 ε_r 配置 ----
% 真值（COMSOL 正演生成 E*）
p.eps_r_true_re = 5.0;               % 真值实部
p.eps_r_true_im = -1.0;              % 真值虚部（负=损耗）
p.eps_r_true    = p.eps_r_true_re + 1j * p.eps_r_true_im;

% 初始猜测（偏离真值，测试梯度方向）
p.eps_r_init_re = 3.0;
p.eps_r_init_im = -0.5;
p.eps_r_init    = p.eps_r_init_re + 1j * p.eps_r_init_im;

%% ---- FD 验证参数 ----
p.fd_deltas_re = [0.1, 0.01, 0.001];   % 实部 FD 步长序列
p.fd_deltas_im = [0.1, 0.01, 0.001];   % 虚部 FD 步长序列
p.fd_sign_threshold = 0.95;            % FD sign 通过率阈值

%% ---- 数值保护 ----
p.E_threshold = 1e-6;
p.F_norm_min  = 1e-60;

%% ---- 梯度内积约定 ----
% 'bilinear'  = E·λ 无共轭（COMSOL 复对称 K 正确公式）
% 'hermitian' = conj(E)·λ 共轭
p.gradient_dot = 'bilinear';

%% ---- 项目路径 ----
p.base_path = fileparts(fileparts(mfilename('fullpath')));

%% ---- COMSOL LiveLink ----
p.comsol_port = 2036;

% 复用管线3的 2layer.mph 模型文件
pipline3_path = fullfile(fileparts(p.base_path), 'pipline3');
p.comsol_model_path = fullfile(pipline3_path, '2layer.mph');

if ~exist(p.comsol_model_path, 'file')
    fprintf('[config] WARNING: 管线3模型文件不存在: %s\n', p.comsol_model_path);
    fprintf('         将使用 build_lightweight_model 程序化构建\n');
    p.comsol_model_path = fullfile(p.base_path, '2layer_p4.mph');
end

%% ---- mphmatrix 参数 ----
p.mphmatrix_symmetry = 'on';     % 复对称 Kc 用 'on' 利用对称性
p.use_decomposition  = true;     % 使用 MATLAB decomposition 缓存 LU

%% ---- 数据路径 ----
p.dir_data   = fullfile(p.base_path, 'data');
p.dir_result = fullfile(p.dir_data, 'results');
for d = {p.dir_data, p.dir_result}
    if ~exist(d{1}, 'dir'), mkdir(d{1}); end
end

end
