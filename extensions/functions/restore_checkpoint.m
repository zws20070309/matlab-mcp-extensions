function restore_checkpoint(snapshot)
%RESTORE_CHECKPOINT Reload a base-workspace snapshot (latest, or a chosen one).
%   snapshot='' (default) loads <extensions>\checkpoint.mat, the newest
%   snapshot. Otherwise pass a timestamp stamp (yyyyMMdd_HHmmss, as reported by
%   the listing below) or a negative index into the history (-1 = newest,
%   -2 = one before that, ...), and the matching archive from
%   <extensions>\checkpoint_history\ is loaded instead. Existing base variables
%   with the same names are overwritten. Variables the snapshot deliberately
%   skipped (graphics objects, oversized arrays) are reported, not lost silently.

if nargin < 1, snapshot = ''; end
snapshot = strtrim(mcp_str(snapshot));
chkPath = fullfile(mcp_ext_root(), 'checkpoint.mat');
hd = fullfile(mcp_ext_root(), 'checkpoint_history');
hist = dir(fullfile(hd, 'checkpoint_*.mat'));
if ~isempty(hist)
    [~, ord] = sort([hist.datenum], 'descend');
    hist = hist(ord);
end
if ~isempty(snapshot) && ~strcmp(snapshot, 'latest')
    chosen = '';
    idx = str2double(snapshot);
    if ~isnan(idx) && idx < 0 && ~isempty(hist)
        j = min(numel(hist), -idx);
        chosen = fullfile(hd, hist(j).name);
    else
        for k = 1:numel(hist)
            if contains(hist(k).name, snapshot)
                chosen = fullfile(hd, hist(k).name);
                break
            end
        end
    end
    if isempty(chosen)
        fprintf('no snapshot matching "%s". Available (newest first):\n', snapshot);
        for k = 1:min(numel(hist), 20)
            stampK = regexp(hist(k).name, '\d{8}_\d{6}', 'once');
            if iscell(stampK) && ~isempty(stampK)
                stampK = stampK{1};
            end
            fprintf('  index=%d  stamp=%s  (%s)\n', -k, char(string(stampK)), hist(k).date);
        end
        error('restore_checkpoint:noMatch', '[restore_checkpoint:noMatch] No snapshot matching: %s', snapshot);
    end
    chkPath = chosen;
end
if ~exist(chkPath, 'file')
    error('restore_checkpoint:notFound', ...
        'No checkpoint file at %s. Enable checkpoints with enable_checkpoint first.', chkPath);
end
fprintf('source: %s\n', chkPath);
S = load(chkPath);
mcp_tool_log('restore_checkpoint', chkPath);
fields = fieldnames(S);
restored = 0;
failed = {};
savedAt = '';
skipped = {};
for k = 1:numel(fields)
    name = fields{k};
    if strcmp(name, 'mcpCheckpointMeta')
        m = S.mcpCheckpointMeta;
        if isfield(m, 'savedAt')
            savedAt = char(string(m.savedAt));
        end
        if isfield(m, 'skipped') && ~isempty(m.skipped)
            skipped = m.skipped;
        end
        continue
    end
    try
        assignin('base', name, S.(name));
        restored = restored + 1;
    catch e
        failed{end+1} = sprintf('%s(%s)', name, e.message); %#ok<AGROW>
    end
end

if isempty(savedAt)
    fprintf('restored %d variable(s) from a snapshot with no recorded timestamp\n', restored);
else
    ageTxt = '';
    try
        dt = datetime('now') - datetime(savedAt, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        % seconds(dt), not dt.Seconds: 'Seconds' is also a duration METHOD name,
        % so dot-indexing raises MATLAB:duration:IllegalDotMethod. That silently
        % swallowed this field until QA caught the age never being printed.
        ageTxt = sprintf(' (%.0f s ago)', seconds(dt));
    catch e
        ageTxt = sprintf(' (age unavailable: %s)', e.message);
    end
    fprintf('restored %d variable(s) from snapshot taken at %s%s\n', ...
        restored, savedAt, ageTxt);
end
if ~isempty(skipped)
    fprintf('not in snapshot (skipped at capture time): %s\n', strjoin(skipped, ', '));
end
if ~isempty(failed)
    fprintf('failed to restore: %s\n', strjoin(failed, ', '));
end

% Report the timer state as it actually is. The previous build printed
% "the checkpoint timer died with the previous session" unconditionally, which
% was false whenever MATLAB had not been restarted (verified: it fired twice in
% a session that was never restarted).
tm = timerfindall('Name', 'MCPCheckpointTimer');
if isempty(tm)
    fprintf('timer: not armed. Snapshots stop here; call enable_checkpoint to resume.\n');
else
    running = strcmp(cellstr(string({tm.Running})), 'on');
    if any(running)
        j = find(running, 1);
        fprintf('timer: armed and running (period %g s). No action needed.\n', tm(j).Period);
    else
        fprintf('timer: present but stopped. Call enable_checkpoint to re-arm it.\n');
    end
end
fprintf(['history: %d archived snapshot(s) in %s (newest 20 kept). ' ...
    'Pass snapshot=-N or a stamp to recover an older state.\n'], ...
    numel(hist), hd);
end
