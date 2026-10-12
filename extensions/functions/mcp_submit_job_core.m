function [jobId, state, jobDir] = mcp_submit_job_core(scriptPath, paramsJson, tag, numWorkers, gpu, attachedFiles)
%MCP_SUBMIT_JOB_CORE Create and launch a batch job, returning jobId + state.
%   Internal helper shared by submit_job and submit_sweep (via mcp_sweep_core).
%   Kept separate so the MCP-exposed tools can print their report WITHOUT
%   returning a value: the server evaluates a tool call as an expression, so a
%   returned jobId used to be echoed as a stray `ans` block after the summary.
%
%   numWorkers   : '' = 1 worker (PCT default). >1 is only useful when the user
%                  function itself parfor's, and note the measured constraint:
%                  a worker CANNOT start a nested pool (parallel:cluster:
%                  PoolRunValidation) and parfor inside a job silently runs
%                  serial (measured 12.18 s parfor vs 12.11 s serial), so for
%                  throughput the pattern is many one-worker jobs, not one
%                  multi-worker job.
%   gpu          : '1' makes the worker enable CUDA forward compatibility before
%                  calling the user function (the flag is per process).
%   attachedFiles: JSON array of absolute file/folder paths to ship to the
%                  worker. Needed for data files that are NOT reachable through
%                  the inherited MATLAB path; without them a worker only sees
%                  the client path plus its own jobDir as current folder.
ROOT = mcp_ext_root();
if nargin < 3, tag = ''; end
if nargin < 4, numWorkers = ''; end
if nargin < 5, gpu = ''; end
if nargin < 6, attachedFiles = ''; end
scriptPath = mcp_str(scriptPath);
paramsJson = mcp_str(paramsJson);
tag = mcp_str(tag);
gpu = mcp_str(gpu);
attachedFiles = mcp_str(attachedFiles);
nw = mcp_num(numWorkers, 0);
if ~isfinite(nw)
    nw = 0;
end
nw = max(0, round(nw));
if isempty(scriptPath)
    error('submit_job:badArgs', '[submit_job:badArgs] scriptPath must be a non-empty string');
end
if ~exist(scriptPath, 'file')
    error('submit_job:notFound', '[submit_job:notFound] File not found: %s', scriptPath);
end
[~, fnName, ext] = fileparts(scriptPath);
if ~strcmpi(ext, '.m')
    error('submit_job:badExt', '[submit_job:badExt] scriptPath must be a .m file, got: %s', scriptPath);
end
attachList = {};
attachedFiles = mcp_str(attachedFiles);
if ~isempty(attachedFiles)
    try
        a = jsondecode(attachedFiles);
        if ischar(a) || isstring(a)
            attachList = {char(string(a))};
        elseif iscell(a)
            attachList = cellfun(@(x) char(string(x)), a(:)', 'UniformOutput', false);
        elseif isempty(a)
            attachList = {};
        else
            error('submit_job:badAttach', ...
                '[submit_job:badAttach] attachedFiles must be a JSON array of path strings, e.g. ["C:\a\b.m"]');
        end
    catch e
        if strcmp(e.identifier, 'submit_job:badAttach')
            rethrow(e)
        end
        if exist(attachedFiles, 'file') == 2
            attachList = {attachedFiles};
        else
            error('submit_job:badAttach', '[submit_job:badAttach] cannot parse attachedFiles: %s (pass a JSON array of paths, e.g. ["C:\a\b.m"], or a single existing path)', e.message);
        end
    end
    for k = 1:numel(attachList)
        if ~exist(attachList{k}, 'file')
            error('submit_job:attachMissing', ...
                '[submit_job:attachMissing] attached file not found: %s', attachList{k});
        end
    end
end
jobId = sprintf('job_%s_%04d%04d', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')), ...
    randi(9999), randi(9999));
jobDir = fullfile(ROOT, 'jobs', jobId);
mkdir(jobDir);
meta = struct('jobId', jobId, 'scriptPath', scriptPath, 'function', fnName, ...
    'tag', ['mcpjob:' jobId], 'userTag', tag, ...
    'submittedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
    'paramsJson', paramsJson, 'status', 'submitted', ...
    'numWorkers', nw, 'gpu', gpu, 'attachedFiles', {attachList});
fid = fopen(fullfile(jobDir, 'meta.json'), 'w');
fwrite(fid, jsonencode(meta));
fclose(fid);
opt = {'CurrentFolder', jobDir, 'CaptureDiary', true};
if ~isempty(attachList)
    opt{end+1} = 'AttachedFiles';
    opt{end+1} = attachList;
end
if nw > 1
    opt{end+1} = 'NumWorkersRange';
    opt{end+1} = [nw nw];
end
% nout must be 0: mcp_job_runner writes its own artifacts (run.log/
% result.mat/done.json) and returns nothing. Passing nw here made batch
% request nw outputs from a 0-output function, so every job died before the
% runner started with MATLAB:TooManyOutputs whenever numWorkers was set
% (reproduced 2026-10-11: numWorkers='1' -> failed, '' -> finished).
% The worker count is already conveyed by the NumWorkersRange option above.
j = batch(@mcp_job_runner, 0, {jobDir, scriptPath, paramsJson, gpu}, opt{:});
j.Tag = ['mcpjob:' jobId];
state = char(j.State);
meta.status = state;
fid = fopen(fullfile(jobDir, 'meta.json'), 'w');
fwrite(fid, jsonencode(meta));
fclose(fid);
mcp_tool_log('submit_job', sprintf('jobId=%s fn=%s tag=%s state=%s nw=%d gpu=%s attach=%d', ...
    jobId, fnName, tag, state, nw, gpu, numel(attachList)));
end
