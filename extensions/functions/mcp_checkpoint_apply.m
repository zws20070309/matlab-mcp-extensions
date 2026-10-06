function mcp_checkpoint_apply(chkPath)
%MCP_CHECKPOINT_APPLY One atomic base-workspace snapshot. Timer callback.
%   Never surfaces errors or warnings: a checkpoint failure must not disturb
%   the session, and anything this callback prints lands inside the output of
%   whatever unrelated tool call happens to be in flight (verified: the
%   per-tick "figure saved to checkpoint.mat.tmp" warning polluted two
%   separate evaluate_matlab_code results).
%
%   Graphics/UI/handle objects are skipped rather than saved: serializing them
%   is what produced that warning and inflated checkpoint.mat by ~15 KiB per
%   tick in a 3-figure session. Variables over 256 MiB are skipped and recorded.
%
%   Besides overwriting chkPath, each snapshot is archived under
%   <extensions>\checkpoint_history\ so that restore_checkpoint can reach a
%   state older than one cadence. Previously checkpoint.mat was the only slot
%   and was clobbered every tick, which made "restore" unable to recover a
%   variable deleted more than one period ago.

try
    info = evalin('base', 'whos');
    keep = {info.name};
    keep = keep(~strcmp(keep, 'ans'));
    skipped = {};
    S = struct();
    for k = 1:numel(keep)
        name = keep{k};
        if info(k).bytes > 268435456
            skipped{end+1} = sprintf('%s(too large: %d MiB)', name, round(info(k).bytes/1048576)); %#ok<AGROW>
            continue
        end
        try
            v = evalin('base', name);
        catch
            skipped{end+1} = sprintf('%s(unsavable)', name); %#ok<AGROW>
            continue
        end
        if mcp_chk_unsavable(v)
            skipped{end+1} = sprintf('%s(%s)', name, mcp_chk_reason(v)); %#ok<AGROW>
            continue
        end
        S.(name) = v;
    end
    keep = setdiff(keep, cellfun(@(s) strtok(s, '('), skipped, 'UniformOutput', false), 'stable');
    stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    meta = struct('savedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
        'stamp', stamp, 'variables', {keep}, 'skipped', {skipped});
    S.mcpCheckpointMeta = meta;
    tmp = [chkPath '.tmp'];
    % Belt and braces: no warning from deep inside a saved struct/cell may
    % escape the timer callback.
    prevW = warning('off', 'all');
    r = onCleanup(@() warning(prevW));
    ok = true;
    try
        save(tmp, '-struct', 'S');
    catch
        ok = false;
    end
    r = [];
    warning(prevW);
    if ~ok
        if exist(tmp, 'file')
            delete(tmp);
        end
        return
    end
    if exist(chkPath, 'file')
        delete(chkPath);
    end
    if exist(tmp, 'file')
        movefile(tmp, chkPath);
    end
    mcp_chk_archive(chkPath, stamp);
catch
    % checkpointing must never break the session it protects
end
end

function mcp_chk_archive(chkPath, stamp)
% Copy this snapshot into the history folder and prune it.
try
    hd = fullfile(mcp_ext_root(), 'checkpoint_history');
    if ~exist(hd, 'dir')
        mkdir(hd);
    end
    dst = fullfile(hd, ['checkpoint_' stamp '.mat']);
    if ~exist(chkPath, 'file')
        return
    end
    d = dir(dst);
    if isempty(d)
        copyfile(chkPath, dst);
    end
    % Keep the newest 20 archives and at most ~200 MiB in total.
    h = dir(fullfile(hd, 'checkpoint_*.mat'));
    if numel(h) > 20
        [~, ix] = sort([h.datenum]);
        drop = ix(1:(numel(ix) - 20));
        for k = 1:numel(drop)
            delete(fullfile(hd, h(drop(k)).name));
        end
    end
    h = dir(fullfile(hd, 'checkpoint_*.mat'));
    total = sum([h.bytes]);
    while total > 209715200 && numel(h) > 1
        [~, ix] = sort([h.datenum]);
        delete(fullfile(hd, h(ix(1)).name));
        h = dir(fullfile(hd, 'checkpoint_*.mat'));
        total = sum([h.bytes]);
    end
catch
end
end

function tf = mcp_chk_unsavable(v)
% True only for graphics/UI/handle OBJECTS.
%
% On R2025a figure()/uifigure()/UI controls return objects, and those are what
% made the old snapshot warn on every tick and grow unbounded (98,435 ->
% 114,177 bytes in ~4 minutes with two figures). Testing anything narrower was
% tried and rejected: an element-wise ishandle() pass dropped ordinary numeric
% data (a [1 2;3 4] matrix was reported as a graphics handle), and a recursive
% struct/cell scan dropped whole data structures merely because they contained
% the numbers 1, 2 or 3 while figures 1-3 were open. Both silently destroyed
% user data, which is worse than the problem being solved, so the rule is now
% "is it a graphics object" and nothing else.
tf = false;
try
    if isobject(v)
        tf = ~isempty(regexp(class(v), ...
            '^(matlab\.ui|matlab\.graphics|simulink\.|handle\.)', 'once'));
    end
catch
end
end

function s = mcp_chk_reason(v)
s = 'graphics object, not snapshotted';
try
    s = sprintf('%s object, not snapshotted', class(v));
catch
end
end
