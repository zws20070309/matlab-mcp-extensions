function suite_run(repoRoot, optsJson)
%SUITE_RUN Budgeted, resumable, evidence-graded full-suite certification.
%   repoRoot : repository root (its tests/ tree is the subject).
%   optsJson : all optional -
%     {"testsDir":"<repo>/tests", "filePattern":"test_*.m", "shards":["unit","integration"],
%      "budgetSec":45, "maxFiles":0, "perCase":true, "stopOnFail":false,
%      "countsJson":"<repo>/docs/counts.json", "keyFiles":"counts.test_files",
%      "keyCases":"counts.test_functions", "addPaths":["src","app","tools"],
%      "cwd":"", "logDir":"", "runId":"", "clearFunctions":"auto", "force":false,
%      "evidenceDir":""}
%
%   WHAT IT GUARANTEES (each line is a measured trap from the source session):
%   * BUDGET, not timeout: it stops starting new files once budgetSec is spent and
%     returns cleanly with next=<file>, so the caller never has to guess whether a
%     -32603 meant "not executed" and never has to resend a call with side effects.
%   * RESUMABLE: pass the same runId and completed files are skipped, so re-invoking
%     the same call is safe (idempotent) rather than doubling host load.
%   * INCREMENTAL DISK LOG: every BEGIN/END is appended with its own
%     fopen/fwrite/fclose, named with a UTC stamp so a fresh run can never overwrite
%     an earlier block (delete()+reopen() silently ate blocks 1-8 once), and the log
%     lives OUTSIDE the repo unless you ask otherwise.
%   * TWO HARD ACCOUNTS: files on disk vs counts.json, and cases executed vs
%     counts.json, printed as COVERAGE|...|match=0/1. (A missing ".m" in the pattern
%     once turned an all-green run into NOT_ALL_GREEN - the account is computed, not
%     assumed.)
%   * TREE FINGERPRINT at start and end: if the repository changed while the
%     certification ran, the verdict is downgraded - editing files mid-run used to
%     invalidate a run silently.
%   * SCRATCH CWD by default (a temp dir, not the repo), so Simulink caches cannot
%     land in the tree and turn a green suite red.
%   * The verdict marker is printed only when all conditions hold; otherwise
%     NOT_CERTIFIED plus the reasons.
if nargin < 2, optsJson = ''; end
repoRoot = mcp_str(repoRoot);
mcp_tool_log('suite_run', mcp_str(repoRoot));
if isempty(repoRoot) || exist(repoRoot, 'dir') ~= 7
    error('suite_run:badRoot', '[suite_run:badRoot] repoRoot must be an existing folder, got: %s', repoRoot);
end
o = struct();
if ~isempty(strtrim(mcp_str(optsJson)))
    try
        o = jsondecode(mcp_str(optsJson));
    catch e
        error('suite_run:badOpts', '[suite_run:badOpts] %s', e.message);
    end
end
testsDir = fullfile(repoRoot, 'tests');
if isfield(o, 'testsDir')
    tdir = mcp_str(o.testsDir);
    if ~isempty(tdir)
        isAbs = ~isempty(regexp(tdir, '^[a-zA-Z]:', 'once')) || tdir(1) == '\' || tdir(1) == '/';
        if ~isAbs
            tdir = fullfile(repoRoot, tdir);
        end
        testsDir = tdir;
    end
end
if exist(testsDir, 'dir') ~= 7
    error('suite_run:noTests', '[suite_run:noTests] no tests folder at %s', testsDir);
end
pat = 'test_*.m';
if isfield(o, 'filePattern'), pat = mcp_str(o.filePattern); end
budget = mcp_num(maybeField(o, 'budgetSec'), 45);
if ~isfinite(budget) || budget < 5, budget = 45; end
maxFiles = mcp_num(maybeField(o, 'maxFiles'), 0);
perCase = true;
if isfield(o, 'perCase'), perCase = truthy(o.perCase); end
stopOnFail = false;
if isfield(o, 'stopOnFail'), stopOnFail = truthy(o.stopOnFail); end
force = false;
if isfield(o, 'force'), force = truthy(o.force); end

