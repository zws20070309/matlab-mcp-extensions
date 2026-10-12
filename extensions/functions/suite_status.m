function suite_status(runId, optsJson)
%SUITE_STATUS Read a certification run from disk and RECOMPUTE its accounts.
%   runId    : the run to inspect ('' or 'last' lists recent runs instead).
%   optsJson : {"logDir":"", "tail":6, "checkTree":true, "filePattern":"test_*.m"}
%
%   Two reasons this is a separate tool rather than "read the last line":
%   * one certification spans several resumed suite_run calls, and the final
%     COVERAGE/CERTIFIED line describes only the last round. Accounts are therefore
%     recomputed here from every END record, keeping each file's LAST record.
%   * a log without a source digest cannot later prove which tree it certified, so the
%     TREE= digest written at start is compared against the tree as it is now.
%   And the one thing stated explicitly: if this tool answered, the MATLAB session is
%   idle, so a run with no verdict line was interrupted, not slow.
if nargin < 1, runId = ''; end
if nargin < 2, optsJson = ''; end
runId = strtrim(mcp_str(runId));
o = struct();
if ~isempty(strtrim(mcp_str(optsJson)))
    try
        o = jsondecode(mcp_str(optsJson));
    catch e
        error('suite_status:badOpts', '[suite_status:badOpts] %s', e.message);
    end
end
logDir = fullfile(mcp_ext_root(), 'suite_logs');
if isfield(o, 'logDir'), logDir = mcp_str(o.logDir); end
tailN = mcp_num(maybeField(o, 'tail'), 6);
if ~isfinite(tailN) || tailN < 0, tailN = 6; end
checkTree = true;
if isfield(o, 'checkTree'), checkTree = truthy(o.checkTree); end
pat = 'test_*.m';
if isfield(o, 'filePattern'), pat = mcp_str(o.filePattern); end
mcp_tool_log('suite_status', sprintf('runId=%s', runId));
if ~exist(logDir, 'dir')
    fprintf('no suite log directory at %s (suite_run creates it on first use)\n', logDir);
    return
end
if isempty(runId) || strcmpi(runId, 'last')
    list_runs(logDir);
    return
end
logPath = fullfile(logDir, ['suite_' runId '.log']);
if exist(logPath, 'file') ~= 2
    fprintf('NOT FOUND: %s\n', logPath);
    fprintf('run suite_status("") to list available run ids.\n');
    return
end
raw = mcp_read_text(logPath);
lines = regexp(raw, '\r?\n', 'split');
lines = lines(~cellfun(@isempty, lines));
d = dir(logPath);
silence = (now - d.datenum) * 86400;
disk = NaN;
logCase = NaN;
expFiles = NaN;
testsDir = '';
repo = '';
dgRun = '';
p0 = NaN;
runLine = '';
for k = 1:numel(lines)
    if startsWith(lines{k}, ['RUN|' runId '|'])
        runLine = lines{k};
        break
    end
end
disk = kvnum(runLine, 'DISK=');
expFiles = kvnum(runLine, 'EXPECT_FILES=');
logCase = kvnum(runLine, 'CASES_EXPECT=');
p0 = kvnum(runLine, 'PID=');
testsDir = kvstr(runLine, 'tests=');
repo = kvstr(runLine, 'repo=');
dgRun = kvstr(runLine, 'TREE=');
verdict = '';
for k = numel(lines):-1:1
    s = lines{k};
    if startsWith(s, ['CERTIFIED|' runId '|']) || startsWith(s, ['NOT_CERTIFIED|' runId '|'])
        verdict = s;
        break
    end
end
unfinished = in_flight(raw, runId);
% recompute the accounts from the whole log, against what is on disk right now
rels = {};
if ~isempty(testsDir) && exist(testsDir, 'dir') == 7
    rels = cellfun(@(p) mcp_rel(p, testsDir), mcp_walk(testsDir, pat), 'UniformOutput', false);
