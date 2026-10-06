function parts = mcp_split_json(txt)
%MCP_SPLIT_JSON Split a JSON array (or JSON-lines text) into element texts.
%   Why not jsondecode the whole array? A heterogeneous array collapses into a
%   MATLAB struct array (fields get filled with NaN/[]), errors on mixed types,
%   and loses per-element identity - none of which is acceptable when each
%   element is the parameter set of one independent job. This scanner tracks
%   brace/bracket depth and string state and returns each top-level element
%   verbatim, so the worker decodes exactly what the caller wrote.
%   Contract:
%     '[{...},{...}]'      -> 2 elements
%     '{...}\n{...}'       -> 2 elements (JSON lines)
%     '[1,2,3]'            -> '1','2','3'   (caller may wrap primitives)
%     ''                   -> {} (no elements)
parts = {};
txt = strtrim(mcp_str(txt));
if isempty(txt)
    return
end
if txt(1) == '['
    inner = txt(2:end);
    if ~isempty(inner) && inner(end) == ']'
        inner = inner(1:end-1);
    end
    parts = splitTop(inner);
else
    lines = regexp(txt, '\r?\n', 'split');
    for k = 1:numel(lines)
        L = strtrim(lines{k});
        if ~isempty(L)
            parts{end+1} = L; %#ok<AGROW>
        end
    end
end
end

function out = splitTop(s)
out = {};
depth = 0;
inStr = false;
esc = false;
start = 1;
for k = 1:numel(s)
    ch = s(k);
    if inStr
        if esc
            esc = false;
        elseif ch == '\'
            esc = true;
        elseif ch == '"'
            inStr = false;
        end
        continue
    end
    switch ch
        case '"'
            inStr = true;
        case {'{', '['}
            depth = depth + 1;
        case {'}', ']'}
            depth = depth - 1;
        case ','
            if depth == 0
                tok = strtrim(s(start:k-1));
                if ~isempty(tok)
                    out{end+1} = tok; %#ok<AGROW>
                end
                start = k + 1;
            end
    end
end
tail = strtrim(s(start:end));
if ~isempty(tail)
    out{end+1} = tail;
end
if ~isempty(out)
    % Drop a trailing empty artifact produced by a stray comma.
    keep = ~cellfun('isempty', out);
    out = out(keep);
end
end
