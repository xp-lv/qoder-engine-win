function bg = bg_planewave(p)
%BG_PLANEWAVE 构造平面波背景场配置
%   bg = bg_planewave(p)
%   从配置结构体 p.background 提取参数，返回标准化的背景场结构。
%
%   输出字段:
%       bg.type        - 'planewave'
%       bg.E0          - 电场复振幅向量 [Ex,Ey,Ez] V/m
%       bg.k_vec        - 波矢 k₀ * k̂
%       bg.k_dir        - 传播方向单位向量
%       bg.description  - 描述字符串（用于日志/可视化标题）

bg_cfg = p.background;

% 归一化极化方向（若用户给的是非归一化的）
pol = bg_cfg.polarization(:);
pol = pol / (norm(pol) + eps);

% 归一化传播方向
k_dir = bg_cfg.k_direction(:);
k_dir = k_dir / (norm(k_dir) + eps);

% 确保极化方向与传播方向正交（横向波条件）
pol = pol - (pol' * k_dir) * k_dir;
pol = pol / (norm(pol) + eps);

bg.type   = 'planewave';
bg.E0     = bg_cfg.amplitude * pol;
bg.k_vec  = p.k0 * k_dir;
bg.k_dir  = k_dir;

theta = acosd(k_dir(3));
phi   = atan2d(k_dir(2), k_dir(1));
bg.description = sprintf('平面波 θ=%.0f° φ=%.0f° |E|=%.1f V/m', ...
    theta, phi, bg_cfg.amplitude);

fprintf('[bg_planewave] %s\n', bg.description);
end