end
rc = suite_recount(logPath, runId, rels);
fprintf('runId:   %s   %s (%d bytes, %d line(s), %.0f s since last write)\n', ...
    runId, logPath, d.bytes, numel(lines), silence);
if ~isnan(disk)
    fprintf('planned: DISK=%d files  expect_files=%s  cases_expect=%s  pattern=%s\n', ...
        disk, num2s(expFiles), num2s(logCase), pat);
end
fprintf(['recount: files_green=%d/%d seen  cases=%d  fail_files=%d  inc=%d  ' ...
    'not_run=%d  rounds=%d  mutated=%d\n'], rc.filesPass, rc.filesSeen, rc.casesTotal, rc.filesBad, ...
    rc.incs, numel(rc.missing), rc.rounds, rc.mutated);
if ~isempty(rc.lastDigest)
    if checkTree && ~isempty(repo) && exist(repo, 'dir') == 7
        dgNow = mcp_tree_hash(repo);
        fprintf('tree:      certified=%s%s now=%s -> %s\n', rc.lastDigest, ...
            tern(rc.nDigests > 1, sprintf(' (+%d earlier)', rc.nDigests - 1), ''), dgNow, ...
            tern(strcmp(rc.lastDigest, dgNow), 'SAME', 'CHANGED (this log does not describe the current tree)'));
        if rc.nDigests > 1
            fprintf('           MULTI_TREE: green files span %d round digests, so no single tree was certified end to end.\n', rc.nDigests);
        end
    else
        fprintf('tree:      certified=%s in %d distinct round digest(s) (pass checkTree with a valid repo to compare)\n', ...
            rc.lastDigest, rc.nDigests);
    end
end
if isempty(verdict)
    fprintf('verdict:   NONE - run did not reach its end\n');
else
    fprintf('verdict:   %s\n', oneLine(verdict, 300));
end
if ~isempty(rc.nonGreen)
    fprintf('not green (%d):\n', numel(rc.nonGreen));
    for k = 1:min(8, numel(rc.nonGreen))
        fprintf('  %s\n', rc.nonGreen{k});
    end
    if numel(rc.nonGreen) > 8
        fprintf('  ... (%d more, all in the log)\n', numel(rc.nonGreen) - 8);
    end
end
if ~isempty(unfinished)
    fprintf('IN FLIGHT at last write: %s\n', strjoin(unfinished, ', '));
end
if isempty(verdict)
    fprintf('LIVENESS: this session is idle and answered, so no suite_run is running here.\n');
    fprintf('          a missing verdict = INTERRUPTED, not slow.\n');
    h = mcp_host_stats(false);
    if p0 > 0 && p0 == h.pid
        fprintf('          started by this session (pid %g) - resume with the same runId.\n', p0);
    elseif p0 > 0
        fprintf('          started by pid %g, this session is %g -> another (possibly dead) session.\n', p0, h.pid);
    end
end
if ~isempty(rc.missing)
    fprintf('next: suite_run("%s", {"runId":"%s","budgetSec":45}) - it skips the %d finished file(s).\n', ...
        repo, runId, rc.filesPass + rc.filesInc);
end
if tailN > 0
    evd = lines(~cellfun(@isempty, regexp(lines, ...
        ['^(COVERAGE|CERTIFIED|NOT_CERTIFIED|PROGRESS|RUNERR)\|' regexpescape(runId) '\|'], 'once')));
    if ~isempty(evd)
        % Without this header the raw evidence records (same two-space indent as
        % the not-green list above) read as extra not-green files (reproduced
        % 2026-10-11: COVERAGE/NOT_CERTIFIED lines mistaken for file results).
        fprintf('log tail (last %d evidence record(s)):\n', min(tailN, numel(evd)));
    end
    for k = max(1, numel(evd) - tailN + 1):numel(evd)
        fprintf('  %s\n', oneLine(evd{k}, 300));
    end
end
end

