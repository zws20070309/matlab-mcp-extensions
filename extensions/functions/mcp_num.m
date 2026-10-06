function v = mcp_num(x, dflt)
%MCP_NUM Normalize an optional numeric MCP argument.
%   The bridge delivers a JSON number as a double and an omitted-but-required
%   argument as a 1x1 empty string scalar, so emptiness MUST be evaluated after
%   mcp_str (the get_variable lesson of 2026-09-19: isempty("") is false for a
%   1x1 string scalar, so the default never applied).
%   Returns dflt when the argument is missing, empty or unparsable.
if nargin < 2
    dflt = [];
end
v = dflt;
if nargin < 1
    return
end
if isnumeric(x) || islogical(x)
    if ~isempty(x)
        v = double(x(1));
    end
    return
end
if isstruct(x) || iscell(x)
    return
end
s = mcp_str(x);
if isempty(s)
    return
end
s = strtrim(s);
t = lower(s);
switch t
    case {'inf','-inf','nan','true','false'}
        if strcmp(t,'true'), v = 1; return; end
        if strcmp(t,'false'), v = 0; return; end
        if strcmp(t,'nan'), v = NaN; return; end
        if strcmp(t,'inf'), v = Inf; return; end
        v = -Inf; return
end
nv = str2double(s);
if ~isnan(nv)
    v = nv;
end
end
