function job_status(jobId)
%JOB_STATUS Report status of a submitted job: live state + artifacts.
%   Merges: the live batch handle found by Tag on the local cluster
%   (classification via mcp_job_state, see note there), done.json written
%   by the worker, and the tail of run.log.
%   Timing fields are labelled explicitly because the previous build printed a
%   single ambiguous 'duration' that disagreed with done.json's elapsedSec and
%   with the submitted/finishedAt wall clock (observed: duration 00:00:01 vs
%   elapsedSec 0.0014 vs a 16 s submission-to-finish gap).
ROOT = mcp_ext_root();
jobId = mcp_str(jobId); % MCP arg normalization, see mcp_str
mcp_tool_log('job_status', jobId);
jobDir = fullfile(ROOT, 'jobs', jobId);
if ~exist(jobDir, 'dir')
    error('job_status:notFound', '[job_status:notFound] Unknown jobId: %s', jobId);
end
metaPath = fullfile(jobDir, 'meta.json');
if exist(metaPath, 'file')
    meta = jsondecode(fileread(metaPath));
else
    meta = struct('jobId', jobId, 'function', '?', 'scriptPath', '?', 'submittedAt', '?');
end
fprintf('jobId:     %s\n', char(meta.jobId));
fprintf('function:  %s\n', char(meta.function));
fprintf('script:    %s\n', char(meta.scriptPath));
fprintf('submitted: %s\n', char(meta.submittedAt));
state = 'no live handle';
errId = '';
errMsg = '';
diaryTxt = '';
workerRuntime = '';
finAt = '';
try
    % Retried lookup: a single pass can transiently miss a just-submitted
    % job while the local job storage index refreshes (see cancel_job).
    wantTag = ['mcpjob:' jobId];
    hit = [];
    for attempt = 1:3
        c = parcluster('local');
        js = c.Jobs;
        for k = 1:numel(js)
            try
                if strcmp(char(js(k).Tag), wantTag)
                    hit = js(k);
                    break;
                end
            catch
            end
        end
        if ~isempty(hit)
            break;
        end
        if attempt < 3
            pause(1.5);
        end
    end
    if ~isempty(hit)
        [state, errId, errMsg] = mcp_job_state(hit);
        % Reading task/worker properties on a job that is still running makes
        % MATLAB emit "此批处理作业的日志可能不完整，因为作业仍在运行" straight into the
        % command window, which the server then folds into THIS tool's output.
        % Same pollution class as the checkpoint timer, so suppress around the
        % property reads only.
        prevW = warning('off', 'all');
        rw = onCleanup(@() warning(prevW));
        try
            diaryTxt = char(hit.Tasks(1).Diary);
        catch
            diaryTxt = '';
        end
        try
            workerRuntime = char(hit.RunningDuration);
        catch
        end
        rw = [];
        warning(prevW);
    end
catch e
    state = ['cluster lookup failed: ' e.message];
end
donePath = fullfile(jobDir, 'done.json');
% Reconcile with the worker's done.json: the runner catches user-function
% errors, so a failed run still finishes its task without task Error.
if exist(donePath, 'file')
    try
        dn = jsondecode(fileread(donePath));
        % done.json is the runner's own terminal record and outranks the live
        % cluster handle, which can misclassify a successful job. Defer to the
        % handle only while the job is genuinely still in flight.
        if isfield(dn, 'status') && ~any(strcmp(state, {'queued', 'running'}))
            state = char(dn.status);
        end
        if isfield(dn, 'status') && strcmp(dn.status, 'failed')
            if isfield(dn, 'identifier'), errId = char(dn.identifier); end
            if isfield(dn, 'message'), errMsg = char(dn.message); end
        end
        if isfield(dn, 'finishedAt')
            finAt = char(dn.finishedAt);
        end
    catch
    end
elseif strcmp(state, 'no live handle') && isfield(meta, 'status') && ~strcmp(meta.status, 'submitted')
    % Handle lost (e.g. after MATLAB restart) and worker never wrote done.json:
    % fall back to the last status recorded in meta.json (e.g. 'cancelled').
    state = ['meta:' meta.status];
end
fprintf('state:     %s\n', state);
if ~isempty(finAt)
    fprintf('finished:  %s\n', finAt);
    try
        wall = datetime(finAt, 'InputFormat', 'yyyy-MM-dd HH:mm:ss') - ...
            datetime(char(meta.submittedAt), 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        fprintf('wall_total:      %.1f s  (submitted -> finished, includes queue delay)\n', seconds(wall));
    catch e
        fprintf('wall_total:      (unavailable: %s)\n', e.message);
    end
end
% The cluster handle's RunningDuration is deliberately NOT reported: on a
% finished job it drifts well past wall time (observed 00:17:56 for a job whose
% submitted->finished gap was 33 s and whose worker compute time was 14.0 s),
% so any label for it would mislead. wall_total and done.json elapsedSec are
% both derived from recorded timestamps and are the only defensible numbers.
if ~isempty(errId)
    fprintf('errorId:   %s\n', errId);
end
if ~isempty(errMsg)
    fprintf('errorMsg:  %s\n', errMsg);
end
if exist(donePath, 'file')
    fprintf('done.json: %s\n', fileread(donePath));
    fprintf('           (done.json elapsedSec = user compute time only)\n');
else
    fprintf('done.json: (not yet)\n');
end
logPath = fullfile(jobDir, 'run.log');
if exist(logPath, 'file')
    fprintf('--- run.log tail ---\n%s\n', mcp_tail(logPath, 30));
elseif ~isempty(diaryTxt)
    lines = regexp(diaryTxt, '\r?\n', 'split');
    n = numel(lines);
    fprintf('--- worker diary tail ---\n%s\n', strjoin(lines(max(1, n-30):n), newline));
else
    fprintf('run.log:   (not yet)\n');
end
fprintf('jobDir:    %s\n', jobDir);
end

function out = mcp_tail(f, n)
try
    raw = fileread(f);
catch
    out = '(run.log unreadable)';
    return;
end
lines = regexp(raw, '\r?\n', 'split');
if numel(lines) > 1 && isempty(lines{end})
    lines(end) = [];
end
first = max(1, numel(lines) - n + 1);
out = strjoin(lines(first:end), newline);
end
