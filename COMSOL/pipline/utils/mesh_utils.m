function voxel = mesh_utils(model, p, R_scatter)
%MESH_UTILS Build regular voxel grid from scatterer radius
%   voxel = mesh_utils(model, p, R_scatter)
%
%   Builds a uniform voxel grid covering the scatterer sphere plus
%   lambda/4 padding. Marks interior voxels by r < R_scatter.
%
%   Input:
%       model       COMSOL model (unused, kept for API compatibility)
%       p           config struct (voxel_size, lambda)
%       R_scatter   scatterer sphere radius [m]
%   Output:
%       voxel struct with fields:
%           .pos            [N_v x 3] voxel center coords
%           .mask_interior  [N_v x 1] logical, true inside sphere
%           .epsilon_r      [N_v x 1] initial permittivity
%           .dV             [N_v x 1] voxel volume

fprintf('[mesh_utils] Building voxel grid...\n');

% Bounding box: sphere radius + lambda/4 padding
padding = p.lambda / 4;
x_range = [-R_scatter - padding, R_scatter + padding];
y_range = [-R_scatter - padding, R_scatter + padding];
z_range = [-R_scatter - padding, R_scatter + padding];

% Voxel counts
Nx = max(3, ceil((x_range(2) - x_range(1)) / p.voxel_size));
Ny = max(3, ceil((y_range(2) - y_range(1)) / p.voxel_size));
Nz = max(3, ceil((z_range(2) - z_range(1)) / p.voxel_size));

% Voxel centers (colon operator for exact voxel_size spacing)
span = p.voxel_size * (ceil((x_range(2)-x_range(1))/p.voxel_size/2));
x_centers = -span : p.voxel_size : span;
y_centers = -span : p.voxel_size : span;
z_centers = -span : p.voxel_size : span;
[Xc, Yc, Zc] = meshgrid(x_centers, y_centers, z_centers);
voxel.pos = [Xc(:), Yc(:), Zc(:)];
N_v = size(voxel.pos, 1);

% Mark interior voxels (inside sphere)
R2 = Xc(:).^2 + Yc(:).^2 + Zc(:).^2;
voxel.mask_interior = R2 < R_scatter^2;

% Initial epsilon_r: interior=1.1 (slightly above background), exterior=1
voxel.epsilon_r = ones(N_v, 1);
voxel.epsilon_r(voxel.mask_interior) = 1.1;

% Voxel volume
voxel.dV = p.voxel_size^3 * ones(N_v, 1);

fprintf('[mesh_utils] Voxel grid: %d x %d x %d = %d total, %d interior\n', ...
    Nx, Ny, Nz, N_v, sum(voxel.mask_interior));

end
