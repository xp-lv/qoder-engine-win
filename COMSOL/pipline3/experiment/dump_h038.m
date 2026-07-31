function dump_h038()
  % Dump H038 result.mat fields to a text file for extraction
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
  fid = fopen('data/results/h038_dump.txt', 'w');
  for i = 1:numel(out)
    fprintf(fid, '%s\n', out{i});
  end
  fclose(fid);
  disp('DUMP_DONE');
end
