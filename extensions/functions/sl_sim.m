function sl_sim(modelPath, simTime, paramJson, outDir, keepInSession)
%SL_SIM Load, configure, simulate and retrieve a Simulink model in one call.
%   modelPath   : absolute path to a .slx, or a model name findable on the path.
%   simTime     : StopTime ('' = keep the model's own value).
%   paramJson   : {"set":[{"block":"CPA","name":"Numerator","value":"[1 -0.5]"},
%                          {"block":"","name":"SaveOutput","value":"on"}]}
%                 a block of "" applies set_param to the model itself.
%   outDir      : folder for the per-signal CSVs ('' = <extensions>/exports/sl_...)
%   keepInSession:'1' (default) also copies each signal into the base workspace as
%                 <name>__t and <name>__y so sl_compare / get_variable can reach
%                 them without going through disk.
%
%   WHY (measured 2026-09-19): the library is not searchable until
%   load_system('simulink') has run, and a To Workspace trace carries one extra
%   leading sample versus a MATLAB array of the same horizon - a naive same-index
%   comparison missed the design doc's 0.1% area gate by reporting 5.4e-3 where
%   the true agreement is 2e-14. This tool therefore always reports the time grid
%   next to the values, and sl_compare searches integer shifts before judging.
%   Prints only; returns nothing so no stray `ans` is echoed.
if nargin < 5, keepInSession = ''; end
if nargin < 4, outDir = ''; end
if nargin < 3, paramJson = ''; end
if nargin < 2, simTime = ''; end
modelPath = mcp_str(modelPath);
if isempty(modelPath)
    error('sl_sim:badArgs', '[sl_sim:badArgs] modelPath is required');
end
mcp_tool_log('sl_sim', sprintf('%s stop=%s', modelPath, mcp_str(simTime)));
prevW = warning('off', 'all');
rest = onCleanup(@() warning(prevW)); %#ok<NASGU>
try
    load_system('simulink');
catch
end
mdl = modelPath;
[fp, fn, ext] = fileparts(modelPath);
if strcmpi(ext, '.slx') || strcmpi(ext, '.slx.bak') || (~isempty(ext) && ~isempty(fp) && exist(modelPath, 'file') == 2)
    try
        close_system(fn, 0);
    catch
    end
    si = load_system(modelPath);
    mdl = fn;
else
    try
        load_system(modelPath);
    catch e
        error('sl_sim:load', '[sl_sim:load] cannot load "%s": %s', modelPath, e.message);
    end
end
fprintf('model:     %s (%s)\n', mdl, tern(isempty(ext), 'by name', fullfile(fp, [fn ext])));
try
    fprintf('blocks:    %d | update-diagram done\n', numel(find_system(mdl, 'LookUnderMasks','all', 'FollowLinks','on', 'Type','Block')));
catch e
    fprintf('block scan skipped: %s\n', e.message);
end
applied = 0;
failed = {};
if ~isempty(strtrim(mcp_str(paramJson)))
    pj = mcp_str(paramJson);
    try
        spec = jsondecode(pj);
    catch e
        error('sl_sim:badParam', '[sl_sim:badParam] paramJson must decode to an object: %s', e.message);
    end
    if isfield(spec, 'set')
        s = spec.set;
        if ~iscell(s)
            if isstruct(s)
                s = num2cell(s);
            else
                s = {s};
            end
        end
        for k = 1:numel(s)
            it = s{k};
            blk = '';
            nm = '';
            val = '';
            if isstruct(it)
                if isfield(it, 'block'), blk = char(string(it.block)); end
                if isfield(it, 'name'), nm = char(string(it.name)); end
                if isfield(it, 'value'), val = it.value; end
            end
            if isempty(nm)
                failed{end+1} = sprintf('#%d missing name', k); %#ok<AGROW>
                continue
            end
            target = mdl;
            if ~isempty(blk)
                target = [mdl '/' blk];
            end
            if isnumeric(val) || islogical(val)
                vs = mat2str(val);
            else
                vs = char(string(val));
            end
            try
                set_param(target, nm, vs);
                applied = applied + 1;
            catch e
                failed{end+1} = sprintf('%s :: %s=%s -> %s', target, nm, vs, strtrim(replace(e.message, newline, ' '))); %#ok<AGROW>
            end
        end
    end
    fprintf('set_param: applied=%d failed=%d\n', applied, numel(failed));
    for k = 1:min(6, numel(failed))
        fprintf('  SETFAIL %s\n', failed{k});
    end
end
st = mcp_str(simTime);
stopApplied = '';
if ~isempty(st)
    try
        v = str2double(st);
        if isnan(v)
            v = st;
        end
        set_param(mdl, 'StopTime', mat2str(v));
        stopApplied = mat2str(v);
    catch e
        fprintf('STOPTIME_FAIL %s\n', e.message);
    end
end
t0 = tic;
so = sim(mdl);
el = toc(t0);
fprintf('sim:       %.3f s (StopTime=%s)\n', el, tern(isempty(stopApplied), 'model default', stopApplied));
if isempty(outDir) || isempty(strtrim(mcp_str(outDir)))
    outDir = fullfile(mcp_ext_root(), 'exports', ...
        sprintf('sl_%s', char(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))));
