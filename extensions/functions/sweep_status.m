function sweep_status(sweepId, tail)
%SWEEP_STATUS One compact poll for a whole parameter sweep.
%   sweepId: id printed by submit_sweep; '' lists the 10 newest sweeps.
%   tail   : max rows to print, '' = 25.
%   Deliberately FILE-BASED (meta.json / done.json only, never the cluster
%   handle), because reading task properties of a running job makes MATLAB emit
%   "此批处理作业的日志可能不完整..." into whatever tool call is in flight. Use
%   job_status(jobId) when you need the live cluster view of one job.
ROOT = mcp_ext_root();
if nargin < 2, tail = ''; end
sweepId = mcp_str(sweepId);
nMax = mcp_num(tail, 25);
if ~isfinite(nMax) || nMax < 1
    nMax = 25;
end
mcp_tool_log('sweep_status', sweepId);
d = fullfile(ROOT, 'sweeps');
if isempty(sweepId)
    if ~exist(d, 'dir')
        fprintf('no sweeps yet\n');
        return
    end
    dd = dir(fullfile(d, 'sweep_*.json'));
    if isempty(dd)
        fprintf('no sweeps yet (%s empty)\n', d);
        return
    end
    [~, ix] = sort([dd.datenum], 'descend');
    dd = dd(ix);
    fprintf('%-28s %-22s %s\n', 'sweepId', 'created', 'function');
    for k = 1:min(10, numel(dd))
        try
            m = jsondecode(fileread(fullfile(dd(k).folder, dd(k).name)));
            fprintf('%-28s %-22s %s (count=%d)\n', m.sweepId, m.createdAt, m.fnName, m.count);
        catch
            fprintf('%-28s ?\n', dd(k).name);
        end
    end
    fprintf('next: sweep_status("<sweepId>", "")\n');
    return
end
mf = fullfile(d, [sweepId '.json']);
if ~exist(mf, 'file')
    error('sweep_status:notFound', '[sweep_status:notFound] No manifest for sweepId %s (list with sweep_status(""))', sweepId);
end
m = jsondecode(fileread(mf));
% Sanitize, never cellstr(string(...)) raw: a null slot in the manifest decodes
% back to [] and string({[]}) throws, killing the whole poll (same class as the
% mcp_sweep_core submit-side crash fixed 2026-10-28).
idsRaw = m.jobIds;
if ~iscell(idsRaw), idsRaw = {idsRaw}; end
ids = cell(1, numel(idsRaw));
for k = 1:numel(idsRaw)
    v = idsRaw{k};
    if ischar(v) || isstring(v)
        ids{k} = char(string(v));
    else
        ids{k} = '';
    end
end
fprintf('sweepId: %s   name: %s   fn: %s   created: %s\n', m.sweepId, m.name, m.fnName, m.createdAt);
fprintf('jobs: %d\n', numel(ids));
count = struct('finished', 0, 'failed', 0, 'cancelled', 0, 'running', 0, 'queued', 0, 'other', 0);
el = [];
fails = {};
for k = 1:numel(ids)
    jobDir = fullfile(ROOT, 'jobs', ids{k});
    if isempty(ids{k})
        state = 'not-submitted';
        e = NaN;
        errId = '';
        summ = '';
        if k <= nMax
            fprintf('  [%2d] %-30s %-10s %8s %s\n', k, '(empty slot)', state, '-', summ);
        end
        count.other = count.other + 1;
        continue
    end
    state = 'no-dir';
    e = NaN;
    errId = '';
    summ = '';
    dp = fullfile(jobDir, 'done.json');
    mp = fullfile(jobDir, 'meta.json');
    if exist(mp, 'file')
        try
            mt = jsondecode(fileread(mp));
            state = char(mt.status);
        catch
        end
    end
    if exist(dp, 'file')
        try
            dn = jsondecode(fileread(dp));
            state = char(dn.status);
            if isfield(dn, 'elapsedSec'), e = double(dn.elapsedSec); end
            % Field pair aligned: the old condition tested 'message' but read
            % 'identifier', which threw (and silently dropped the error id)
            % on any record carrying message without identifier.
            if isfield(dn, 'identifier'), errId = char(string(dn.identifier)); end
            if isfield(dn, 'outSummary')
                s = char(string(dn.outSummary));
                if numel(s) > 70, s = [s(1:70) '...']; end
                summ = s;
            end
        catch
        end
    else
        if any(strcmp(state, {'running', 'queued'}))
        else
            state = [state '/in-flight'];
        end
    end
    fn = 'other';
    if strcmp(state, 'finished'), fn = 'finished';
    elseif strcmp(state, 'failed'), fn = 'failed';
    elseif strcmp(state, 'cancelled'), fn = 'cancelled';
    elseif contains(state, 'running'), fn = 'running';
    elseif contains(state, 'queued'), fn = 'queued';
    end
    count.(fn) = count.(fn) + 1;
    if isfinite(e), el(end+1) = e; end %#ok<AGROW>
    if strcmp(fn, 'failed') && numel(fails) < 10
        fails{end+1} = sprintf('%s  %s', ids{k}, errId); %#ok<AGROW>
    end
    if k <= nMax
        fprintf('  [%2d] %-30s %-10s %8s %s\n', k, ids{k}, state, ...
            tern(isfinite(e), sprintf('%.1fs', e), '-'), summ);
    end
end
if numel(ids) > nMax
    fprintf('  ... %d rows hidden (tail=%g)\n', numel(ids) - nMax, nMax);
end
done = count.finished + count.failed + count.cancelled;
% Terminal math must not count slots that were never submitted (an invalid
% params element leaves an empty id): they are shown as rows but are not work.
nReal = nnz(~cellfun(@isempty, ids));
fprintf('SUMMARY finished=%d failed=%d cancelled=%d running=%d queued=%d other=%d  -> %d/%d terminal\n', ...
    count.finished, count.failed, count.cancelled, count.running, count.queued, count.other, done, nReal);
if ~isempty(el)
    tot = sum(el);
    fprintf('compute: total=%.1fs median=%.2fs min=%.2fs max=%.2fs (worker time only, excludes the ~10-15 s per-job boot)\n', ...
        tot, median(el), min(el), max(el));
    if done < nReal
        remaining = nReal - done;
        cores = feature('numcores');
        fprintf('eta: %d jobs left, ~%.0f s of compute / %d cores -> >= %.0f s plus queue\n', ...
            remaining, tot / max(done, 1) * remaining, cores, ...
            (tot / max(done, 1) * remaining) / cores);
    end
end
for k = 1:numel(fails)
    fprintf('FAIL %s\n', fails{k});
end
if count.failed > 0
    fprintf('drill in: job_status("<jobId>") shows the stack line and run.log tail\n');
end
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
