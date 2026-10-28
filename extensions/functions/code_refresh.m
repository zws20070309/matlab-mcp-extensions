function code_refresh(path, optsJson)
%CODE_REFRESH Make edited code visible to this session before you trust a result.
%   path     : folder (or .m file) whose code was just edited.
%   optsJson : {"clearFunctions":true|false|"auto", "lint":true}
%   WHY: the source session twice invalidated its own certification because it
%   edited a +package function and then verified against the OLD cached
%   definition. MATLAB caches function files; rehash refreshes the path table,
%   clear functions additionally drops loaded function workspaces (the reliable
%   one for package files, at the cost of reloading on next call). "auto"
%   (default) clears only when the target tree contains a +package or @class
%   folder, i.e. exactly where the stale-cache trap has been observed.
%   Prints only; returns nothing.
if nargin < 2, optsJson = ''; end
o = struct();
if ~isempty(strtrim(mcp_str(optsJson)))
    try
        o = jsondecode(mcp_str(optsJson));
    catch e
        error('code_refresh:badOpts', '[code_refresh:badOpts] %s', e.message);
    end
end
path = mcp_str(path);
mcp_tool_log('code_refresh', mcp_str(path));
if isempty(path) || exist(path, 'file') == 0
    error('code_refresh:notFound', '[code_refresh:notFound] nothing at %s', path);
end
pat = '*.m';
if exist(path, 'dir') == 7
    if isfield(o, 'pattern'), pat = mcp_str(o.pattern); end
    if isempty(pat), pat = '*.m'; end
    files = mcp_walk(path, pat);
    tree = path;
else
    files = {path};
    tree = fileparts(path);
end
pkg = ~isempty(dir(fullfile(tree, '+*'))) || ~isempty(dir(fullfile(tree, '@*')));
doClear = pkg;
if isfield(o, 'clearFunctions')
    v = o.clearFunctions;
    if islogical(v) || isnumeric(v)
        doClear = any(double(v(:)) ~= 0);
    else
        s = lower(strtrim(char(string(v))));
        if any(strcmp(s, {'1', 'true', 'yes'})), doClear = true; end
        if any(strcmp(s, {'0', 'false', 'no'})), doClear = false; end
    end
end
newest = 0;
totalBytes = 0;
for k = 1:numel(files)
    d = dir(files{k});
    if ~isempty(d)
        newest = max(newest, d.datenum);
        totalBytes = totalBytes + d.bytes;
    end
end
rehash;
if doClear
    try
        clear functions;
        fprintf('cleared function cache (package/@class tree detected or requested)\n');
    catch e
        fprintf('clear functions FAILED: %s\n', e.message);
    end
end
fprintf('scanned            : %d file(s) matching "%s" under %s\n', numel(files), pat, tree);
fprintf('total bytes        : %d\n', totalBytes);
if newest > 0
    fprintf('newest mtime       : %s (age %.0f s)\n', ...
        char(datetime(newest, 'ConvertFrom', 'datenum', 'TimeZone', 'local', ...
        'Format', 'yyyy-MM-dd HH:mm:ss')), 86400 * (now - newest));
end
fprintf('rehash             : done\n');
if ~doClear
    fprintf('clear functions    : SKIPPED (no +package/@class tree) - if you edited a package function, pass clearFunctions=true\n');
end
if isfield(o, 'lint')
    % String-aware truthiness: any(double(char)) treated EVERY non-empty
    % string as true, so "lint":"false" switched the lint ON.
    v = o.lint;
    if ischar(v) || isstring(v)
        doLint = any(strcmp(lower(strtrim(char(string(v)))), {'1', 'true', 'yes', 'on'}));
    else
        doLint = any(double(v(:)) ~= 0);
    end
    if doLint
        fprintf('--- lint of the refreshed tree ---\n');
        check_code_tree(tree, '*.m', 'error');
    end
end
end
