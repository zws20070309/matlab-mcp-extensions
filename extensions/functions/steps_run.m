function steps_run(repoRoot, stepsJson, optsJson)
%STEPS_RUN Run a fixed-order closeout pipeline and stop on the first failure.
%   repoRoot  : repository root; every relative path in a step resolves here.
%   stepsJson : JSON array of steps, executed in the given order. Each step is
%               {"name":"...", "kind":"...", ...} with kind-specific fields:
%     command  {"code":"genCounts()"}          execute MATLAB as-is (generation
%                                              tools are plain functions here:
%                                              tepc.genCounts() does not resolve).
%     test     {"file":"tests/unit/test_x.m"}  run one test file, require 0 fail.
%     anchor   {"file":"docs/x.md","anchor":"verbatim text","count":1}
%                                              the anchor must exist verbatim
%                                              (evidence anchors are checked this
%                                              way by the repo's own tests).
%     json     {"file":"docs/counts.json","get":"counts.test_functions","equals":578}
%                                              parse (reporting the suspect offset)
%                                              and optionally compare a dotted key.
%     sub      {"file":"README.md","find":"572","replace":"578","expect":2}
%                                              literal replace, backup written.
%     exists   {"file":"docs/latest.md","minBytes":1,"freshWithinSec":3600}
%     docsync  {"file":"docs/counts.json","get":"counts.test_functions",
%               "docs":["README.md","docs/quickstart.md"]}
%              the number regenerated into counts.json must appear verbatim in
%              every listed doc, or the docs test goes red on a stale number.
%     all      steps accept {"continueOnError":true} and {"writes":true} (a step
%                                              flagged writes:true is reported in
%                                              the abort line so you know what the
%                                              tree already changed).
%   optsJson  : {"logDir":"","addPaths":["tools","src"],"stopOnFail":true,
%                "dryRun":false,"recipe":"closeout"}
%
%   Why: the source session's closeout ran by hand and the order is load-bearing -
%   genCounts before the doc-count sync (otherwise the docs test goes red against a
%   stale number), genPositioning after any 'reason' edit, writeLatestEvidence after
%   both, governance locks last. Skipping a step produced states that were only
%   self-consistent in the narration. This tool makes the order executable and fails
%   loudly, and it logs every step to disk as it happens.
if nargin < 2, stepsJson = ''; end
if nargin < 3, optsJson = ''; end
repoRoot = mcp_str(repoRoot);
mcp_tool_log('steps_run', mcp_str(repoRoot));
if isempty(repoRoot) || exist(repoRoot, 'dir') ~= 7
    error('steps_run:badRoot', '[steps_run:badRoot] repoRoot must be an existing folder, got: %s', repoRoot);
end
o = struct();
if ~isempty(strtrim(mcp_str(optsJson)))
    try
        o = jsondecode(mcp_str(optsJson));
    catch e
        error('steps_run:badOpts', '[steps_run:badOpts] %s', e.message);
    end
end
stopOnFail = true;
if isfield(o, 'stopOnFail'), stopOnFail = truthy(o.stopOnFail); end
dryRun = false;
if isfield(o, 'dryRun'), dryRun = truthy(o.dryRun); end

steps = load_steps(repoRoot, stepsJson, o);
if isempty(steps)
    error('steps_run:noSteps', '[steps_run:noSteps] no steps given (stepsJson array, or opts {"recipe":"closeout"})');
end

logDir = fullfile(mcp_ext_root(), 'steps_logs');
if isfield(o, 'logDir'), logDir = mcp_str(o.logDir); end
if ~exist(logDir, 'dir'), mkdir(logDir); end
runId = sprintf('s%s', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd''T''HHmmss''Z''')));
logPath = fullfile(logDir, ['steps_' runId '.log']);

oldPath = path();
cleanUp = onCleanup(@() restore_path(oldPath));
if isfield(o, 'addPaths')
    ap = o.addPaths;
    if ~iscell(ap), ap = cellstr(string(ap)); end
    for k = 1:numel(ap)
        p = mcp_repo_path(repoRoot, ap{k});
        if exist(p, 'dir') == 7
            % -begin: the repo under test must win over a same-named function that some
            % other session left on the path, or a step silently runs the other repo.
            addpath(p, '-begin');
        end
    end
end
rehash;
fprintf('STEPS|runId=%s|n=%d|repo=%s%s\n', runId, numel(steps), repoRoot, tern(dryRun, '|DRYRUN', ''));
mcp_log_append(logPath, sprintf('STEPS|%s|n=%d|repo=%s|dryRun=%d', runId, numel(steps), repoRoot, dryRun));

ok = 0;
bad = 0;
written = {};
abortedAt = 0;
abortMsg = '';
firstMsg = '';
for k = 1:numel(steps)
    s = steps{k};
    nm = fld(s, 'name', sprintf('step%d', k));
    kd = lower(fld(s, 'kind', 'command'));
    cont = truthy(fld(s, 'continueOnError', false));
    isWrite = truthy(fld(s, 'writes', false)) || any(strcmp(kd, {'sub', 'command'}));
    if dryRun
        fprintf('STEP %d/%d  %-22s %-8s DRYRUN\n', k, numel(steps), nm, kd);
        ok = ok + 1;
        continue
    end
    te = tic;
    mcp_log_append(logPath, sprintf('BEGIN|%s|%d|%s|%s', runId, k, nm, kd));
    [msg, detail] = run_step(kd, s, repoRoot);
    el = toc(te);
    if isempty(msg)
        ok = ok + 1;
        if isWrite, written{end + 1} = nm; end
        fprintf('STEP %d/%d  %-22s %-8s OK    %5.1fs  %s\n', k, numel(steps), nm, kd, el, oneLine(detail, 150));
        mcp_log_append(logPath, sprintf('END|%s|%d|%s|OK|%s', runId, k, nm, oneLine(detail, 300)));
    else
        bad = bad + 1;
        fprintf('STEP %d/%d  %-22s %-8s FAIL  %5.1fs\n     reason: %s\n', k, numel(steps), nm, kd, el, msg);
        if ~isempty(strtrim(detail))
            fprintf('     detail: %s\n', oneLine(detail, 300));
        end
        mcp_log_append(logPath, sprintf('END|%s|%d|%s|FAIL|%s', runId, k, nm, oneLine([msg ' :: ' detail], 500)));
        if isempty(firstMsg), firstMsg = msg; end
        if ~cont && stopOnFail
            abortedAt = k;
            abortMsg = msg;
            break
        end
    end
end
restore_path(oldPath);
cleanUp = []; %#ok<NASGU>

if abortedAt == 0 && bad == 0
    v = sprintf('VERDICT|%s|ALL_OK|steps=%d', runId, ok);
elseif abortedAt == 0
    v = sprintf('VERDICT|%s|OK_WITH_%d_SKIPPED_FAILS|steps=%d', runId, bad, ok);
else
    v = sprintf('VERDICT|%s|ABORTED_AT_%d_OF_%d', runId, abortedAt, numel(steps));
end
if ~isempty(written)
    v = [v '|steps_that_wrote=' strjoin(written, ',')];
end
mcp_log_append(logPath, v);
fprintf('%s\n', v);
fprintf('log: %s\n', logPath);
if abortedAt > 0
    fprintf('NOT finished: %d step(s) ran, %d remain.\n', k - 1, numel(steps) - k);
    fprintf('the abort is real: fix the cause and rerun the whole list from step 1 unless a step is idempotent-safe to skip.\n');
    fprintf('first failure: %s\n', abortMsg);
elseif bad > 0
    % stopOnFail=false: the whole list ran, so the caller needs the failures named here
    % rather than a verdict token that says only how many were bad.
    fprintf('%d of %d step(s) failed but the list ran on (stopOnFail=false). first failure: %s\n', ...
        bad, numel(steps), firstMsg);
end
end

% ------------------------------------------------------------------------
function steps = load_steps(repoRoot, stepsJson, o)
steps = {};
txt = mcp_str(stepsJson);
% stepsJson may also be a path, so a long chain lives in a file instead of in the call.
% Anything starting with [ or { is JSON text; otherwise resolve repo-relative and read it.
t0 = strtrim(txt);
if ~isempty(t0) && ~any(t0(1) == '[{')
    pth = mcp_repo_path(repoRoot, t0);
    if exist(pth, 'file') ~= 2
        error('steps_run:noStepsFile', ...
            '[steps_run:noStepsFile] stepsJson was neither JSON text nor an existing file: %s', t0);
    end
    fprintf('steps file: %s\n', pth);
    txt = mcp_read_text(pth);
end
if ~isempty(strtrim(txt))
    try
        js = jsondecode(txt);
    catch e
        error('steps_run:badSteps', '[steps_run:badSteps] stepsJson did not parse: %s', e.message);
    end
    % jsondecode turns an array of objects into a struct array when every object
    % has the same fields and into a CELL array of structs otherwise (which is the
    % normal case here: step kinds carry different fields). Accept both shapes.
    if iscell(js)
        steps = js(:);
    elseif isstruct(js)
        if numel(js) > 1 && ~isfield(js, 'steps')
            steps = num2cell(js);
        elseif isfield(js, 'steps') && ~isempty(js.steps)
            inner = js.steps;
            if iscell(inner)
                steps = inner(:);
            else
                steps = num2cell(inner);
            end
        else
            steps = {js};
        end
    else
        error('steps_run:badSteps2', '[steps_run:badSteps2] stepsJson must be an array of step objects');
    end
    for k = numel(steps):-1:1
        if ~isstruct(steps{k})
            error('steps_run:badStep', '[steps_run:badStep] step %d is not an object', k);
        end
        if numel(steps{k}) > 1
            error('steps_run:badStepArray', ...
                ['[steps_run:badStepArray] step %d is a %dx%d struct array, not one step. ' ...
                 'In MATLAB a cell array passed to struct() expands column-wise: build the step, then assign the list field.'], ...
                k, size(steps{k}, 1), size(steps{k}, 2));
        end
    end
    return
end
if isfield(o, 'recipe') && strcmpi(strtrim(char(string(o.recipe))), 'closeout')
    steps = closeout_steps(repoRoot);
end
end

function steps = closeout_steps(repoRoot)
% Default order for the TEPC-style pure-MATLAB repository. Read from
% docs/closeout_steps.json when the repository ships one, so the repo owns the
% order and this tool does not hard-code a project's numbers.
custom = fullfile(repoRoot, 'docs', 'closeout_steps.json');
if exist(custom, 'file') == 2
    txt = mcp_read_text(custom);
    try
        js = jsondecode(txt);
        if ~iscell(js), js = num2cell(js); end
        steps = js(:);
        return
    catch e
        warning('steps_run:customRecipe', 'docs/closeout_steps.json unusable (%s); using built-in order', e.identifier);
    end
end
counts = fullfile(repoRoot, 'docs', 'counts.json');
s1 = struct('name', 'counts_json_parses', 'kind', 'json', 'file', counts);
s2 = struct('name', 'genCounts', 'kind', 'command', 'code', 'genCounts()', 'writes', true);
% s.docs is assigned AFTER struct(): a cell array passed to struct() is expanded
% column-wise, which turns one step into a 2-element struct array and makes every
% s.field access a comma list (isempty then fails with "too many input arguments")
s3 = struct('name', 'doc_counts_synced', 'kind', 'docsync', 'file', counts, ...
    'get', 'counts.test_functions');
s3.docs = {'README.md', 'docs/quickstart.md'};
s4 = struct('name', 'genPositioning', 'kind', 'command', 'code', 'genPositioning()', 'writes', true);
s5 = struct('name', 'writeLatestEvidence', 'kind', 'command', 'code', 'writeLatestEvidence()', 'writes', true);
s6 = struct('name', 'counts_reloaded', 'kind', 'json', 'file', counts);
steps = {s1, s2, s3, s4, s5, s6};
end

% ------------------------------------------------------------------------
function [msg, detail] = run_step(kind, s, repoRoot)
msg = '';
detail = '';
try
    switch kind
        case 'command'
            code = mcp_str(fld(s, 'code', ''));
            if isempty(code)
                msg = 'kind=command needs "code"';
                return
            end
            before = dir_snapshot(fld(s, 'watchDir', repoRoot));
            % Which file does this name actually run? A shared session keeps other repos
            % on the path, and a same-named generator there would silently be executed
            % and write into THAT repo instead of the one under test.
            res = first_resolution(code);
            if ~isempty(res)
                detail = ['resolved: ' res];
                rr = lower(strrep(strtrim(char(repoRoot)), '\', '/'));
                rl = lower(strrep(res, '\', '/'));
                inside = numel(rl) > numel(rr) && strcmp(rl(1:numel(rr)), rr) || ...
                    contains(rl, '/matlab-mcp-server/extensions/functions/');
                if ~inside && ~truthy(fld(s, 'allowOutside', false))
                    msg = sprintf(['the command resolves outside repoRoot (%s). Refusing to run it: ' ...
                        'that would modify another repository. Fix the path order, name the file ' ...
                        'explicitly, or pass allowOutside=true.'], res);
                    return
                end
            end
            cap = evalc(code);
            after = dir_snapshot(fld(s, 'watchDir', repoRoot));
            chg = diff_snapshot(before, after);
            detail = oneLine(cap, 300);
            if ~isempty(chg)
                detail = [detail ' | changed: ' strjoin(chg, ', ')];
            end

        case 'test'
            f = abs_path(repoRoot, fld(s, 'file', ''));
            if isempty(f) || exist(f, 'file') ~= 2
                msg = ['no such test file: ' char(string(fld(s, 'file', '')))];
                return
            end
            r = runtests(f);
            nf = nnz([r.Failed]);
            nc = numel(r);
            detail = sprintf('cases=%d fail=%d inc=%d', nc, nf, nnz([r.Incomplete]));
            wantMin = mcp_num(fld(s, 'minCases', NaN), NaN);
            if nf > 0
                first = r(find([r.Failed], 1));
                msg = sprintf('%d test(s) failed in %s; first: %s :: %s', ...
                    nf, filesep_tail(f, 28), first.Name, diag_of(first));
            elseif isfinite(wantMin) && nc < wantMin
                msg = sprintf('only %d case(s) ran, minCases=%g', nc, wantMin);
            end

        case 'anchor'
            f = abs_path(repoRoot, fld(s, 'file', ''));
            a = char(string(fld(s, 'anchor', '')));
            if isempty(f) || exist(f, 'file') ~= 2
                msg = ['no such file: ' char(string(fld(s, 'file', '')))];
                return
            end
            if isempty(a)
                msg = 'kind=anchor needs "anchor"';
                return
            end
            txt = mcp_read_text(f);
            hits = strfind(txt, a);
            want = mcp_num(fld(s, 'count', 1), 1);
            line = [];
            if ~isempty(hits)
                line = numel(strfind(txt(1:hits(1)), newline)) + 1;
            end
            detail = sprintf('occurrences=%d firstLine=%s', numel(hits), mat2str(line));
            if numel(hits) < want
                msg = sprintf('anchor NOT FOUND verbatim in %s (%d occurrence(s), want >= %g)', ...
                    rel_of(f, repoRoot), numel(hits), want);
                near = near_lines(txt, a);
                if ~isempty(near)
                    detail = [detail ' | closest line(s): ' near];
                end
            end

        case 'json'
            f = abs_path(repoRoot, fld(s, 'file', ''));
            if isempty(f) || exist(f, 'file') ~= 2
                msg = ['no such file: ' char(string(fld(s, 'file', '')))];
                return
            end
            txt = mcp_read_text(f);
            try
                js = jsondecode(txt);
            catch e
                msg = sprintf('JSON does not parse: %s', e.message);
                susp = bad_quote_offset(txt);
                if ~isempty(susp)
                    msg = [msg sprintf(' (suspect char %d, line %d: unescaped ASCII double quote inside a string value)', ...
                        susp(1), numel(strfind(txt(1:susp(1)), newline)) + 1)];
                    msg = [msg ' | governance rule: use 「」 inside register strings'];
                end
                return
            end
            key = mcp_str(fld(s, 'get', ''));
            if isempty(key)
                detail = sprintf('parsed OK, %d bytes', numel(txt));
                return
            end
            val = dotget(js, key);
            if isempty(val)
                msg = sprintf('key "%s" not present in %s', key, rel_of(f, repoRoot));
                return
            end
            detail = sprintf('%s = %s', key, val_str(val));
            if isfield(s, 'equals')
                want = s.equals;
                if ~same_val(val, want)
                    msg = sprintf('%s is %s, expected %s', key, val_str(val), val_str(want));
                end
            end

        case 'sub'
            f = abs_path(repoRoot, fld(s, 'file', ''));
            a = char(string(fld(s, 'find', '')));
            b = char(string(fld(s, 'replace', '')));
            if isempty(f) || exist(f, 'file') ~= 2
                msg = ['no such file: ' char(string(fld(s, 'file', '')))];
                return
            end
            txt = mcp_read_text(f);
            hits = strfind(txt, a);
            want = mcp_num(fld(s, 'expect', 1), 1);
            if numel(hits) ~= want
                msg = sprintf('found %d occurrence(s) of find-text in %s, expect=%g', ...
                    numel(hits), rel_of(f, repoRoot), want);
                return
            end
            if numel(b) > 0 && any(b == '"') && endsWith(f, '.json') && ~truthy(fld(s, 'allowQuote', false))
                msg = 'refusing to insert an ASCII double quote into a .json string value (use 「」): pass allowQuote=true if this is really intended';
                return
            end
            out = strrep(txt, a, b);
            bak = [f '.bak-' char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd''T''HHmmss''Z'''))];
            copyfile(f, bak);
            fid = fopen(f, 'wb');
            if fid < 0
                msg = ['cannot open for writing: ' f];
                return
            end
            fwrite(fid, unicode2native(out, 'UTF-8'));
            fclose(fid);
            detail = sprintf('replaced %d occurrence(s); backup %s', numel(hits), filesep_tail(bak, 34));

        case 'docsync'
            f = abs_path(repoRoot, fld(s, 'file', ''));
            txtj = mcp_read_text(f);
            if isempty(txtj)
                msg = ['no such json: ' char(string(fld(s, 'file', '')))];
                return
            end
            try
                js = jsondecode(txtj);
            catch e
                msg = sprintf('source json does not parse: %s', e.message);
                return
            end
            key = mcp_str(fld(s, 'get', ''));
            val = dotget(js, key);
            if isempty(val)
                msg = sprintf('key "%s" not present', key);
                return
            end
            num = sprintf('%g', double(val));
            docs = fld(s, 'docs', {});
            if ~iscell(docs), docs = cellstr(string(docs)); end
            miss = {};
            parts = strings(0, 1);
            for j = 1:numel(docs)
                dp = abs_path(repoRoot, docs{j});
                dtxt = mcp_read_text(dp);
                if isempty(dtxt)
                    miss{end + 1} = [char(string(docs{j})) ' (missing)']; %#ok<AGROW>
                    continue
                end
                % a plain substring search let "5" pass as present inside "572"
                % and hid the very drift this step exists to catch
                h = regexp(dtxt, ['(?<!\d)' strrep(num, '.', '\.') '(?!\d)'], 'start');
                if isempty(h)
                    miss{end + 1} = [char(string(docs{j})) ' (no standalone "' num '")']; %#ok<AGROW>
                else
                    ln = numel(strfind(dtxt(1:h(1)), newline)) + 1;
                    parts(end + 1) = sprintf('%s:%d', char(string(docs{j})), ln); %#ok<AGROW>
                end
            end
            detail = sprintf('%s=%s in %s', key, num, strjoin(parts, ', '));
            if ~isempty(miss)
                msg = sprintf('doc count not synced: %s does not contain "%s" (run the generator, then edit these docs)', ...
                    strjoin(miss, '; '), num);
            end

        case 'exists'
            f = abs_path(repoRoot, fld(s, 'file', ''));
            d = dir(f);
            if isempty(d) || d.isdir
                msg = ['missing file: ' char(string(fld(s, 'file', '')))];
                return
            end
            detail = sprintf('%d bytes, %s', d.bytes, char(datetime(d.datenum, 'ConvertFrom', 'datenum')));
            mb = mcp_num(fld(s, 'minBytes', 0), 0);
            if d.bytes < mb
                msg = sprintf('%s is %d bytes, minBytes=%g', rel_of(f, repoRoot), d.bytes, mb);
                return
            end
            fw = mcp_num(fld(s, 'freshWithinSec', NaN), NaN);
            if isfinite(fw)
                age = (now - d.datenum) * 86400;
                detail = sprintf('%s, age=%.0fs', detail, age);
                if age > fw
                    msg = sprintf('%s is %.0f s old, freshWithinSec=%g', rel_of(f, repoRoot), age, fw);
                end
            end

        case 'anchors'
            % Every evidence.anchor in a register must exist verbatim in the file it names.
            % Checking one anchor by hand is how a stale register survives a review.
            rf = abs_path(repoRoot, fld(s, 'file', ''));
            jtxt = mcp_read_text(rf);
            JJ = jsondecode(jtxt);
            listPath = char(string(fld(s, 'list', 'entries')));
            items = dotget(JJ, listPath);
            if isempty(items)
                msg = sprintf('no entries at "%s" in %s', listPath, rel_of(rf, repoRoot));
                return
            end
            fKey = char(string(fld(s, 'fileKey', 'file')));
            aKey = char(string(fld(s, 'anchorKey', 'anchor')));
            n = 0;
            bad = {};
            for e1 = 1:numel(items)
                it = items(e1);
                if ~isstruct(it) || ~isfield(it, aKey), continue; end
                an = char(string(it.(aKey)));
                if isempty(an), continue; end
                tgt = char(string(fld(it, fKey, fld(s, 'inFile', ''))));
                if isempty(tgt), msg = 'step needs inFile, or each entry to carry its file field'; return; end
                tp = abs_path(repoRoot, tgt);
                if exist(tp, 'file') ~= 2
                    bad{end+1} = sprintf('%s: file missing (%s)', tgt, an); %#ok<AGROW>
                    continue
                end
                txt = mcp_read_text(tp);
                n = n + 1;
                % literal, not regexp: an anchor containing . ( + would otherwise match
                % anything (or nothing) and the check would silently pass
                if ~contains(txt, an)
                    bad{end+1} = sprintf('%s: anchor not found verbatim ("%s")', tgt, oneLine(an, 60)); %#ok<AGROW>
                end
            end
            detail = sprintf('%d/%d anchor(s) matched in %s', n - numel(bad), n, rel_of(rf, repoRoot));
            if ~isempty(bad)
                msg = sprintf('%d anchor(s) stale: %s', numel(bad), strjoin(bad(1:min(5, numel(bad))), ' | '));
            end

        case 'fresh'
            % A generated artifact must not be older than the sources it describes:
            % editing src/tests and then certifying leaves the same-generation locks red.
            af = abs_path(repoRoot, fld(s, 'file', ''));
            d = dir(af);
            if isempty(d) || d.isdir
                msg = ['generated file missing: ' char(string(fld(s, 'file', '')))];
                return
            end
            srcs = fld(s, 'sources', {'src', 'tests', 'tools', 'app'});
            if ~iscell(srcs), srcs = cellstr(string(srcs)); end
            pat = char(string(fld(s, 'pattern', '*.m')));
            older = {};
            newest = 0;
            for q = 1:numel(srcs)
                one = mcp_walk(abs_path(repoRoot, srcs{q}), pat);
                for w = 1:numel(one)
                    dd = dir(one{w});
                    if ~isempty(dd) && dd.datenum > d.datenum + 1e-9
                        older{end+1} = rel_of(one{w}, repoRoot); %#ok<AGROW>
                        newest = max(newest, dd.datenum);
                    end
                end
            end
            age = (now - d.datenum) * 86400;
            detail = sprintf('%s is %.0fs old, %d source file(s) newer', ...
                rel_of(af, repoRoot), age, numel(older));
            if ~isempty(older)
                msg = sprintf('generated file is stale: %d source file(s) changed after it (e.g. %s) - rerun its generator before certifying', ...
                    numel(older), strjoin(older(1:min(3, numel(older))), ', '));
            end

        otherwise
            msg = ['unknown kind "' kind '" (command|test|anchor|anchors|json|sub|exists|docsync|fresh)'];
    end
catch e
    msg = sprintf('[%s] %s', e.identifier, e.message);
end
end

% ------------------------------------------------------------------------
function v = fld(s, f, d)
v = d;
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = s.(f);
end
end

function p = first_resolution(code)
% Resolve the leading identifier of each ';' segment of a command string the way MATLAB
% would run it. A shared session keeps other repos on the path, so a bare generator name
% can be a DIFFERENT repo's file - and that repo is what gets written.
p = '';
root = lower(strrep(matlabroot, '\', '/'));
parts = strsplit(strtrim(code), ';');
for k = 1:numel(parts)
    seg = strtrim(parts{k});
    % which() is asked BEFORE the command runs, so a segment like
    % "addpath(X,'-begin'); genCounts" would resolve against the OLD path and be refused
    % even though the command itself fixes the order. Applying that segment here is what
    % running the command does anyway, and steps_run restores the session path on exit.
    if ~isempty(regexp(seg, '^addpath\s*[\(/]', 'once'))
        try
            eval(seg);
            rehash;
        catch
        end
        continue
    end
    tok = regexp(seg, '^([A-Za-z_]\w*)', 'tokens', 'once');
    if isempty(tok), continue; end
    w = '';
    try
        w = which(tok{1});
    catch
    end
    if ~(ischar(w) && ~isempty(w) && exist(w, 'file') == 2), continue; end
    rl = lower(strrep(w, '\', '/'));
    if contains(rl, root), continue; end             % a MathWorks function is not a repo
    if contains(rl, '/matlab-mcp-server/extensions/functions/'), continue; end
    p = w;
    return
end
end

function p = abs_path(repoRoot, relp)
p = mcp_repo_path(repoRoot, relp);
end

function r = rel_of(p, repoRoot)
r = strrep(strrep(p, filesep(), '/'), [strrep(repoRoot, filesep(), '/') '/'], '');
end

function s = filesep_tail(p, n)
p = strrep(char(string(p)), '\', '/');
if numel(p) > n
    s = ['...' p(end - n + 1:end)];
else
    s = p;
end
end

function m = diag_of(t)
m = '';
try
    arr = t.Details.toArray();
    if ~isempty(arr)
        m = strjoin(arrayfun(@(a) a.Message, arr, 'UniformOutput', false), ' / ');
    end
catch
    m = '(no diagnostic)';
end
if isempty(m), m = '(no diagnostic)'; end
end

function v = dotget(s, parts0)
v = [];
parts = strsplit(parts0, '.');
for k = 1:numel(parts)
    if isstruct(s) && isfield(s, parts{k})
        s = s.(parts{k});
    else
        return
    end
end
v = s;
end

function s = val_str(v)
if isnumeric(v) || islogical(v)
    s = sprintf('%g', double(v));
elseif isstring(v)
    s = ['"' char(v) '"'];
else
    s = char(string(v));
end
end

function tf = same_val(a, b)
tf = false;
try
    if isnumeric(a) || islogical(a)
        tf = isnumeric(b) && isfinite(double(a)) && double(a) == double(b);
    else
        tf = strcmp(char(string(a)), char(string(b)));
    end
catch
    tf = false;
end
end

function out = near_lines(txt, anchor)
out = '';
head = anchor(1:min(10, numel(anchor)));
lines = regexp(txt, '\r?\n', 'split');
hit = strings(0, 1);
for k = 1:numel(lines)
    if ~isempty(strfind(lower(lines{k}), lower(head)))
        hit(end + 1) = sprintf('L%d:%s', k, strtrim(lines{k})); %#ok<AGROW>
        if numel(hit) >= 3
            break
        end
    end
end
if ~isempty(hit)
    out = oneLine(strjoin(hit, ' || '), 240);
end
end

function pos = bad_quote_offset(txt)
% First position that looks like an unterminated/extra ASCII double quote inside
% a JSON string value: a '"' that closes no string (next non-space is not one of
% , } ] : and the character before it is not a backslash). Heuristic, reported as
% "suspect" - the measured failure was exactly this defect at a fixed char offset.
pos = [];
inStr = false;
esc = false;
for k = 1:numel(txt)
    c = txt(k);
    if inStr
        if esc
            esc = false;
        elseif c == '\'
            esc = true;
        elseif c == '"'
            j = k + 1;
            while j <= numel(txt) && (txt(j) == ' ' || txt(j) == char(9))
                j = j + 1;
            end
            if j > numel(txt) || ~any(txt(j) == [',}]:'])
                pos = [k];
                return
            end
            inStr = false;
        end
    elseif c == '"'
        inStr = true;
    end
end
end

function s = dir_snapshot(d)
s = struct('name', {}, 'bytes', {}, 'datenum', {});
if isempty(d) || exist(d, 'dir') ~= 7
    return
end
try
    s = dir(fullfile(d, '**', '*'));
catch
    s = dir(d);
end
end

function ch = diff_snapshot(a, b)
ch = {};
keyA = strings(numel(a), 1);
for k = 1:numel(a)
    keyA(k) = string(sprintf('%s|%d|%f', a(k).name, a(k).bytes, a(k).datenum));
end
keyB = strings(numel(b), 1);
for k = 1:numel(b)
    keyB(k) = string(sprintf('%s|%d|%f', b(k).name, b(k).bytes, b(k).datenum));
end
onlyB = setdiff(keyB, keyA, 'stable');
for k = 1:min(12, numel(onlyB))
    ch{end + 1} = char(onlyB(k)); %#ok<AGROW>
end
end

function restore_path(p)
try
    path(p);
catch
end
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
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
