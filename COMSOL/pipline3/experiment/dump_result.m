function dump_result(exp_id)
%DUMP_RESULT 通用结果 dump 工具（P1-H039 维护：泛化 dump_h038，消除每轮手动重命名）
%
%   读取 data/results/inversion_complex_result.mat，将标量/逻辑/字符字段
%   以 "field = value" 形式写入 data/results/<exp_id>_dump.txt；大数组以
%   "[numeric numel=N]" 摘要输出（与 dump_h038.m 输出格式完全等价）。
%
%   用法：
%     dump_result('h039')     % -> data/results/h039_dump.txt
%     dump_result()           % -> data/results/last_dump.txt
%
%   设计：本工具取代 dump_h038.m（其输出文件名硬编码 'h038'，复用到 H039/
%   后续轮次时需手动重命名）。仅把硬编码 'h038' 替换为可选 exp_id 参数，
%   字段遍历/格式化逻辑保持不变，确保下游解析脚本无感切换。
%
%   注意：需在 pipline_adjoint 根目录（cwd）下调用，与 run_inversion_complex
%         的 save 路径 (p.dir_result) 对齐。

  if nargin < 1 || isempty(exp_id)
    exp_id = 'last';
  end

  S = load('data/results/inversion_complex_result.mat');
  fn = fieldnames(S);
  r = S.(fn{1});
  rf = fieldnames(r);
  out = {};
  for i = 1:numel(rf)
    v = r.(rf{i});
    if isnumeric(v) && numel(v) <= 20
      out{end+1} = sprintf('%s = %s', rf{i}, mat2str(v, 6));
    elseif islogical(v)
      out{end+1} = sprintf('%s = %s', rf{i}, mat2str(v));
    elseif ischar(v)
      out{end+1} = sprintf('%s = %s', rf{i}, v);
    else
      out{end+1} = sprintf('%s = [numeric numel=%d]', rf{i}, numel(v));
    end
  end

  out_path = sprintf('data/results/%s_dump.txt', exp_id);
  fid = fopen(out_path, 'w');
  for i = 1:numel(out)
    fprintf(fid, '%s\n', out{i});
  end
  fclose(fid);
  fprintf('DUMP_DONE -> %s\n', out_path);
end
