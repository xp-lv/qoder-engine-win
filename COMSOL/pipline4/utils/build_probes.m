function probe = build_probes(p)
%BUILD_PROBES 在散射体内部生成准均匀探针点
%   probe = build_probes(p)
%
%   探针点位于球内（R_min < r < R_max），使用 Fibonacci 球面分布
%   并赋予随机半径，确保 3D 空间准均匀覆盖。
%
%   输出:
%       probe.pos    [N_probe × 3] — 探针点坐标
%       probe.weight [N_probe × 1] — 等权重（1/N_probe）

N = p.N_probe;
R_min = p.probe_R_min;
R_max = p.probe_R_max;

% Fibonacci 球面方向（准均匀）
golden = (1 + sqrt(5)) / 2;
theta = (2 * pi * (1:N) / golden^2)';  % 方位角 [N×1] 列向量
phi   = acos(1 - 2 * (1:N)' / (2*N + 1));  % 极角 [0, pi] [N×1]

% 随机半径（R_min 到 R_max 之间，保证在球内）
% 使用确定性半径分布（等间距），避免随机种子影响可复现性
r_vals = linspace(R_min, R_max, N)';  % [N×1] 列向量

% 球坐标 → 笛卡尔坐标
probe.pos = zeros(N, 3);
probe.pos(:, 1) = r_vals .* sin(phi) .* cos(theta);
probe.pos(:, 2) = r_vals .* sin(phi) .* sin(theta);
probe.pos(:, 3) = r_vals .* cos(phi);

% 等权重
probe.weight = ones(N, 1) / N;

fprintf('[build_probes] %d 探针点, R range [%.3f, %.3f] m\n', N, R_min, R_max);
fprintf('  坐标范围: x[%.3f,%.3f] y[%.3f,%.3f] z[%.3f,%.3f]\n', ...
    min(probe.pos(:,1)), max(probe.pos(:,1)), ...
    min(probe.pos(:,2)), max(probe.pos(:,2)), ...
    min(probe.pos(:,3)), max(probe.pos(:,3)));

end
