function run_tests(testPath)
%RUN_TESTS Run a MATLAB test suite and report a compact structured summary.
%   Unlike piping runtests through the generic tools, test failures do NOT
%   propagate as MCP errors: a failing test is an expected outcome, so this
%   function always returns normally when the suite itself executed, and
%   prints per-failure details. The full framework output is written to
%   extensions/exports/test_<timestamp>.log. Only "runtests could not run
%   at all" (bad path, syntax error in the test file) raises an error.
%   testPath may be a file or folder, exactly like the runtests argument.

if nargin < 1, testPath = ''; end
testPath = mcp_str(testPath);
if isempty(testPath)
    error('run_tests:badArgs', '[run_tests:badArgs] testPath is required');
end
if exist(testPath, 'file') ~= 2 && exist(testPath, 'dir') ~= 7
    error('run_tests:notFound', '[run_tests:notFound] testPath not found: %s', char(testPath));
end
mcp_tool_log('run_tests', testPath);

% A suite usually needs its project root on the search path for +package
% resolution: the test framework does not search the caller's cwd (verified:
% fishsim.* failed from cwd until the project root was added).
% The root used to be inferred only from a parent directory literally named
% "tests", so suites in any other folder (suite2/, verify/, regression/)
% failed with undefined mp.adder-style errors (reproduced 2026-10-11). The
% parent-of-tests convention is kept and generalised: any immediate parent
% of the suite directory that contains +packages or the suite's sibling
% +folders gets added too.
targetDir = testPath;
if exist(testPath, 'file') == 2
    targetDir = fileparts(testPath);
end
[~, targetName] = fileparts(targetDir);
if strcmpi(targetName, 'tests')
    projectRoot = fileparts(targetDir);
    if ~any(strcmp(cellstr(path), projectRoot))
        addpath(projectRoot);
        fprintf('run_tests: added project root to path: %s\n', projectRoot);
    end
else
    % Generalised fallback: add the suite's own directory and, when it sits
    % one level under a root holding +packages, that root as well.
    if ~any(strcmp(cellstr(path), targetDir))
        addpath(targetDir);
    end
    root = fileparts(targetDir);
    pkgs = dir(fullfile(root, '+*'));
    if ~isempty(pkgs) && ~any(strcmp(cellstr(path), root))
        addpath(root);
        fprintf('run_tests: added sibling-package root to path: %s\n', root);
    end
end

% Budget guard (head-of-line blocking prevention, field-proven in session
% 7ac4a2ae): a suite that took >45 s last time will be killed by the ~60 s MCP
% client timeout this time, and the engine keeps running it afterwards. Warn
% before paying that cost again and point at the sharded alternatives.
if exist(testPath, 'file') == 2
    budgetFile = [testPath '.mcp_budget'];
else
    budgetFile = fullfile(targetDir, 'suite.mcp_budget');
end
lastSec = NaN;
if exist(budgetFile, 'file')
    try
        lastSec = str2double(strtrim(fileread(budgetFile)));
    catch
    end
end
if isfinite(lastSec) && lastSec > 45
    fprintf(['BUDGET WARNING: this suite took %.0fs last run; the MCP client times calls out at ~60s ' ...
        'and the engine stays busy afterwards. Prefer suite_run (shards+budgetSec) or ' ...
        'eval_async+job_status for it.\n'], lastSec);
end

t0 = tic;
outDir = fullfile(mcp_ext_root(), 'exports');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
logFile = fullfile(outDir, sprintf('test_%s.log', ...
    char(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))));

S = struct('p', testPath); %#ok<NASGU> % referenced by the evalc expression
% evalc evaluates in this function's scope, so S resolves here; runtests
% does not need base-workspace semantics (tests run in their own contexts).
captured = evalc('results = runtests(S.p);');

fid = fopen(logFile, 'w');
if fid < 0
    error('run_tests:writeFailed', '[run_tests:writeFailed] Cannot create log file: %s', logFile);
end
c = onCleanup(@() mcp_fclose_quiet(fid)); %#ok<NASGU>
fwrite(fid, captured);
fclose(fid);
c = [];

n = numel(results);
passed = nnz([results.Passed]);
failed = nnz([results.Failed]);
incomplete = nnz([results.Incomplete]);
totalSec = sum([results.Duration]);
wallSec = toc(t0);
try
    fid = fopen(budgetFile, 'w');
    if fid > 0
        fprintf(fid, '%.1f', wallSec);
        fclose(fid);
    end
catch
end
fprintf('run_tests: %d/%d passed, %d failed, %d incomplete (%.1f s total)\n', ...
    passed, n, failed, incomplete, totalSec);
fprintf('full framework output: %s (%d bytes)\n', logFile, numel(captured));

if failed == 0 && incomplete == 0
    fprintf('ALL PASSED\n');
    return
end

bad = results([results.Failed] | [results.Incomplete]);
maxReport = 12;
for k = 1:min(numel(bad), maxReport)
    % Label by category. The previous build prefixed every entry with FAIL,
    % including assumption-filtered (incomplete) tests, which contradicted the
    % "N failed, M incomplete" header above it.
    if bad(k).Failed
        kind = 'FAIL';
    else
        kind = 'SKIP';
    end
    fprintf('%s %s\n%s\n', kind, bad(k).Name, failureMessage(bad(k)));
end
if numel(bad) > maxReport
    fprintf('... %d more failures omitted (see log)\n', numel(bad)-maxReport);
end
end

function msg = failureMessage(result)
% Extract the most useful text from a failed/incomplete TestResult. The
% framework puts the full formatted diagnostic in Details.DiagnosticRecord.
% Report (verified R2025a for both verification failures and errored tests);
% the field scan is only a fallback for framework changes.
msg = '';
try
    d = result.Details;
    if isfield(d, 'DiagnosticRecord') && ~isempty(d.DiagnosticRecord)
        rec = d.DiagnosticRecord;
        if numel(rec) > 1
            rec = rec(1);
        end
        msg = char(string(rec.Report));
    end
catch
end
if isempty(msg)
    try
        d = result.Details;
        if isfield(d, 'Message') && ~isempty(d.Message)
            msg = char(string(d.Message));
        else
            fn = fieldnames(d);
            for f = 1:numel(fn)
                v = d.(fn{f});
                if ischar(v) || isstring(v)
                    msg = char(string(v));
                    break
                end
            end
        end
    catch
    end
end
if isempty(msg)
    msg = '(no detail extracted; see log file)';
end
lines = regexp(msg, '\r?\n', 'split');
if numel(lines) > 6
    msg = [strjoin(lines(1:min(14, numel(lines))), newline) newline '...'];
end
end

function mcp_fclose_quiet(fid)
try
    if fid > 0
        fclose(fid);
    end
catch
end
end
