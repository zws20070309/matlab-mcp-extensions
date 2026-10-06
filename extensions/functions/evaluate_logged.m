function evaluate_logged(code, codeFile)
%EVALUATE_LOGGED Evaluate MATLAB code with full output captured to a file.
%   code:     MATLAB statements, executed in the base workspace exactly like
%             the built-in evaluate_matlab_code. For multi-line code either
%             replace every line break with the token @@NL@@ (see
%             mcp_code_arg), or prefer codeFile.
%   codeFile: absolute path to a UTF-8 .m-style text file holding the code;
%             takes precedence over code when non-empty.
%   The command-window output is captured with evalc and written to
%   extensions/exports/eval_<timestamp>.log; only the log path, its size and
%   a tail preview are printed, so results longer than the client's output
%   truncation limit stay fully readable via the returned path. On evaluation
%   errors the log file is STILL written (everything printed before the fault is
%   kept, plus the report) and the error is re-raised as
%   evaluate_logged:evalFailed with the log path inside its message.
%   Note: diary cannot be used here - inside a server-executed tool the
%   command-window output stream is redirected at the engine level, and
%   diary only sees the input echo (verified empirically), so the capture
%   must happen inside MATLAB via evalc.

if nargin < 1, code = ''; end
if nargin < 2, codeFile = ''; end
code = mcp_code_arg(code, 'evaluate_logged');
codeFile = mcp_str(codeFile);
if ~isempty(codeFile)
    if ~exist(codeFile, 'file')
        error('evaluate_logged:fileNotFound', '[evaluate_logged:fileNotFound] codeFile not found: %s', codeFile);
    end
    fid = fopen(codeFile, 'r', 'n', 'UTF-8');
    if fid < 0
        error('evaluate_logged:readFailed', '[evaluate_logged:readFailed] Cannot read codeFile: %s', codeFile);
    end
    cr = onCleanup(@() mcp_fclose_quiet(fid));
    code = char(fread(fid, '*char').');
    fclose(fid);
    cr = []; %#ok<NASGU> % destroy the onCleanup so it will not close again
end
if isempty(code)
    error('evaluate_logged:badArgs', '[evaluate_logged:badArgs] Provide a non-empty code string or codeFile path');
end
outDir = fullfile(mcp_ext_root(), 'exports');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
logFile = fullfile(outDir, sprintf('eval_%s.log', ...
    char(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))));

mcp_tool_log('evaluate_logged', sprintf('code=%d chars codeFile=%s', numel(code), ...
    tern(isempty(codeFile), 'yes', 'no')));

S = struct('c', code); %#ok<NASGU> % referenced by the evalc string below
% The previous build let the error escape evalc, which DISCARDS everything the
% run had already printed. That cost real time during this QA session: a 30-line
% diagnostic whose last line failed returned nothing, and the whole probe had to
% be re-run (three times in one hour). So the user code is executed inside a
% try/catch that only RECORDS the failure - evalc therefore keeps every byte
% printed up to the fault - the log is written, and the error is re-raised
% afterwards with the log path inside its message.
try
    evalin('base', 'clear mcpEvalErrId mcpEvalErrMsg');
catch
end
NL = char(10);
wrapped = ['try' NL 'evalin(''base'', S.c);' NL 'catch ME' NL ...
    'assignin(''base'', ''mcpEvalErrId'', ME.identifier);' NL ...
    'assignin(''base'', ''mcpEvalErrMsg'', getReport(ME, ''basic''));' NL 'end'];
captured = evalc(wrapped);
hadErr = evalin('base', 'exist(''mcpEvalErrId'', ''var'')') > 0;
eid = '';
emsg = '';
if hadErr
    eid = char(evalin('base', 'mcpEvalErrId'));
    emsg = strtrim(char(evalin('base', 'mcpEvalErrMsg')));
    try
        evalin('base', 'clear mcpEvalErrId mcpEvalErrMsg');
    catch
    end
end
fid = fopen(logFile, 'w');
if fid < 0
    error('evaluate_logged:writeFailed', '[evaluate_logged:writeFailed] Cannot create log file: %s', logFile);
end
c = onCleanup(@() mcp_fclose_quiet(fid));
fwrite(fid, captured);
if hadErr
    fwrite(fid, [NL '===== evaluate_logged re-raised this error =====' NL emsg NL]);
end
fclose(fid);
c = []; %#ok<NASGU> % destroy the onCleanup so it will not close again
if hadErr
    % Newlines are stripped from a tool result by the transport, so the report is
    % flattened here and the full text is left in the log file instead.
    error('evaluate_logged:evalFailed', ...
        '[evaluate_logged:evalFailed] %s :: %s | partial output (%d bytes) saved to %s', ...
        eid, strtrim(strrep(emsg, NL, ' ')), numel(captured), logFile);
end

fprintf('evaluate_logged: full output written to %s (%d bytes)\n', logFile, numel(captured));
lines = regexp(captured, '\r?\n', 'split');
if numel(lines) > 1 && isempty(lines{end})
    lines(end) = [];
end
first = max(1, numel(lines) - 40 + 1);
fprintf('--- last %d line(s) ---\n%s\n', numel(lines) - first + 1, ...
    strjoin(lines(first:end), newline));
end

function out = tern(cond, a, b)
if cond, out = a; else, out = b; end
end

function mcp_fclose_quiet(fid)
try
    if fid > 0
        fclose(fid);
    end
catch
end
end
