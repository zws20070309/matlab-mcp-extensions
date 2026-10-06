function c = mcp_str(s)
%MCP_STR Coerce an MCP-marshaled argument to a clean char row vector.
%   Normalizes the shapes the server can deliver (string scalar, string
%   array, char row, multi-row char) into a single char row.
%
%   Multi-row char arrays must be joined ROW-wise with an explicit newline.
%   The previous build used s(:).' which flattens COLUMN-major, so a 2-row
%   argument 'ab'/'cd' came out as 'acbd' (verified live). Trailing padding
%   spaces are kept because they are part of the delivered array.

c = '';
try
    if isstring(s)
        if numel(s) <= 1
            s = char(s);
        else
            parts = cell(numel(s), 1);
            for k = 1:numel(s)
                parts{k} = char(s(k));
            end
            s = strjoin(parts, newline);
        end
    end
    if ischar(s)
        if size(s, 1) > 1
            rows = cell(size(s, 1), 1);
            for k = 1:size(s, 1)
                rows{k} = s(k, :);
            end
            s = strjoin(rows, newline);
        else
            s = s(:).';
        end
        s(s == char(0)) = []; % strip NUL padding only
        c = s;
    end
catch
    c = '';
end
end
