function session_reset(what, confirm)
%SESSION_RESET Bring the shared MATLAB session back to a known state.
%   what    : JSON array or comma list from figures|models|pool|timers|vars|all.
%             "" defaults to figures,models,pool.
%   confirm : literal "yes" to act; anything else prints the plan only.
%   WHY: every MCP tool shares ONE stateful session. Measured consequences:
%   `clear` of 80 variables left 6 Simulink models loaded and returned almost no
%   memory (8.81 -> 8.79 GiB); a crashed multi-step script left its parpool
%   running; failed UI probes left 3 invisible uifigures behind. There is no
%   engine-restart tool, so without this the only remedy is restarting the client.
%   `vars` is deliberately opt-in and never part of "all": wiping the base
%   workspace can destroy results another tool still needs.
%   Prints only; returns nothing.
if nargin < 2, confirm = ''; end
if nargin < 1, what = ''; end
mcp_tool_log('session_reset', mcp_str(what));
raw = mcp_str(what);
rawT = strtrim(raw);
items = {};
if isempty(rawT)
    items = {'figures', 'models', 'pool'};
elseif rawT(1) == '['
    try
        a = jsondecode(rawT);
        items = cellstr(string(a(:)'));
    catch e
        error('session_reset:badWhat', '[session_reset:badWhat] %s', e.message);
    end
else
    items = strtrim(strsplit(lower(rawT), ','));
end
if any(strcmp(items, 'all'))
    items = [items, {'figures', 'models', 'pool', 'timers'}];
end
items = unique(items(:)');
doit = strcmp(lower(strtrim(mcp_str(confirm))), 'yes');
if ~doit
    fprintf('DRY RUN - would reset: %s (rerun with confirm="yes")\n', strjoin(items, ', '));
end

if any(strcmp(items, 'figures'))
    f = findall(0, 'Type', 'figure');
    fprintf('figures: %d before', numel(f));
    if doit
        for k = 1:numel(f)
            try
                delete(f(k));
            catch
            end
        end
    end
    fprintf(' -> %d after\n', numel(findall(0, 'Type', 'figure')));
end
if any(strcmp(items, 'timers'))
    t = timerfindall;
    fprintf('timers:  %d before', numel(t));
    if doit
        for k = 1:numel(t)
            try
                stop(t(k));
                delete(t(k));
            catch
            end
        end
    end
    fprintf(' -> %d after (the MCP checkpoint timer is included; re-arm with enable_checkpoint)\n', numel(timerfindall));
end
if any(strcmp(items, 'models'))
    n0 = 0;
    names = {};
    try
        names = find_system('type', 'block_diagram');
        n0 = numel(names);
    catch
    end
    fprintf('models:  %d loaded', n0);
    if doit
        for k = 1:numel(names)
            try
                close_system(names{k}, 0);
            catch
            end
        end
    end
    n1 = 0;
    try
        n1 = numel(find_system('type', 'block_diagram'));
    catch
    end
    fprintf(' -> %d after\n', n1);
end
if any(strcmp(items, 'pool'))
    p = gcp('nocreate');
    if isempty(p)
        fprintf('pool:    none\n');
    else
        fprintf('pool:    %d workers before', p.NumWorkers);
        if doit
            try
                delete(p);
            catch e
                fprintf(' (delete failed: %s)', e.message);
            end
        end
        q = gcp('nocreate');
        fprintf(' -> %s after\n', tern(isempty(q), 'none', 'still present'));
    end
end
if any(strcmp(items, 'vars'))
    w = evalin('base', 'who');
    fprintf('vars:    %d before', numel(w));
    if doit
        try
            evalin('base', 'clear');
        catch e
            fprintf(' (clear failed: %s)', e.message);
        end
    end
    fprintf(' -> %d after\n', numel(evalin('base', 'who')));
else
    fprintf('vars:    untouched (pass "vars" in what to clear the base workspace)\n');
end
try
    m = memory;
    fprintf('memory:  %.2f GiB used by MATLAB. NOTE: MATLAB rarely returns freed heap to the OS, so a big drop needs an engine restart.\n', ...
        m.MemUsedMATLAB / 2^30);
catch
end
if ~doit
    fprintf('nothing was changed (dry run)\n');
end
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