else
    outDir = mcp_str(outDir);
end
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
tw = find_system(mdl, 'LookUnderMasks','all', 'FollowLinks','on', 'BlockType','ToWorkspace');
fprintf('To Workspace blocks found: %d\n', numel(tw));
keep = ~any(strcmp(mcp_str(keepInSession), {'0','false','no','off'}));
nSig = 0;
for k = 1:numel(tw)
    try
        vname = char(get_param(tw{k}, 'VariableName'));
    catch
        vname = '';
    end
    if isempty(vname)
        continue
    end
    try
        raw = so.get(vname);
    catch e
        fprintf('  %-18s MISSING in output (%s)\n', vname, e.identifier);
        continue
    end
    res = mcp_as_timeseries(raw);
    if isempty(res.t)
        fprintf('  %-18s skipped (class=%s, no time column found)\n', vname, class(raw));
        continue
    end
    nSig = nSig + 1;
    f = fullfile(outDir, [vname '.csv']);
    writematrix([res.t(:), res.y(:)], f);
    dt = NaN;
    if numel(res.t) > 1
        dt = median(diff(res.t(:)));
    end
    fprintf('  %-18s n=%-8d t0=%-12g dt=%-12g end=%-12g mean=%-14g min=%g max=%g\n', ...
        vname, numel(res.y), res.t(1), dt, res.t(end), mean(res.y(:)), min(res.y(:)), max(res.y(:)));
    fprintf('           -> %s\n', f);
    if keep
        try
            assignin('base', [vname '__t'], res.t(:));
            assignin('base', [vname '__y'], res.y(:));
        catch
        end
    end
end
try
    lo = so.get('logsout');
    if ~isempty(lo) && isa(lo, 'Simulink.SimulationData.Dataset')
        fprintf('logsout elements: %d\n', lo.numElements);
        for e = 1:lo.numElements
            el2 = lo{e};
            nSig = nSig + 1;
            f = fullfile(outDir, sprintf('log_%d_%s.csv', e, strrep(el2.Name, '/', '_')));
            writematrix([el2.Values.Time(:), el2.Values.Data(:)], f);
            fprintf('  %-18s n=%-8d -> %s\n', el2.Name, numel(el2.Values.Data), f);
            if keep
                try
                    assignin('base', [strrep(el2.Name,'/','_') '__t'], el2.Values.Time(:));
                    assignin('base', [strrep(el2.Name,'/','_') '__y'], el2.Values.Data(:));
                catch
                end
            end
        end
    end
catch
end
fprintf('signals exported: %d into %s\n', nSig, outDir);
if keep && nSig > 0
    fprintf('base-workspace copies available as <name>__t / <name>__y\n');
end
fprintf('next: sl_compare("ws:yourMatlabSignal","ws:simout__y","") to judge them with shift search\n');
rest = [];
warning(prevW);
end

function r = mcp_as_timeseries(v)
r = struct('t', [], 'y', []);
try
    if isa(v, 'timeseries')
        r.t = v.Time(:);
        r.y = double(v.Data(:));
    elseif istimetable(v)
        r.t = seconds(v.Time);
        r.y = double(table2array(v(:, 1)));
    elseif istable(v)
        cn = v.Properties.VariableNames;
        ti = find(contains(lower(cn), 'time'), 1);
        if isempty(ti)
            ti = 1;
        end
        yi = find(contains(lower(cn), 'data'), 1);
        if isempty(yi), yi = mod(ti, numel(cn)) + 1; end
        r.t = double(v.(cn{ti})(:));
        r.y = double(v.(cn{yi})(:));
    elseif isstruct(v) && isfield(v, 'time') && isfield(v, 'signals')
        r.t = v.time(:);
        r.y = double(v.signals(1).values(:));
    elseif isnumeric(v) && isvector(v)
        r.y = double(v(:));
        r.t = (1:numel(v))';
    end
catch
end
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
