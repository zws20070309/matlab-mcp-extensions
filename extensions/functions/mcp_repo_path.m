function p = mcp_repo_path(repoRoot, relp)
%MCP_REPO_PATH Resolve a caller-supplied path against the repository root.
%   Relative paths ALWAYS mean "relative to repoRoot", never "relative to the
%   session's current folder". Using exist() to decide instead is unsafe here:
%   exist('tools','dir') searches the whole MATLAB path (2600+ entries on this
%   host) and answered that a folder called 'tools' exists, which made a step
%   path silently resolve against the MATLAB startup folder - a wrong addpath and a
%   wrong target file, both without an error.
p = '';
relp = strtrim(mcp_str(relp));
if isempty(relp)
    return
end
relp = strrep(relp, '/', filesep());
if numel(repoRoot) > 1 && repoRoot(2) == ':'
    root = repoRoot;
else
    root = mcp_str(repoRoot);
end
if (numel(relp) > 1 && relp(2) == ':') || startsWith(relp, [filesep() filesep()])
    p = relp;
elseif ~isempty(root)
    p = fullfile(root, relp);
else
    p = relp;
end
end
