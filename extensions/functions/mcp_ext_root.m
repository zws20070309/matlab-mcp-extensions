function root = mcp_ext_root()
%MCP_EXT_ROOT Root folder of the MATLAB MCP extension layer.
%   Derived from this file's own location, so the extension tree can be
%   cloned to any folder without editing a hard-coded absolute path.
%   This file lives in <root>/extensions/functions/, hence two fileparts().
%   All extension artifacts (job dirs, exports) live under this folder.
root = fileparts(fileparts(mfilename('fullpath')));
end
