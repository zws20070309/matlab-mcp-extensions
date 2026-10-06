function [sweepId, jobIds, skipped] = mcp_sweep_core(scriptPath, paramsJsonArray, tag, numWorkers, gpu, attachedFiles, name)
%MCP_SWEEP_CORE Submit one one-worker batch job per parameter set, as a group.
%   Measured reason this exists: a PCT worker cannot start a nested pool and a
%   parfor inside a job runs serially, so the only way to use 16 cores is 16
%   concurrent jobs - which without a group handle means N separate submits and
%   N separate polls. This writes extensions/sweeps/<sweepId>.json so
%   sweep_status/cancel_sweep can act on the whole group in one call.
%   Returns (jobIds, skipped) for internal callers; the tool wrapper prints.
if nargin < 7, name = ''; end
if nargin < 6, attachedFiles = ''; end
if nargin < 5, gpu = ''; end
if nargin < 4, numWorkers = ''; end
if nargin < 3, tag = ''; end
if nargin < 2, paramsJsonArray = ''; end
tag = mcp_str(tag);
name = mcp_str(name);
parts = mcp_split_json(paramsJsonArray);
if isempty(parts)
    parts = {''};
end
ROOT = mcp_ext_root();
sweepId = sprintf('sweep_%s_%04d', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')), randi(9999));
jobIds = cell(1, numel(parts));
skipped = {};
paramsUsed = cell(1, numel(parts));
for k = 1:numel(parts)
    pj = strtrim(parts{k});
    if isempty(pj)
        pj = '{}';
    end
    if ~(pj(1) == '{' || pj(1) == '[')
        % primitive sweep value (e.g. "[1e5,2e5,4e5]") -> named field
        pj = sprintf('{"value":%s}', pj);
    end
    ok = true;
    try
        jsondecode(pj);
    catch e
        ok = false;
        skipped{end+1} = sprintf('#%d %.120s (%s)', k, pj, e.identifier); %#ok<AGROW>
    end
    if ~ok
        continue
    end
    paramsUsed{k} = pj;
    try
        [jobIds{k}, ~, ~] = mcp_submit_job_core(scriptPath, pj, ...
            [sweepId ' #' num2str(k) ' ' tag], numWorkers, gpu, attachedFiles);
    catch e
        jobIds{k} = ['SUBMIT_FAILED: ' e.identifier];
        skipped{end+1} = sprintf('#%d %s', k, e.message); %#ok<AGROW>
    end
end
good = ~cellfun('isempty', jobIds) & ~startsWith(string(jobIds), 'SUBMIT_FAILED');
[~, fnOnly, ~] = fileparts(mcp_str(scriptPath));
man = struct('sweepId', sweepId, 'name', name, 'tag', tag, ...
    'scriptPath', mcp_str(scriptPath), ...
    'fnName', fnOnly, ...
    'createdAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
    'numWorkers', mcp_num(numWorkers, 0), 'gpu', mcp_str(gpu), ...
    'count', numel(parts), 'jobIds', {jobIds}, 'params', {paramsUsed}, ...
    'submitted', {jobIds(good)}, 'skipped', {skipped});
d = fullfile(ROOT, 'sweeps');
if ~exist(d, 'dir')
    mkdir(d);
end
fid = fopen(fullfile(d, [sweepId '.json']), 'w');
fwrite(fid, jsonencode(man));
fclose(fid);
mcp_tool_log('submit_sweep', sprintf('%s count=%d submitted=%d skipped=%d', ...
    sweepId, numel(parts), nnz(good), numel(skipped)));
jobIds = jobIds(good);
end
