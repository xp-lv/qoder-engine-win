function test_sdf_chain_rule()
%TEST_SDF_CHAIN_RULE 验证 SDF tanh 链式法则 dε/d(hole_j) 的解析公式 vs FD

rng(42);
pos = rand(100, 3) * 0.1;  % 100 个随机点
hole_pos = [0.02; 0.01; 0.005];
eps_r = 4.0;
delta = 0.008;

diff = pos - hole_pos';
d = sqrt(sum(diff.^2, 2));
sech2 = 1 ./ cosh(d / delta).^2;
deps_dd = -(1 - eps_r) * 0.5 * sech2 / delta;

dh = 1e-4;

for j = 1:3
    ej = zeros(3,1); ej(j) = 1;
    d_plus = sqrt(sum((pos - repmat(hole_pos' + dh*ej', 100, 1)).^2, 2));
    d_minus = sqrt(sum((pos - repmat(hole_pos' - dh*ej', 100, 1)).^2, 2));
    eps_plus = eps_r + (1-eps_r) * 0.5 * (1 - tanh(d_plus/delta));
    eps_minus = eps_r + (1-eps_r) * 0.5 * (1 - tanh(d_minus/delta));
    fd_grad = (eps_plus - eps_minus) / (2*dh);
    analytical = deps_dd .* (-diff(:,j) ./ (d + 1e-30));
    mask = abs(fd_grad) > 1e-15;
    rj = analytical(mask) ./ fd_grad(mask);
    fprintf('j=%d: SDF 链式法则 ratio mean=%.6f std=%.6f n=%d\n', ...
        j, mean(rj), std(rj), sum(mask));
end

% 同时验证 dε/d(eps_r)
eps_plus = (eps_r+0.01) + (1-(eps_r+0.01)) * 0.5 * (1 - tanh(d/delta));
eps_minus = (eps_r-0.01) + (1-(eps_r-0.01)) * 0.5 * (1 - tanh(d/delta));
fd_deps = (eps_plus - eps_minus) / (2*0.01);
analytical_deps = 0.5 * (1 + tanh(d/delta));
mask2 = abs(fd_deps) > 1e-15;
r_eps = analytical_deps(mask2) ./ fd_deps(mask2);
fprintf('eps_r: SDF 链式法则 ratio mean=%.6f std=%.6f n=%d\n', ...
    mean(r_eps), std(r_eps), sum(mask2));
end
