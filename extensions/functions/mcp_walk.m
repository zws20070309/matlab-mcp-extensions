function files = mcp_walk(rootPath, pattern, maxDepth)
%MCP_WALK Recursive file list (files only, no directories).
%   pattern: dir() style include pattern, '' or '*' = everything.
%   maxDepth: recursion cap (default 24) - Windows junctions and symlink loops
%   are real on this host and an unbounded walk hangs the session.
%
%   The file glob and the folder recursion are deliberately TWO passes. Listing
%   dir(fullfile(root, pattern)) only yields the entries that match at THAT
%   level, so recursing through it (which an earlier version did) silently
%   returns zero files for any nested tree: tests/unit/test_x.m is invisible to
%   a 'test_*.m' listing of tests/. A discovery count of 0 reads as "no tests"
%   instead of "walk broken", which is the worst possible failure mode for a
%   certification tool, so the fix is structural, not a warning message.
if nargin < 2, pattern = ''; end
if nargin < 3, maxDepth = 24; end
rootPath = mcp_str(rootPath);
if isempty(pattern)
    pattern = '*';
end
files = {};
if exist(rootPath, 'dir') ~= 7
    if exist(rootPath, 'file') == 2
        files = {rootPath};
    end
    return
end
files = walk_here(rootPath, pattern, maxDepth);
end

function files = walk_here(rootPath, pattern, depth)
files = {};
d = dir(fullfile(rootPath, pattern));
for k = 1:numel(d)
    if d(k).isdir
        continue
    end
    files{end+1} = fullfile(d(k).folder, d(k).name); %#ok<AGROW>
end
if depth <= 1
    return
end
dd = dir(rootPath);
for k = 1:numel(dd)
    nm = dd(k).name;
    if ~dd(k).isdir || strcmp(nm, '.') || strcmp(nm, '..') || startsWith(nm, '.')
        continue
    end
    sub = walk_here(fullfile(rootPath, nm), pattern, depth - 1);
    files = [files, sub]; %#ok<AGROW>
end
end
