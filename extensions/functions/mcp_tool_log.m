function mcp_tool_log(toolName, detail)
%MCP_TOOL_LOG Append one line to the extension-layer tool call log.
%   The Go server only logs its own built-in tools, so extension tools left no
%   trace at all: during QA the server log contained entries for
%   evaluate_matlab_code / check_matlab_code / run_matlab_file /
%   run_matlab_test_file and nothing for any of the 13 extension tools, which
%   made the argument-corruption bug impossible to trace from logs alone.
%   This gives the extension layer its own audit trail.
%   Best effort: logging must never break the tool that calls it.
if nargin < 2, detail = ''; end
try
    d = fullfile(mcp_ext_root(), 'logs');
    if ~exist(d, 'dir')
        mkdir(d);
    end
    f = fullfile(d, 'tools.log');
    % Keep the file bounded: rotate once past ~2 MiB.
    fi = dir(f);
    if ~isempty(fi) && fi.bytes > 2097152
        movefile(f, fullfile(d, 'tools.log.1'), 'f');
    end
    fid = fopen(f, 'a');
    if fid < 0
        return
    end
    % Explicit UTF-8 for portability. CORRECTION of an earlier note in this file:
    % the garbled Chinese paths seen while inspecting tools.log were NOT written
    % here - the log was already UTF-8 (checked at byte level) and the fault was
    % in file_op's reader, which reinterpreted bytes as chars. Writing the
    % encoding explicitly is still the right thing, but the diagnosis printed in
    % the v8 report is the reader, not this writer.
    line = sprintf('%s\t%s\t%s\n', ...
        char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS')), ...
        toolName, strrep(detail, newline, ' '));
    fwrite(fid, unicode2native(line, 'UTF-8'));
    fclose(fid);
catch
end
end
