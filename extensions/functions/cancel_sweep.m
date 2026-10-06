function cancel_sweep(sweepId, confirm)
%CANCEL_SWEEP Cancel every not-yet-terminal job of a sweep.
%   sweepId: from submit_sweep; '' lists sweeps like sweep_status('').
%   confirm: MUST be the literal text 'yes'. Any other value (including '')
%            prints what would be cancelled and does nothing, because
%            cancelling is destructive and this tool is often reached by an
%            agent that mis-typed an id.
ROOT = mcp_ext_root();
sweepId = mcp_str(sweepId);
confirm = lower(strtrim(mcp_str(confirm)));
mf = fullfile(ROOT, 'sweeps', [sweepId '.json']);
if ~exist(mf, 'file')
    error('cancel_sweep:notFound', '[cancel_sweep:notFound] No manifest for sweepId %s (list with sweep_status(""))', sweepId);
end
m = jsondecode(fileread(mf));
ids = cellstr(string(m.jobIds))';
victims = {};
for k = 1:numel(ids)
    dp = fullfile(ROOT, 'jobs', ids{k}, 'done.json');
    if exist(dp, 'file')
        continue;   % terminal already; cancelling a finished job is a no-op at best
    end
    victims{end+1} = ids{k}; %#ok<AGROW>
end
if isempty(victims)
    fprintf('sweep %s: nothing to cancel (all %d jobs already terminal)\n', sweepId, numel(ids));
    return
end
if ~strcmp(confirm, 'yes')
    fprintf('DRY RUN - %d jobs would be cancelled in sweep %s:\n', numel(victims), sweepId);
    for k = 1:min(20, numel(victims))
        fprintf('  %s\n', victims{k});
    end
    fprintf('rerun with confirm="yes" to actually cancel them.\n');
    return
end
cancelled = 0;
errs = {};
for k = 1:numel(victims)
    try
        cancel_job(victims{k});
        cancelled = cancelled + 1;
    catch e
        errs{end+1} = sprintf('%s %s', victims{k}, e.identifier); %#ok<AGROW>
    end
end
fprintf('sweep %s: cancelled=%d of %d non-terminal\n', sweepId, cancelled, numel(victims));
for k = 1:min(5, numel(errs))
    fprintf('  NOT CANCELLED %s\n', errs{k});
end
mcp_tool_log('cancel_sweep', sprintf('%s cancel=%d/%d', sweepId, cancelled, numel(victims)));
end
