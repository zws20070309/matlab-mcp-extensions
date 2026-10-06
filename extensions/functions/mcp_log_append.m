function mcp_log_append(f, line)
%MCP_LOG_APPEND Append one line, opening and closing the file every time.
%   Deliberately not a cached handle: long certification runs are interrupted,
%   killed or outlived by their client, and a buffered handle loses everything
%   since the last flush (measured: a z157 driver wrote its results only at the
%   end and 550 s of work was unrecoverable; the z158 per-line version returned
%   everything within 30 s). One fopen/fwrite/fclose per event is cheap and makes
%   each line durable the moment it is produced.
fid = fopen(f, 'a');
if fid < 0
    return
end
try
    fwrite(fid, unicode2native([line char(10)], 'UTF-8'));
catch
    fwrite(fid, line);
end
fclose(fid);
end
