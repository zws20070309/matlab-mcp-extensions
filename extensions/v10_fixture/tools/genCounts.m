function genCounts()
%GENCOUNTS Plain (non-package) generator, like the repository it imitates.
%   Recomputes test file and test case counts from disk into docs/counts.json.
root = fileparts(fileparts(mfilename('fullpath')));
td = fullfile(root, 'tests');
fl = dir(fullfile(td, '**', 'test_*.m'));
nFiles = 0;
nCases = 0;
for k = 1:numel(fl)
    if fl(k).isdir, continue; end
    nFiles = nFiles + 1;
    txt = fileread(fullfile(fl(k).folder, fl(k).name));
    tok = regexp(txt, 'function\s+\w+\s*\(', 'tokens');
    nCases = nCases + numel(tok);
end
out = struct('generated', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HHmmss''Z''')), ...
    'counts', struct('test_files', nFiles, 'test_functions', nCases));
fid = fopen(fullfile(root, 'docs', 'counts.json'), 'w');
fwrite(fid, jsonencode(out, 'PrettyPrint', true));
fclose(fid);
fprintf('genCounts: files=%d cases=%d\n', nFiles, nCases);
end
