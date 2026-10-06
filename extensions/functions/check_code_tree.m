function check_code_tree(rootPath, pattern, minSeverity)
%CHECK_CODE_TREE Lint an entire source tree in one call.
%   rootPath: absolute folder (or a single .m file).
%   pattern : include pattern for dir(), e.g. "*.m" ('' = all .m).
%   minSeverity: 'error'|'warning'|'info' - the cutoff for LISTING individual
%             messages; everything is still counted. '' = 'info'.
%   WHY: check_matlab_code covers one file per call, so a project with dozens of
%   sources costs one round trip each. This walks the tree and aggregates.
if nargin < 3, minSeverity = ''; end
if nargin < 2, pattern = ''; end
mcp_tool_log('check_code_tree', mcp_str(rootPath));
rootPath = mcp_str(rootPath);
if isempty(rootPath) || exist(rootPath, 'file') == 0
    error('check_code_tree:notFound', '[check_code_tree:notFound] nothing at %s', rootPath);
end
pattern = mcp_str(pattern);
if isempty(pattern)
    pattern = '*.m';
end
if exist(rootPath, 'dir') == 7
    files = mcp_walk(rootPath, pattern);
else
    files = {rootPath};
end
sev = lower(strtrim(mcp_str(minSeverity)));
if isempty(sev), sev = 'info'; end
rank = struct('error', 3, 'warning', 2, 'info', 1);
if ~isfield(rank, sev)
    error('check_code_tree:badSeverity', '[check_code_tree:badSeverity] minSeverity must be error|warning|info, got %s', sev);
end
tot = struct('error', 0, 'warning', 0, 'info', 0);
shown = 0;
nfile = 0;
nfault = 0;
fprintf('checking %d file(s) under %s\n', numel(files), rootPath);
for k = 1:numel(files)
    f = files{k};
    nfile = nfile + 1;
    try
        msg = checkcode(f);
    catch e
        fprintf('CHECKCODE_FAIL %s : %s\n', f, e.identifier);
        continue
    end
    if isempty(msg)
        continue
    end
    nfault = nfault + 1;
    cnt = struct('error', 0, 'warning', 0, 'info', 0);
    % checkcode in struct form exposes only message, fix, line and column - there
    % is no severity field (verified with fieldnames). Severity below is therefore
    % classified from the message text by keyword; that heuristic is stated here
    % rather than presented as the grading MATLAB itself applies.
    for j = 1:numel(msg)
        d = strtrim(replace(char(string(msg(j).message)), newline, ' '));
        s = classify(d);
        tot.(s) = tot.(s) + 1;
        cnt.(s) = cnt.(s) + 1;
        if rank.(s) >= rank.(sev) && shown < 200
            shown = shown + 1;
            fprintf('  %-7s %s:%d  %s\n', s, strrep(f, '\', '/'), msg(j).line, d(1:min(140, numel(d))));
        end
    end
    fprintf('FILE %-90s error=%d warning=%d info=%d\n', strrep(f, '\', '/'), ...
        cnt.error, cnt.warning, cnt.info);
end
fprintf('TOTAL files=%d with_issues=%d error=%d warning=%d info=%d\n', ...
    nfile, nfault, tot.error, tot.warning, tot.info);
if tot.error > 0
    fprintf('VERDICT: %d error-level finding(s) - fix before running anything\n', tot.error);
elseif tot.warning > 0
    fprintf('VERDICT: no errors; %d warnings (style or latent bugs)\n', tot.warning);
else
    fprintf('VERDICT: clean\n');
end
if shown >= 200
    fprintf('(listing capped at 200 messages; totals above are complete)\n');
end
end

function s = classify(msgText)
%CLASSIFY Keyword severity, because checkcode exposes no severity in struct form.
t = lower(msgText);
errKeys = {'parse error', 'invalid syntax', 'syntax error', 'error', 'unrecognized', ...
           'unable', 'not supported', '解析错误', '无效', '语法', '错误', '无法'};
warnKeys = {'possibly', 'might', 'could', 'unused', 'duplicate', 'deprecated', ...
            'recommend', 'should', 'avoid', '隐藏', '建议', '未使用', '过时', '可能'};
s = 'info';
for k = 1:numel(errKeys)
    if contains(t, lower(errKeys{k}))
        s = 'error';
        return
    end
end
for k = 1:numel(warnKeys)
    if contains(t, lower(warnKeys{k}))
        s = 'warning';
        return
    end
end
end
