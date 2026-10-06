function submit_job(scriptPath, paramsJson, tag, numWorkers, gpu, attachedFiles)
%SUBMIT_JOB Submit a simulation function as an asynchronous batch job.
%   scriptPath   : absolute path to a function file with the convention
%                  "out = f(params)" (params decoded from paramsJson).
%                  For a multi-argument project API use the mcpCall form:
%                  {"cfg":{...},"mcpCall":["$cfg","N",1000,"Seed",7]}.
%   paramsJson   : JSON string of parameters, or '' for none.
%   tag          : free-text label, or ''.
%   numWorkers   : '' = 1. Keep 1: a worker cannot start a nested pool and a
%                  parfor inside a job runs serially (measured 12.18 s parfor vs
%                  12.11 s serial), so use submit_sweep for core-parallel work.
%   gpu          : '1' enables CUDA forward compatibility inside the worker so
%                  gpuArray works there (the flag is per process).
%   attachedFiles: JSON array of absolute paths to ship to the worker.
%   Prints jobId immediately; computation runs on a PCT worker.
%   Artifacts land in <extensions>\jobs\<jobId>\ (meta.json, run.log,
%   result.mat, done.json). Poll with job_status, stop with cancel_job.
%   Returns no output argument on purpose (see mcp_submit_job_core).
if nargin < 6, attachedFiles = ''; end
if nargin < 5, gpu = ''; end
if nargin < 4, numWorkers = ''; end
if nargin < 3, tag = ''; end
if nargin < 2, paramsJson = ''; end
if nargin < 1, scriptPath = ''; end
[jobId, state, jobDir] = mcp_submit_job_core(scriptPath, paramsJson, tag, ...
    numWorkers, gpu, attachedFiles);
fprintf('jobId=%s\nstate=%s\njobDir=%s\n', jobId, state, jobDir);
fprintf('note: ~10-15 s of queue+worker boot before compute starts; done.json elapsedSec counts compute only\n');
end
