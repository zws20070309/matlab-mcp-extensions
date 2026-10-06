function session_info(level)
%SESSION_INFO One-shot situational snapshot of the live MATLAB session.
%   level: '' or 'basic' -> version, current folder, open figures, all timers
%          (to spot stale simulation timers left by a closed GUI), checkpoint
%          file state. 'full' -> also appends the env_report capacity view
%          (cores, memory, pool, loaded models, GPU, jobs).
%   Read-only; never starts anything.

if nargin < 1, level = ''; end
lv = lower(strtrim(mcp_str(level)));
fprintf('MATLAB %s\n', version);
mcp_tool_log('session_info', lv);
fprintf('pwd: %s\n', pwd);

figs = findall(0, 'Type', 'figure');
fprintf('open figures: %d\n', numel(figs));
for k = 1:numel(figs)
    nm = '';
    try
        nm = char(string(figs(k).Name));
    catch
    end
    vis = '';
    try
        vis = sprintf(' visible=%s', figs(k).Visible);
    catch
    end
    fprintf('  [%d] "%s" (%s)%s\n', figs(k).Number, nm, class(figs(k)), vis);
end

tm = timerfindall;
fprintf('timers: %d\n', numel(tm));
for k = 1:numel(tm)
    fprintf('  "%s": %s, period=%.3f s, executed=%d\n', ...
        tm(k).Name, tm(k).Running, tm(k).Period, tm(k).TasksExecuted);
end

cp = fullfile(mcp_ext_root(), 'checkpoint.mat');
if exist(cp, 'file') == 2
    d = dir(cp);
    fprintf('checkpoint: %s (%d bytes, %s)\n', cp, d.bytes, d.date);
else
    fprintf('checkpoint: none\n');
end
if any(strcmp(lv, {'full', 'all', 'env'}))
    fprintf('--- capacity view (env_report) ---\n');
    env_report('jobs');
end
end
