function bg = bg_gaussian(p)
%BG_GAUSSIAN 构造高斯波束背景场配置
%   bg = bg_gaussian(p)
%   从配置结构体 p.background 提取参数。
%   注意：高斯波束在 COMSOL 中通过用户自定义背景场实现，
%   此处仅构造配置结构体，实际场分布由 bg_setup 注入 COMSOL。
%
%   输出字段:
%       bg.type        - 'gaussian'
%       bg.E0          - 极化方向单位向量
%       bg.k_dir        - 传播方向单位向量
%       bg.waist       - 束腰半径 (m)
%       bg.focus       - 焦点坐标 [x,y,z] (m)
%       bg.amplitude   - 振幅因子
%       bg.description - 描述字符串

bg_cfg = p.background;

% 归一化
pol = bg_cfg.polarization(:);
pol = pol / (norm(pol) + eps);

k_dir = bg_cfg.k_direction(:);
k_dir = k_dir / (norm(k_dir) + eps);

% 横向波条件
pol = pol - (pol' * k_dir) * k_dir;
pol = pol / (norm(pol) + eps);

bg.type      = 'gaussian';
bg.E0        = pol;
bg.k_dir     = k_dir;
bg.waist     = bg_cfg.waist;
bg.focus     = bg_cfg.focus(:)';
bg.amplitude = bg_cfg.amplitude;

theta = acosd(k_dir(3));
phi   = atan2d(k_dir(2), k_dir(1));
bg.description = sprintf('高斯波束 θ=%.0f° φ=%.0f° waist=%.2fm', ...
    theta, phi, bg.waist);

fprintf('[bg_gaussian] %s\n', bg.description);
end
