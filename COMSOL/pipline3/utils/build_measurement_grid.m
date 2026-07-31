function grid = build_measurement_grid(p)
%BUILD_MEASUREMENT_GRID 生成测量球面均匀采样网格
%   grid = build_measurement_grid(p)
%
%   输入: p - config (使用 p.R_sphere, p.N_theta, p.N_phi)
%   输出: grid 结构 (与 core/jobs/extract_scattered.m 兼容)
%       .pos        [N_surface × 3] 笛卡尔坐标
%       .r_hat      [N_surface × 3] 径向单位向量
%       .theta_hat  [N_surface × 3] theta 单位向量
%       .phi_hat    [N_surface × 3] phi 单位向量
%       .norm       [N_surface × 3] 法向量 (= r_hat)
%       .weight     [N_surface × 1] 立体角权重
%
%   物理: 球面 R_sphere 上 N_theta × N_phi 单元中点采样
%   用途: V5a sanity check (extract_scattered + lightcone_project → J_obs)
%   继承自: 2.0 工程, exp01-10 全部沿用此 schema
%   用户决策 2026-06-15: V5a 验证 J_obs 和 J_hyp 接近相等

R = p.R_sphere;
N_theta = p.N_theta;
N_phi = p.N_phi;
N_surface = N_theta * N_phi;

% theta 单元中点 (cos-weighted 离散化)
theta_v = linspace(0, pi, N_theta + 1);
theta_v = theta_v(1:end-1) + diff(theta_v) / 2;

% phi 单元中点
phi_v = linspace(0, 2*pi, N_phi + 1);
phi_v = phi_v(1:end-1) + diff(phi_v) / 2;

delta_theta = pi / N_theta;
delta_phi = 2 * pi / N_phi;

grid.pos       = zeros(N_surface, 3);
grid.r_hat     = zeros(N_surface, 3);
grid.theta_hat = zeros(N_surface, 3);
grid.phi_hat   = zeros(N_surface, 3);
grid.norm      = zeros(N_surface, 3);
grid.weight    = zeros(N_surface, 1);

count = 0;
for i_theta = 1:N_theta
    theta_i = theta_v(i_theta);
    sin_t = sin(theta_i);
    cos_t = cos(theta_i);
    % 立体角权重 (R^2 dOmega = R^2 sin(theta) dtheta dphi)
    area_weight = R^2 * sin_t * delta_theta * delta_phi;

    for i_phi = 1:N_phi
        count = count + 1;
        phi_i = phi_v(i_phi);
        sin_p = sin(phi_i);
        cos_p = cos(phi_i);

        % 球面坐标 → 笛卡尔
        x = R * sin_t * cos_p;
        y = R * sin_t * sin_p;
        z = R * cos_t;
        grid.pos(count, :) = [x, y, z];

        % 径向单位向量 = r/R
        r_hat = [sin_t * cos_p, sin_t * sin_p, cos_t];
        grid.r_hat(count, :) = r_hat;
        grid.norm(count, :) = r_hat;

        % theta 单位向量 (球面切平面内, 朝 +theta 方向)
        theta_hat = [cos_t * cos_p, cos_t * sin_p, -sin_t];
        grid.theta_hat(count, :) = theta_hat;

        % phi 单位向量 (球面切平面内, 朝 +phi 方向)
        phi_hat = [-sin_p, cos_p, 0];
        grid.phi_hat(count, :) = phi_hat;

        grid.weight(count) = area_weight;
    end
end

fprintf('[build_measurement_grid] N_surface=%d (R=%.3fm, %dx%d theta×phi)\n', ...
    N_surface, R, N_theta, N_phi);
end
