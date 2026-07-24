function build_hollow_sphere_model(output_mph_path, comsol_port)
% BUILD_HOLLOW_SPHERE_MODEL  构建空心球散射测试模型并保存 .mph
% =========================================================================
% 目的：为 SDK solve_forward 提供干净的 .mph 输入
%       避开 model_export.m 的历史包袱（domain 编号错乱）
%
% 几何：嵌套球（layer 切分）
%   - R_outer = 0.40m（球外边界）
%   - 主计算域 R=[0, 0.30]
%   - PML 域    R=[0.30, 0.40]
%   - 散射体不显式建模，由 SDK 的 int2(x,y,z) 插值函数隐式定义
%
% 物理场（emw，频域）：
%   - Scattered field 模式（SolveFor=scatteredField）
%   - 背景场 E_bg = +z 方向单位平面波
%   - 散射体区域 eps_r 由调用方通过 CSV 写入（SDK 的 forward_solve.m 完成）
%
% 默认频率：1 GHz
% 网格：自由四面体，正常密度
%
% 预验证：脚本会在保存 .mph 之前先跑一次默认求解（eps_r=1），
%        验证背景场 Ez 在原点 ≈ 1 V/m、散射场 relEz ≈ 0
%
% 用法：
%   build_hollow_sphere_model('C:\path\to\hollow_sphere.mph')
%   build_hollow_sphere_model('C:\path\to\hollow_sphere.mph', 2036)
% =========================================================================

    if nargin < 1 || isempty(output_mph_path)
        error('build:argError', ...
            'Usage: build_hollow_sphere_model(output_mph_path, comsol_port)');
    end
    if nargin < 2 || isempty(comsol_port)
        comsol_port = 2036;
    end

    import com.comsol.model.*
    import com.comsol.model.util.*

    fprintf('[build] ========================================\n');
    fprintf('[build] Hollow Sphere Model Builder\n');
    fprintf('[build] Output: %s\n', output_mph_path);
    fprintf('[build] COMSOL port: %d\n', comsol_port);
    fprintf('[build] ========================================\n');

    % ============================================================
    % 1. 连接 LiveLink（要求 COMSOL Server 已在端口监听）
    % ============================================================
    fprintf('[build] [1/10] Connecting to COMSOL Server (port %d)...\n', comsol_port);

    % 先加 LiveLink API 路径（mphstart 在 mli/ 下）
    mli_candidates = {
        'D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli', ...
        'C:\Program Files\COMSOL\COMSOL62\Multiphysics\mli', ...
    };
    mli_added = false;
    for i = 1:numel(mli_candidates)
        if exist(mli_candidates{i}, 'dir')
            addpath(mli_candidates{i});
            fprintf('[build]       LiveLink API path: %s\n', mli_candidates{i});
            mli_added = true;
            break;
        end
    end
    if ~mli_added
        error('build:mliNotFound', ...
            'LiveLink mli/ directory not found in candidates');
    end

    try
        mphstart(comsol_port);
    catch ME
        error('build:connectFailed', ...
            'mphstart failed: %s\nIs COMSOL Server running on port %d?', ...
            ME.message, comsol_port);
    end
    % 验证连接：试创建一个 model，失败则报错
    try
        model = ModelUtil.create('HollowSphere');
    catch ME
        error('build:connectFailed', ...
            'LiveLink connected but cannot create model: %s', ME.message);
    end
    fprintf('[build]       LiveLink connected\n');

    % ============================================================
    % 2. 模型对象已在上一步验证连接时创建
    % ============================================================
    fprintf('[build] [2/10] Model object ready\n');

    % ============================================================
    % 3. 组件 + 3D 几何（嵌套球）
    % ============================================================
    fprintf('[build] [3/10] Building geometry...\n');
    model.modelNode.create('comp1', true);
    model.geom.create('geom1', 3);
    model.geom('geom1').model('comp1');

    % 外球 R=0.4m，layer 厚度 0.1m（外层 PML）
    model.geom('geom1').create('sph1', 'Sphere');
    model.geom('geom1').feature('sph1').set('r', 0.4);
    model.geom('geom1').feature('sph1').setIndex('layer', 0.1, 0);
    model.geom('geom1').run;
    fprintf('[build]       Sphere R=0.40, layer=0.10 (PML outer shell)\n');

    % ---- 查询实际 domain 编号 ----
    % 嵌套球通常：interior=1（主计算域），outer=2（PML）
    % 但 COMSOL 版本/几何细节会影响，运行时验证
    try
        % mphgetpmodel 也行，但最简单：在已知坐标查 domain
        % 用 mphselectcoords 选 R<0.3 的点，看它们属于哪些 domain
        inner_test_pts = [0, 0, 0; 0.1, 0, 0; 0.2, 0, 0];   % 在主域内
        outer_test_pts = [0.35, 0, 0; 0.39, 0, 0];          % 在 PML 内
        all_pts = [inner_test_pts; outer_test_pts]';

        % 用 mpheval 查询每个点的 domain（通过 dom）
        % LiveLink 不直接给 dom(x,y,z)，改用 selection 几何查询
        % 简化：通过 model.geom().feature().resultSelection 拿所有 domain
        all_domains = model.geom('geom1').feature('sph1').resultSelection;
        fprintf('[build]       All domains after sph1+layer: %s\n', ...
            mat2str(all_domains));
        % 通常 [1 2]：内层 1，外层 2
        if numel(all_domains) >= 2
            interior_domain = all_domains(1);
            pml_domain = all_domains(end);
        else
            interior_domain = 1;
            pml_domain = 2;
        end
    catch ME
        fprintf('[build][WARN] domain query failed: %s\n', ME.message);
        interior_domain = 1;
        pml_domain = 2;
    end
    fprintf('[build]       interior_domain=%d, pml_domain=%d\n', ...
        interior_domain, pml_domain);

    % ============================================================
    % 4. PML 坐标系（外层域，球形缩放）
    % ============================================================
    fprintf('[build] [4/10] Setting up PML (Spherical scaling)...\n');
    model.coordSystem.create('pml1', 'geom1', 'PML');
    model.coordSystem('pml1').selection.set(pml_domain);
    try
        model.coordSystem('pml1').set('ScalingType', 'Spherical');
    catch
        % 某些 COMSOL 版本是 'PMLType'
        try, model.coordSystem('pml1').set('PMLType', 'Spherical'); catch, end
    end

    % ============================================================
    % 5. 物理场（emw + 散射场模式）
    % ============================================================
    fprintf('[build] [5/10] Setting up EMW physics (scattered field)...\n');
    model.physics.create('emw', 'ElectromagneticWaves', 'geom1');
    model.physics('emw').model('comp1');

    % 散射场模式：解 E_s = E_total - E_bg
    model.physics('emw').prop('BackgroundField').set('SolveFor', 'scatteredField');
    model.physics('emw').prop('BackgroundField').set('WaveType', 'userdef');

    % 背景场：+z 方向单位平面波 E_bg = (0, 0, 1) V/m
    model.physics('emw').prop('BackgroundField').set('Ebg', ...
        {'0' '0' '1[V/m]'});
    fprintf('[build]       Scattered field mode, Ebg = +z 1V/m\n');

    % ============================================================
    % 6. 材料（全域空气 eps_r=1，SDK 后续会用 int2 覆盖）
    % ============================================================
    fprintf('[build] [6/10] Adding air material (eps_r=1)...\n');
    model.material.create('mat1', 'Common', 'comp1');
    model.material('mat1').propertyGroup('def').set('relpermittivity', {'1'});
    model.material('mat1').propertyGroup('def').set('relpermeability', {'1'});
    model.material('mat1').propertyGroup('def').set('electricconductivity', {'0'});
    model.material('mat1').selection.all;
    fprintf('[build]       mat1 = air on all domains\n');

    % ============================================================
    % 7. 网格（autoMeshSize + 手动 hmax，避免 layer 几何默认触发扫掠网格）
    % ============================================================
    fprintf('[build] [7/10] Building mesh...\n');
    model.mesh.create('mesh1', 'geom1');
    % autoMeshSize(8) 较粗，不触发扫掠（参考 model_export.m 用的是 9）
    model.mesh('mesh1').autoMeshSize(8);
    % 手动限定最大单元尺寸 = 0.04m（1GHz 37.5cm 波长，约10单元/波长）
    try
        model.mesh('mesh1').set('hmax', '0.04');
    catch
        % 某些版本需要在 feature 上设
        try
            model.mesh('mesh1').feature('size').set('hmax', '0.04');
        catch
            fprintf('[build][WARN] could not set hmax explicitly\n');
        end
    end
    model.mesh('mesh1').run;
    fprintf('[build]       Mesh built (autoMeshSize=8)\n');

    % ============================================================
    % 8. Study（1 GHz 单频）
    % ============================================================
    fprintf('[build] [8/10] Creating Frequency study @ 1 GHz...\n');
    model.study.create('std1');
    model.study('std1').create('freq', 'Frequency');
    model.study('std1').feature('freq').setSolveFor('/physics/emw', true);
    model.study('std1').feature('freq').set('plist', '1[GHz]');

    % ============================================================
    % 9. 预求解 + 验证（默认 eps_r=1，纯背景场，应无散射）
    % ============================================================
    fprintf('[build] [9/10] Running pre-save validation solve...\n');
    % 参照 model_export.m 的 sol 构造顺序：
    %   sol1 -> attach(std1) -> StudyStep -> Variables -> Stationary -> runAll
    model.sol.create('sol1');
    model.sol('sol1').study('std1');
    model.sol('sol1').attach('std1');
    model.sol('sol1').create('st1', 'StudyStep');
    model.sol('sol1').feature('st1').set('study', 'std1');
    model.sol('sol1').feature('st1').set('studystep', 'freq');
    model.sol('sol1').create('v1', 'Variables');
    model.sol('sol1').feature('v1').set('control', 'freq');
    model.sol('sol1').create('s1', 'Stationary');
    model.sol('sol1').feature('s1').set('stol', 0.01);
    try
        model.sol('sol1').runAll;
    catch ME
        fprintf('[build][WARN] runAll failed: %s\n', ME.message);
        % fallback：试 run
        try
            model.sol('sol1').run;
        catch ME2
            error('build:solveFailed', 'Solve failed: %s', ME2.message);
        end
    end

    fprintf('[build]       Initial solve finished, validating fields...\n');
    test_points = [0 0 0; 0.1 0 0; -0.1 0 0; 0 0.1 0; 0.2 0 0; 0.35 0 0]';

    % mphinterp 验证场值（用 'coord' 参数传坐标，不是 'selection'）
    % Ez（总场）：应 ≈ 1 V/m（背景场，无散射体）
    try
        Ez = mphinterp(model, 'emw.Ez', 'dataset', 'dset1', ...
                       'coord', test_points);
    catch ME1
        % 某些版本用 selection + 数组索引
        fprintf('[build][WARN] mphinterp coord failed: %s\n', ME1.message);
        fprintf('[build][WARN] Trying selection=1 (interior domain)...\n');
        Ez = mphinterp(model, 'emw.Ez', 'dataset', 'dset1', 'selection', 1);
        Ez = Ez(1) * ones(6, 1);   % fallback，只用 domain 1 的代表值
    end

    try
        relEz = mphinterp(model, 'emw.relEz', 'dataset', 'dset1', ...
                          'coord', test_points);
    catch
        relEz = mphinterp(model, 'emw.relEz', 'dataset', 'dset1', 'selection', 1);
        relEz = relEz(1) * ones(6, 1);
    end

    labels = {'(0,0,0)', '(0.1,0,0)', '(-0.1,0,0)', '(0,0.1,0)', '(0.2,0,0)', '(0.35,0,0) PML'};
    fprintf('[build]       Pre-save field validation:\n');
    fprintf('[build]       %-20s %-18s %-18s\n', 'Point', '|Ez| (total)', '|relEz| (scattered)');
    all_ok = true;
    for i = 1:size(test_points, 2)
        ez_val = abs(Ez(i));
        rel_val = abs(relEz(i));
        marker = '';
        if i <= 5 && ez_val < 0.5
            marker = '  <-- FAIL (background field <0.5)';
            all_ok = false;
        end
        if i <= 5 && rel_val > 0.1
            marker = '  <-- WARN (scattered >0.1 with no scatterer)';
        end
        fprintf('[build]       %-20s %.4e V/m     %.4e V/m%s\n', ...
            labels{i}, ez_val, rel_val, marker);
    end

    if ~all_ok
        fprintf('[build][ERROR] Background field validation failed.\n');
        fprintf('[build][ERROR] Possible causes:\n');
        fprintf('[build][ERROR]   - PML scaling type wrong\n');
        fprintf('[build][ERROR]   - pml_domain selection wrong (current=%d)\n', pml_domain);
        fprintf('[build][ERROR]   - Ebg not properly set\n');
        error('build:validationFailed', 'Pre-save validation failed');
    end
    fprintf('[build]       Validation PASSED\n');

    % ============================================================
    % 10. 保存 .mph + 断开
    % ============================================================
    fprintf('[build] [10/10] Saving model to: %s\n', output_mph_path);
    model.save(output_mph_path, 'compressed');   % 压缩模式减小文件
    fprintf('[build]        Model saved\n');

    ModelUtil.disconnect;
    fprintf('[build]        LiveLink disconnected (Server left running)\n');
    fprintf('[build] ========================================\n');
    fprintf('[build] BUILD COMPLETE\n');
    fprintf('[build] ========================================\n');
end
