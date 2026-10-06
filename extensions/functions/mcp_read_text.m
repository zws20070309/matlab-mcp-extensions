function txt = mcp_read_text(f)
%MCP_READ_TEXT Read a whole UTF-8 text file as one char row.
%   Returns '' when the file is absent or unreadable: callers use this for
%   optional inputs (a counts.json, an existing log to resume from) and must be
%   able to treat "nothing there yet" as empty rather than as an error.
%   Bytes are decoded explicitly because fread gives numeric doubles; reading
%   them as char() produces mojibake for any non-ASCII content (Chinese paths
%   and text are routine on this host).
txt = '';
if nargin < 1
    return
end
p = mcp_str(f);
if isempty(p) || isfile(p) ~= true
    return
end
fid = fopen(p, 'rb');
if fid < 0
    return
end
% Clearing the onCleanup object is the close: calling fclose here as well makes
% the destructor close a dead handle and raise MATLAB:FileIO:InvalidFid.
cleanup = onCleanup(@() fclose(fid));
raw = fread(fid, Inf, 'uint8=>uint8');
clear cleanup
if isempty(raw)
    return
end
try
    txt = native2unicode(raw(:).', 'UTF-8');
catch
    txt = char(raw(:).');
end
if isa(txt, 'string')
    txt = char(txt);
end
txt = txt(:).';
end
