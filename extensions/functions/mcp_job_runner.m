function mcp_job_runner(jobDir, scriptPath, paramsJson, gpu)
%MCP_JOB_RUNNER Executes a user simulation function on a PCT worker.
%   Convention: scriptPath points to a function file "out = f(params)".
%   params is decoded from paramsJson (empty -> []).
%   Escape hatch for real project APIs that need more than one argument: when
%   the decoded params is a struct carrying a cell field "mcpCall", the function
%   is invoked as f(params.mcpCall{:}), so a name-value API such as
%     <pkg>.run.execute(cfg, 'N', 1e5, 'Seed', 12345)
%   becomes reachable from a batch job (the plain single-argument form cannot
%   express it). A leading "$name" inside mcpCall is substituted by the sibling
%   field of the same struct:
%     paramsJson = {"cfg":{"a":1},"mcpCall":["$cfg","N",100,"Seed",7]}
%   gpu: non-empty and not '0' -> enable CUDA forward compatibility first, since
%   that flag is per process and a worker starts with it OFF (measured: the
%   client had it enabled, a fresh worker still had to enable it itself).
%   Artifacts written into jobDir:
%     run.log     - command-window output + worker provenance + pool warning
%     result.mat  - variable "out" (on success)
%     done.json   - completion marker with status/summary (always)
if nargin < 4, gpu = ''; end
logFid = fopen(fullfile(jobDir, 'run.log'), 'w');
c = onCleanup(@() mcp_fclose_safe(logFid));
fprintf(logFid, 'job started %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
try
    fprintf(logFid, 'worker: host=%s user=%s cores=%d\n', ...
        getenv('COMPUTERNAME'), getenv('USERNAME'), feature('numcores'));
catch
end
try
    p = gcp('nocreate');
    if isempty(p)
        fprintf(logFid, ['pool: none. WARNING - parfor inside this function runs ' ...
            'SERIALLY (measured parfor 12.18 s vs serial 12.11 s for 12x pause(1)), ' ...
            'and a worker cannot start its own pool (parallel:cluster:PoolRunValidation). ' ...
            'For throughput submit several one-worker jobs (use submit_sweep).\n']);
    else
        fprintf(logFid, 'pool: present with %d workers\n', p.NumWorkers);
    end
catch e
    fprintf(logFid, 'pool: unknown (%s)\n', e.message);
end
gs = mcp_str(gpu);
if ~isempty(gs) && ~any(strcmp(lower(gs), {'0', 'false', 'off', 'no'}))
    try
        g = mcp_gpu_enable(gs);
        fprintf(logFid, 'gpu: usable=%s device=%s cc=%s warm=%.2fs note=%s\n', ...
            tfstr(g.ok), g.device, g.cc, g.warmSec, g.note);
    catch e
        fprintf(logFid, 'gpu: enable FAILED %s :: %s\n', e.identifier, e.message);
    end
end
try
    if ~isempty(paramsJson)
        params = jsondecode(paramsJson);
    else
        params = [];
    end
    [~, fnName, ext] = fileparts(scriptPath);
    if ~strcmpi(ext, '.m')
        error('mcp_job_runner:badExt', 'scriptPath must be a .m file, got: %s', scriptPath);
    end
    addpath(fileparts(scriptPath));
    fh = str2func(fnName);
    callArgs = {params};
    if isstruct(params) && isfield(params, 'mcpCall')
        cc = params.mcpCall;
        if ~iscell(cc)
            cc = {cc};
        end
        callArgs = cell(1, numel(cc));
        for k = 1:numel(cc)
            v = cc{k};
            if (ischar(v) || isstring(v)) && numel(char(string(v))) > 1 && v(1) == '$'
                fld = char(string(v(2:end)));
                if ~isfield(params, fld)
                    error('mcp_job_runner:badRef', 'mcpCall entry $%s has no sibling field', fld);
                end
                v = params.(fld);
            end
            callArgs{k} = v;
        end
        fprintf(logFid, 'calling with %d arguments (mcpCall form)\n', numel(callArgs));
    end
    fprintf(logFid, 'running function: %s\n', fnName);
    t0 = tic;
    S = struct('out', [], 'cap', '', 'fh', fh, 'ca', {callArgs});
    S.cap = evalc('S.out = S.fh(S.ca{:});');
    elapsed = toc(t0);
    out = S.out;
    fprintf(logFid, '%s', S.cap);
    fprintf(logFid, 'finished in %.1f s\n', elapsed);
    save(fullfile(jobDir, 'result.mat'), 'out');
    info = struct('status', 'finished', 'elapsedSec', elapsed, ...
        'outClass', class(out), 'outSize', mat2str(size(out)), ...
        'finishedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    if isstruct(out) && ~isempty(out)
        info.fields = fieldnames(out);
    end
    % Value fingerprint: outClass/outSize alone cannot expose a wrong-but-well-
    % shaped result, so a cheap numeric summary makes silent corruption visible
    % from job_status without downloading result.mat.
    try
        info.outSummary = mcp_out_summary(out);
    catch
        info.outSummary = '(unavailable)';
    end
    mcp_write_json(fullfile(jobDir, 'done.json'), info);
catch e
    info = struct('status', 'failed', 'message', e.message, ...
        'identifier', e.identifier, ...
        'failedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    if ~isempty(e.stack)
        info.stackAt = e.stack(1).name;
        info.stackLine = e.stack(1).line;
    end
    mcp_write_json(fullfile(jobDir, 'done.json'), info);
    fprintf(logFid, 'FAILED: %s :: %s\n', e.identifier, e.message);
end
end

function mcp_write_json(f, s)
fid = fopen(f, 'w');
fwrite(fid, jsonencode(s));
fclose(fid);
end

function s = tfstr(b)
if b
    s = 'true';
else
    s = 'false';
end
end

function mcp_fclose_safe(fid)
try
    if fid > 0
        fclose(fid);
    end
catch
end
end