% ------------------------------------------------------------------------
function u = in_flight(raw, runId)
b = regexp(raw, ['^BEGIN\|' regexpescape(runId) '\|([^\r\n]+)'], 'tokens');
e = regexp(raw, ['^END\|' regexpescape(runId) '\|([^|]+)\|'], 'tokens');
begun = cellfun(@(t) t{1}, b, 'UniformOutput', false);
ended = cellfun(@(t) t{1}, e, 'UniformOutput', false);
u = setdiff(begun, ended, 'stable');
end

function v = field_of(txt, pattern)
v = '';
tok = regexp(txt, [pattern '([^|\r\n]+)'], 'tokens', 'once');
if ~isempty(tok), v = strtrim(tok{1}); end
end

function v = kvstr(line, tag)
v = '';
if isempty(line), return; end
tok = regexp(line, [regexpescape(tag) '([^|\r\n]+)'], 'tokens', 'once');
if ~isempty(tok), v = strtrim(tok{1}); end
end

function n = kvnum(line, tag)
n = NaN;
s = kvstr(line, tag);
if isempty(s) || strcmp(s, 'n/a'), return; end
n = str2double(s);
end

function list_runs(logDir)
fl = dir(fullfile(logDir, 'suite_*.log'));
if isempty(fl)
    fprintf('no runs recorded in %s yet\n', logDir);
    return
end
[~, im] = sort([fl.datenum], 'descend');
fprintf('runs in %s (newest first, up to 15):\n', logDir);
for k = im(1:min(15, numel(im)))
    d = fl(k);
    rid = strrep(strrep(d.name, 'suite_', ''), '.log', '');
    txt = mcp_read_text(fullfile(logDir, d.name));
    nEnd = numel(regexp(txt, ['^END\|' regexpescape(rid) '\|'], 'once'));
    v = field_of(txt, ['^NOT_CERTIFIED\|' regexpescape(rid) '\|']);
    if isempty(v), v = field_of(txt, ['^CERTIFIED\|' regexpescape(rid) '\|ALL_GREEN']); end
    if isempty(v), v = 'no verdict (interrupted or running)'; end
    fprintf('  %-28s END=%3d  %s  %s\n', rid, nEnd, ...
        char(datetime(d.datenum, 'ConvertFrom', 'datenum', 'Format', 'MM-dd HH:mm')), ...
        oneLine(v, 140));
end
fprintf('pass a runId to suite_status for the recomputed accounts.\n');
end

function s = maybeField(s0, f)
if isstruct(s0) && isfield(s0, f), s = s0.(f); else, s = []; end
end

function s = num2s(v)
if isempty(v) || ~isfinite(v)
    s = 'n/a';
else
    s = sprintf('%g', v);
end
end

function out = tern(c, a, b)
if c, out = a; else, out = b; end
end

function tf = truthy(v)
if isempty(v)
    tf = false;
elseif islogical(v) || isnumeric(v)
    tf = any(double(v(:)) ~= 0);
else
    tf = any(strcmp(lower(strtrim(char(string(v)))), {'1', 'true', 'yes', 'on'}));
end
end

function s = mcp_rel(p, base)
p = strrep(mcp_str(p), '\', '/');
b = strrep(mcp_str(base), '\', '/');
if numel(p) > numel(b) && strcmpi(p(1:numel(b)), b)
    s = regexprep(p(numel(b) + 1:end), '^[/\\]+', '');
    s = strrep(s, '/', filesep());
else
    s = [filesep() p];
end
end

function s = regexpescape(s0)
 specials = {'\','|','.','^','$','[',']','(',')','+','*','?','{','}'};
s = s0;
for k = 1:numel(specials)
    s = strrep(s, specials{k}, ['\' specials{k}]);
end
end

function s = oneLine(v, n)
s = strtrim(strrep(char(string(v)), newline, ' '));
if numel(s) > n
    s = [s(1:n) '...'];
end
end
