
addpath('D:\LenovoSoftstore\Install\COMSOL62\Multiphysics\mli');
mphstart(2036);
import com.comsol.model.*
import com.comsol.model.util.*

m = mphload('D:/ZJU/PROJECT/2026-07-02-qoder-engine/COMSOL/livelink_model.mph');

% 先尝试访问已有的 int2 的所有属性
fprintf('\n[props] === existing int2 properties ===\n');
int2 = m.func('int2');
fprintf('[props] int2 class: %s\n', class(int2));

% 试用 Java reflection 列出所有方法
try
    methods_list = methods(int2);
    fprintf('[props] int2 methods (%d):\n', length(methods_list));
    for i = 1:length(methods_list)
        fprintf('  %s\n', methods_list{i});
    end
catch ME
    fprintf('[props] methods() failed: %s\n', ME.message);
end

% 列出 props（用 Java 的 introspect）
try
    % ModelEntity 有 props() method?
    props = m.func('int2').props;
    fprintf('[props] props() class: %s\n', class(props));
catch ME
    fprintf('[props] props failed: %s\n', ME.message);
end

% 通过 .mph 模型本身的 introspection
fprintf('\n[props] === create new interpolation ===\n');
try
    m.func.create('int2_new', 'Interpolation');
    new_int = m.func('int2_new');
    fprintf('[props] new int2 class: %s\n', class(new_int));
    fprintf('[props] new int2 methods:\n');
    new_methods = methods(new_int);
    for i = 1:length(new_methods)
        m_name = new_methods{i};
        % 只列 set/get 相关的
        if startsWith(m_name, 'set') || startsWith(m_name, 'get') || startsWith(m_name, 'has')
            fprintf('  %s\n', m_name);
        end
    end
catch ME
    fprintf('[props] create failed: %s\n', ME.message);
end

% 尝试 set('table', cell_of_strings) —— 即把数据每行一个字符串
fprintf('\n[props] === try table with cell of formatted strings ===\n');
try
    rows = {'0 0 0 1.0', '0.1 0 0 2.0', '0.2 0 0 3.0'};
    m.func('int2_new').set('table', rows);
    fprintf('[props] cell of row-strings: OK\n');
catch ME
    fprintf('[props] cell of row-strings FAIL: %s\n', ME.message);
end

% 尝试 set('table', string_matrix) —— cell of cells
try
    rows = {'0', '0', '0', '1.0'; '0.1', '0', '0', '2.0'};
    m.func('int2_new').set('table', rows);
    fprintf('[props] 2D string cell: OK\n');
catch ME
    fprintf('[props] 2D string cell FAIL: %s\n', ME.message);
end

% 尝试 set('table', numeric) 用 cellstr
try
    num = [0 0 0 1.0; 0.1 0 0 2.0; 0.2 0 0 3.0];
    str_matrix = cellstr(num2str(num, '%.6f'));
    fprintf('[props] cellstr preview: '); disp(str_matrix(1));
    m.func('int2_new').set('table', str_matrix);
    fprintf('[props] cellstr column: OK\n');
catch ME
    fprintf('[props] cellstr column FAIL: %s\n', ME.message);
end

% 尝试从文件加载
fprintf('\n[props] === try file source ===\n');
try
    csv_content = '0 0 0 1.0\n0.1 0 0 2.0\n0.2 0 0 3.0\n';
    fid = fopen('D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/list_props/test.csv', 'w');
    fwrite(fid, csv_content);
    fclose(fid);
    m.func('int2_new').set('tablename', 'data');
    m.func('int2_new').set('data', 'D:/ZJU/PROJECT/2026-07-02-qoder-engine/engine/sdk/forward_pipeline/.e2e_runs/hollow_sphere/list_props/test.csv');
    fprintf('[props] file source via data: OK\n');
catch ME
    fprintf('[props] data FAIL: %s\n', ME.message);
end

clearvars m;
fprintf('\n[props] DONE\n');
