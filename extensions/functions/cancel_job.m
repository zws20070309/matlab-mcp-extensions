function cancel_job(jobId)
%CANCEL_JOB Cancel a queued/running batch job by jobId.
%   Terminal classification uses mcp_job_state (Job.State alone cannot
%   distinguish cancelled/failed from finished on R2025a local cluster).
ROOT = mcp_ext_root();
% MCP marshals JSON args as MATLAB string scalars; mcp_str normalizes them
% to char so ['mcpjob:' jobId] is char concat (string concat would build a
% string ARRAY and strcmp would return a non-scalar logical that never
% matches) and empty-string args collapse to '' cleanly.
jobId = mcp_str(jobId);
mcp_tool_log('cancel_job', jobId);
jobDir = fullfile(ROOT, 'jobs', jobId);
if ~exist(jobDir, 'dir')
    error('cancel_job:notFound', '[cancel_job:notFound] Unknown jobId: %s', jobId);
end
donePath = fullfile(jobDir, 'done.json');
% Lookup with retries: a single pass over cluster jobs can transiently miss
% a just-submitted job while the local job storage index is refreshing
% (observed once in live use). Retry before declaring the handle lost.
hit = [];
seenTags = '';
for attempt = 1:4
    c = parcluster('local');
    js = c.Jobs;
    wantTag = ['mcpjob:' jobId];
    seenTags = '';
    for k = 1:numel(js)
        try
            tg = char(js(k).Tag);
            seenTags = [seenTags ' ' tg]; %#ok<AGROW>
            if strcmp(tg, wantTag)
                hit = js(k);
                break;
            end
        catch
            seenTags = [seenTags ' <unreadable>']; %#ok<AGROW>
        end
    end
    if ~isempty(hit)
        break;
    end
    if attempt < 4
        pause(2);
    end
end
if isempty(hit)
    if exist(donePath, 'file')
        fprintf('job %s already finished (no live handle):\n%s\n', jobId, fileread(donePath));
        return;
    end
    error('cancel_job:noHandle', '[cancel_job:noHandle] No live handle and no done.json for job %s (cluster jobs seen:%s)', jobId, seenTags);
end
[before, ~, ~] = mcp_job_state(hit);
if any(strcmp(before, {'finished', 'failed', 'cancelled'}))
    fprintf('job %s already in terminal state: %s\n', jobId, before);
    % Persist the observed cluster state, not just print it. Jobs that died
    % before their runner started leave meta.json stuck at "queued" with no
    % done.json, and every file-based tool (sweep_status, cancel_sweep, a later
    % job_status) then reports a dead job as queued. Reproduced 2026-10-11.
    metaPath = fullfile(jobDir, 'meta.json');
    if exist(metaPath, 'file')
        try
            meta = jsondecode(fileread(metaPath));
            meta.status = before;
            fid = fopen(metaPath, 'w');
            fwrite(fid, jsonencode(meta));
            fclose(fid);
        catch
        end
    end
    if ~exist(donePath, 'file')
        [~, errId0, errMsg0] = mcp_job_state(hit);
        rec = struct('status', char(string(before)), ...
            'identifier', char(string(errId0)), 'message', char(string(errMsg0)), ...
            'note', 'terminal state observed and recorded by cancel_job; the runner never wrote a record');
        fid = fopen(donePath, 'w');
        if fid > 0
            fwrite(fid, jsonencode(rec));
            fclose(fid);
            fprintf('recorded: %s\n', donePath);
        end
    end
    return;
end
tic;
cancel(hit);
pause(1);
[after, errId, errMsg] = mcp_job_state(hit);
fprintf('cancelled: %s (state %s -> %s)\n', jobId, before, after);
if ~isempty(errId)
    fprintf('errorId:   %s\n', errId);
end
if ~isempty(errMsg)
    fprintf('errorMsg:  %s\n', errMsg);
end
metaPath = fullfile(jobDir, 'meta.json');
if exist(metaPath, 'file')
    meta = jsondecode(fileread(metaPath));
    meta.status = 'cancelled';
    fid = fopen(metaPath, 'w');
    fwrite(fid, jsonencode(meta));
    fclose(fid);
end
% A cancelled job's worker never reaches the point where it writes done.json, so
% without this the errId/errMsg printed above die with the live handle: after a
% session restart job_status falls back to on-disk records and finds only
% meta.status, with no reason. Measured: jobs/<id>/ held meta.json alone while a
% worker-side failure next to it held a full done.json.
if ~exist(donePath, 'file')
    rec = struct('status', char(string(after)), 'identifier', char(string(errId)), ...
        'message', char(string(errMsg)), ...
        'cancelledAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
        'note', 'written by cancel_job: the worker did not run to completion, so it wrote no record');
    fid = fopen(donePath, 'w');
    if fid > 0
        fwrite(fid, jsonencode(rec));
        fclose(fid);
        fprintf('recorded: %s\n', donePath);
    end
end
end
