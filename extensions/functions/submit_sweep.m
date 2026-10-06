function submit_sweep(scriptPath, paramsJsonArray, tag, numWorkers, gpu, attachedFiles, name)
%SUBMIT_SWEEP Submit one job per parameter set and return a group handle.
%   scriptPath     : absolute path to "out = f(params)" (see submit_job notes).
%   paramsJsonArray: JSON array of parameter objects, or JSON lines, e.g.
%                      [{"N":1000,"seed":1},{"N":1000,"seed":2}]
%                    Primitives are wrapped as {"value":x}. '' = one plain job.
%   tag            : free-text label or ''.
%   numWorkers     : '' = 1 per job. KEEP IT 1: a worker cannot start a nested
%                    pool and parfor inside a job runs serially, so N one-worker
%                    jobs is how you use N cores (measured 3.55x on 4 workers
%                    only in the client session, not inside jobs).
%   gpu            : '1' to enable CUDA forward compatibility inside each worker.
%   attachedFiles  : JSON array of absolute paths the worker needs (data files).
%   name           : short label stored in the sweep manifest.
%   Jobs are queued by the local cluster automatically when workers run out.
%   Poll with sweep_status(sweepId,''), cancel with cancel_sweep(sweepId,'').
%   Prints only - returns nothing so no stray `ans` is echoed.
if nargin < 7, name = ''; end
if nargin < 6, attachedFiles = ''; end
if nargin < 5, gpu = ''; end
if nargin < 4, numWorkers = ''; end
if nargin < 3, tag = ''; end
if nargin < 2, paramsJsonArray = ''; end
if nargin < 1, scriptPath = ''; end
parts = mcp_split_json(paramsJsonArray);
n = numel(parts);
if n == 0
    n = 1;
end
[sweepId, jobIds, skipped] = mcp_sweep_core(scriptPath, paramsJsonArray, tag, ...
    numWorkers, gpu, attachedFiles, name);
fprintf('sweepId=%s\nplanned=%d submitted=%d skipped=%d\n', sweepId, numel(parts), numel(jobIds), numel(skipped));
fprintf('manifest=%s\n', fullfile(mcp_ext_root(), 'sweeps', [sweepId '.json']));
cap = min(20, numel(jobIds));
for k = 1:cap
    fprintf('  [%d] %s\n', k, jobIds{k});
end
if numel(jobIds) > cap
    fprintf('  ... %d more (see the manifest above)\n', numel(jobIds) - cap);
end
for k = 1:min(5, numel(skipped))
    fprintf('  SKIPPED %s\n', skipped{k});
end
if isempty(jobIds)
    fprintf('VERDICT|SWEEP_SUBMIT_FAILED|planned=%d submitted=0 - nothing was queued; fix the errors above and resubmit\n', numel(parts));
else
    fprintf('next: sweep_status("%s", "")\n', sweepId);
end
mcp_tool_log('submit_sweep', sprintf('%s n=%d ok=%d', sweepId, numel(parts), numel(jobIds)));
end