% ---- 1. host gate ------------------------------------------------------
h = mcp_host_stats(false);
if ~force
    if (isfinite(h.freeMB) && h.freeMB < 1500) || (isfinite(h.matlabProcs) && h.matlabProcs > 2)
        error('suite_run:hostGate', ...
            ['[suite_run:hostGate] not starting: %d MATLAB process(es), %d MB free. ' ...
             'Long runs on this host previously cost 1.5 GB and paged for ~70 min. ' ...
             'Clear the extra session or pass force=true.'], ...
            round(h.matlabProcs), round(h.freeMB));
    end
end
% ---- 2. log file (UTC-named, outside the repo by default) --------------
logDir = fullfile(mcp_ext_root(), 'suite_logs');
if isfield(o, 'logDir'), logDir = mcp_str(o.logDir); end
if ~exist(logDir, 'dir'), mkdir(logDir); end
if isfield(o, 'runId') && ~isempty(strtrim(mcp_str(o.runId)))
    runId = mcp_str(o.runId);
else
    runId = sprintf('r%s', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd''T''HHmmss''Z''')));
end
logPath = fullfile(logDir, ['suite_' runId '.log']);
% ---- 3. discovery + the two hard accounts ------------------------------
allFiles = mcp_walk(testsDir, pat);
[~, order] = sort(shardKey(allFiles, testsDir));
allFiles = allFiles(order);
rel = cellfun(@(p) mcp_rel(p, testsDir), allFiles, 'UniformOutput', false);
% An empty discovery is a NO-GO, never a green run: a scoped filePattern that matches
% nothing used to reach the verdict block with 0 files, 0 failures and no counts.json to
% argue with, and printed ALL_GREEN.
if isempty(allFiles)
    error('suite_run:noFiles', ...
        ['[suite_run:noFiles] pattern "%s" matched 0 files under %s. Nothing was ' ...
         'certified; widen the pattern or fix testsDir.'], pat, testsDir);
end
expFiles = NaN;
expCases = NaN;
if isfield(o, 'countsJson') && ~isempty(strtrim(mcp_str(o.countsJson)))
    cj = mcp_str(o.countsJson);
    if exist(cj, 'file') == 2
        txt = mcp_read_text(cj);
        try
            js = jsondecode(txt);
            expFiles = mcp_num(dotget(js, maybeFieldD(o, 'keyFiles', 'counts.test_files')), NaN);
            expCases = mcp_num(dotget(js, maybeFieldD(o, 'keyCases', 'counts.test_functions')), NaN);
        catch e
            mcp_log_append(logPath, [ 'RUNERR|' runId '|counts_json|' e.identifier]);
        end
    end
end
% ---- 4. resume set -----------------------------------------------------
% Only files that ENDED green (PASS or INC) are treated as done. A file whose
% last END said FAIL/ERROR is re-run, so fixing the code and resuming actually
% re-verifies the fixed file instead of inheriting the old red verdict.
doneSet = containers.Map('KeyType', 'char', 'ValueType', 'logical');
if exist(logPath, 'file') == 2
    prev = regexp(mcp_read_text(logPath), '\r?\n', 'split');
    for k = 1:numel(prev)
        tok = regexp(prev{k}, ['^END\|' runId '\|([^|]+)\|([A-Z]+)\|'], 'tokens', 'once');
        if ~isempty(tok) && any(strcmp(char(tok{2}), {'PASS', 'INC'}))
            doneSet(char(tok{1})) = true;
        end
    end
end
% ---- 5. code freshness + paths + scratch cwd --------------------------
oldPwd = pwd;
cleanUp = onCleanup(@() restore_dir(oldPwd));
cwd = fullfile(tempdir, sprintf('mcp_suite_%s', runId));
if isfield(o, 'cwd') && ~isempty(strtrim(mcp_str(o.cwd))), cwd = mcp_str(o.cwd); end
if ~exist(cwd, 'dir'), mkdir(cwd); end
cd(cwd);
if isfield(o, 'addPaths')
    ap = o.addPaths;
    if ~iscell(ap), ap = cellstr(string(ap)); end
    for k = 1:numel(ap)
        p = mcp_repo_path(repoRoot, ap{k});
        if exist(p, 'dir') == 7
            addpath(genpath(p), '-begin');
        end
    end
end
rehash;
cf = maybeFieldD(o, 'clearFunctions', 'auto');
if strcmp(cf, 'auto')
    if ~isempty(dir(fullfile(repoRoot, 'src', '+*'))) || ~isempty(dir(fullfile(repoRoot, '+*')))
        try, clear functions, catch, end
    end
elseif any(strcmp(cf, {'1', 'true', 'yes'}))
    try, clear functions, catch, end
end
% ---- 6. header + run ---------------------------------------------------
fp0 = tree_fingerprint(repoRoot);
dg0 = mcp_tree_hash(repoRoot);
hdr = sprintf(['RUN|%s|repo=%s|tests=%s|DISK=%d|EXPECT_FILES=%s|CASES_EXPECT=%s|' ...
    'FREE_MB=%s|PROCS=%s|PID=%s|PERCASE=%d|BUDGET=%g|TREE=%s|SRC=%dm|CWD=%s'], runId, repoRoot, testsDir, ...
    numel(allFiles), num2s(expFiles), num2s(expCases), num2s(h.freeMB), num2s(h.matlabProcs), ...
    num2s(h.pid), perCase, budget, dg0, fp0.files, cwd);
mcp_log_append(logPath, hdr);
fprintf('%s\n', hdr);
filesDone = 0; casesRun = 0; failed = 0; incomplete = 0; skipped = 0;
firstFail = '';
tAll = tic;
stopEarly = false;
for k = 1:numel(allFiles)
    if maxFiles > 0 && filesDone >= maxFiles, break; end
    if toc(tAll) > budget
        mcp_log_append(logPath, sprintf('PROGRESS|%s|stopped=budget|next=%s', runId, rel{k}));
        fprintf('PROGRESS| stopped=budget|next=%s\n', rel{k});
        stopEarly = true;
        break
    end
    if doneSet.isKey(rel{k})
        skipped = skipped + 1;
        continue
    end
    f = allFiles{k};
    te = tic;
    mcp_log_append(logPath, sprintf('BEGIN|%s|%s', runId, rel{k}));
    [st, nc, nf, ni, msg] = run_one(f, perCase);
    el = toc(te);
    casesRun = casesRun + nc;
    failed = failed + nf;
    incomplete = incomplete + ni;
    if nf > 0 && isempty(firstFail)
        firstFail = sprintf('%s :: %s', rel{k}, msg);
    end
    mcp_log_append(logPath, sprintf('END|%s|%s|%s|cases=%d|fail=%d|inc=%d|sec=%.1f|%s', ...
        runId, rel{k}, st, nc, nf, ni, el, oneLine(msg, 200)));
    fprintf('END| %s %s cases=%d fail=%d %.1fs\n', rel{k}, st, nc, nf, el);
    filesDone = filesDone + 1;
    if stopOnFail && nf > 0
        mcp_log_append(logPath, sprintf('PROGRESS|%s|stopped=first_failure|file=%s', runId, rel{k}));
        stopEarly = true;
        break
    end
end
restore_dir(oldPwd);
cleanUp = []; %#ok<NASGU>
% ---- 7. accounts + verdict --------------------------------------------
fp1 = tree_fingerprint(repoRoot);
dg1 = mcp_tree_hash(repoRoot);
treeSame = strcmp(dg0, dg1);
% Accounts are recomputed from every END record in the log, not from this round's
% counters: one certification is usually spread over several resumed invocations, and
% the last CERTIFIED line used to report only the cases that the last round executed.
rc = suite_recount(logPath, runId, rel);
accMatch = ~isfinite(expFiles) || expFiles == numel(allFiles);
caseMatch = ~isfinite(expCases) || expCases == rc.casesTotal;
cov = sprintf(['COVERAGE|%s|disk_files=%d|expect_files=%s|round_files=%d|round_skipped=%d|' ...
    'cases_total=%d|cases_expect=%s|files_green=%d/%d|not_run=%d|fail_files=%d|inc=%d|' ...
    'rounds=%d|tree=%s|TREE=%s|TREE_NOW=%s'], runId, numel(allFiles), num2s(expFiles), ...
    filesDone, skipped, rc.casesTotal, num2s(expCases), rc.filesPass, rc.filesSeen, ...
    numel(rc.missing), rc.filesBad, rc.incs, rc.rounds, ...
    tern(treeSame, 'unchanged', 'MUTATED'), dg0, dg1);
mcp_log_append(logPath, cov);
fprintf('%s\n', cov);
reasons = {};
if ~isempty(rc.missing)
    reasons{end+1} = sprintf('NOT_RUN=%d:%s', numel(rc.missing), ...
        strjoin(rc.missing(1:min(3, numel(rc.missing))), ',') ...
        ); %#ok<AGROW>
end
if rc.filesBad > 0 || rc.fails > 0
    reasons{end+1} = sprintf('FAILURES=%d', max(rc.filesBad, 1)); %#ok<AGROW>
end
if ~accMatch
    reasons{end+1} = sprintf('COVERAGE_MISMATCH disk=%d expect=%s', numel(allFiles), num2s(expFiles)); %#ok<AGROW>
end
if ~caseMatch
    reasons{end+1} = sprintf('CASE_MISMATCH total=%d expect=%s', rc.casesTotal, num2s(expCases)); %#ok<AGROW>
end
if ~treeSame
    reasons{end+1} = 'TREE_MUTATED_DURING_RUN'; %#ok<AGROW>
end
if stopEarly
    reasons{end+1} = 'BUDGET_STOPPED'; %#ok<AGROW>
end
if ~isempty(rc.extra)
    reasons{end+1} = sprintf('RUN_NOT_ON_DISK=%d', numel(rc.extra)); %#ok<AGROW>
end
if isfinite(expFiles)
    note = '';
else
    note = ' (no counts.json: file/case accounts NOT proven)';
end
% Resume makes the tree question real: files that passed in an earlier round ran on the
% tree of that round, so a green set spread over k round digests is NOT one certification.
if rc.nDigests > 1
    note = [note sprintf(' [MULTI_TREE=%d: green files were certified on %d different trees]' ...
        , rc.nDigests, rc.nDigests)];
end
% An assumption-filtered case never executed, so counting it toward cases=%d and calling
% the run ALL_GREEN certifies untested code. Measured: 3 integration cases were filtered out
% (files_green=1/2, inc=3) and the verdict still read CERTIFIED|ALL_GREEN|files=2|cases=11.
if rc.incs > 0
    reasons{end+1} = sprintf('INCOMPLETE_CASES=%d (assumption-filtered, never executed)', rc.incs); %#ok<AGROW>
end
if isempty(reasons) && rc.filesSeen > 0
    v = sprintf('CERTIFIED|%s|ALL_GREEN|files=%d|cases=%d%s|TREE=%s', ...
        runId, rc.filesSeen, rc.casesTotal, note, dg0);
elseif isempty(reasons)
    v = sprintf('NOT_CERTIFIED|%s|NO_FILES_DISCOVERED', runId);
else
    v = sprintf('NOT_CERTIFIED|%s|%s', runId, strjoin(reasons, ';'));
end
mcp_log_append(logPath, v);
fprintf('%s\n', v);
fprintf('log: %s\n', logPath);
fprintf('resume with the same runId (pass {"runId":"%s"}); already-OK files are skipped.\n', runId);
if ~isempty(firstFail)
    fprintf('first failure: %s\n', firstFail);
end
if ~isempty(strtrim(note))
    fprintf('WARNING:%s\n', note);
end
if ~treeSame
    fprintf(['WARNING: the tree changed while running (TREE=%s at start, %s at end) - this ' ...
        'certification is void. Archive it as a pre-change measurement only.\n'], dg0, dg1);
end
end

% ------------------------------------------------------------------------
function [st, nc, nf, ni, msg] = run_one(f, perCase)
st = 'PASS';
nc = 0;
nf = 0;
ni = 0;
msg = '';
usedPerCase = false;
try
    % R2025a: matlab.unittest.TestSuite.fromFile returns an ARRAY OF TESTS
    % (numel = number of test cases), and run(test) gives one TestResult. The
    % bare function tests(char) does not accept a file name, so going through
    % TestSuite is what makes per-case logging possible at all.
    sc = matlab.unittest.TestSuite.fromFile(f);
    if perCase && isa(sc, 'matlab.unittest.Test') && numel(sc) > 0
        usedPerCase = true;
        for c = 1:numel(sc)
            nc = nc + 1;
            try
                r = run(sc(c));
                if isa(r, 'matlab.unittest.TestResult')
                    if r.Failed
                        nf = nf + 1;
                        st = 'FAIL';
                        msg = [msg ' ' r.Name ': ' diag_of(r)];
                    elseif r.Incomplete
                        ni = ni + 1;
                        if strcmp(st, 'PASS'), st = 'INC'; end
                    end
                end
            catch e2
                nf = nf + 1;
                st = 'FAIL';
                msg = [msg ' case' num2str(c) ' threw ' e2.identifier];
            end
        end
    else
        r = runtests(f);
        nc = numel(r);
        for c = 1:nc
            if r(c).Failed
                nf = nf + 1;
                st = 'FAIL';
                msg = [msg ' ' r(c).Name ': ' diag_of(r(c))];
            elseif r(c).Incomplete
                ni = ni + 1;
                if strcmp(st, 'PASS'), st = 'INC'; end
            end
        end
    end
catch e
    st = 'ERROR';
    nf = 1;
    msg = [e.identifier ': ' e.message];
end
if ~usedPerCase && perCase
    msg = ['(file-level run; per-case unavailable) ' msg];
end
msg = strtrim(msg);
end

function m = diag_of(t)
m = '';
try
    arr = t.Details.toArray();
    if ~isempty(arr)
        c = arrayfun(@(a) a.Message, arr, 'UniformOutput', false);
        m = strjoin(c, ' / ');
    end
catch
    try
        m = sprintf('%s', t.Name);
    catch
        m = '(no diagnostic)';
    end
end
if isempty(m)
    m = '(no diagnostic)';
end
end

function v = maybeField(s, f)
if isstruct(s) && isfield(s, f), v = s.(f); else, v = []; end
end

function v = maybeFieldD(s, f, d)
v = d;
if isstruct(s) && isfield(s, f)
    v = s.(f);
end
end

function v = dotget(s, path)
v = [];
parts = strsplit(mcp_str(path), '.');
for k = 1:numel(parts)
    if isstruct(s) && isfield(s, parts{k})
        s = s.(parts{k});
    else
        v = [];
        return
    end
end
v = s;
end

function key = shardKey(files, testsDir)
key = strings(numel(files), 1);
for k = 1:numel(files)
    r = mcp_rel(files{k}, testsDir);
    % a cell of delimiters, not [filesep() '/']: as a char vector that is ONE
    % literal delimiter ("\/"), so no split happened, the shard directory came
    % back empty and every file got the same priority
    parts = strsplit(r, {filesep(), '/'});
    parts = parts(~cellfun(@isempty, parts));
    if numel(parts) > 1
        d = parts{1};
    else
        d = '';
    end
    pri = 5;
    if strcmpi(d, 'unit'), pri = 0; end
    if strcmpi(d, 'golden'), pri = 2; end
    if strcmpi(d, 'integration'), pri = 3; end
    if strcmpi(d, 'regression'), pri = 4; end
    key(k) = string(sprintf('%d_%s|%s', pri, d, r));
end
end

function fp = tree_fingerprint(repoRoot)
fp = struct('files', 0, 'bytes', 0, 'newest', 0);
fl = mcp_walk(repoRoot, '*.m');
for k = 1:numel(fl)
    d = dir(fl{k});
    if ~isempty(d)
        fp.files = fp.files + 1;
        fp.bytes = fp.bytes + d.bytes;
        fp.newest = max(fp.newest, d.datenum);
    end
end
end

function restore_dir(p)
try
    cd(p);
catch
end
end

function s = mcp_rel(p, base)
p = strrep(mcp_str(p), '\', '/');
b = strrep(mcp_str(base), '\', '/');
if numel(p) > numel(b) && strcmpi(p(1:numel(b)), b)
    s = p(numel(b) + 1:end);
    % the joining separator must not survive: '\unit\test_x.m' as a relative
    % name shifted the shard sort (an empty first path part) and the resume key
    s = regexprep(s, '^[/\\]+', '');
    s = strrep(s, '/', filesep());
else
    s = [filesep() p];
end
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end

function s = num2s(v)
if isempty(v) || (isnumeric(v) && ~isfinite(v))
    s = 'n/a';
elseif isnumeric(v)
    s = sprintf('%g', v);
else
    s = char(string(v));
end
end

function s = oneLine(v, n)
s = strtrim(strrep(char(string(v)), newline, ' '));
if numel(s) > n
    s = [s(1:n) '...'];
end
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
