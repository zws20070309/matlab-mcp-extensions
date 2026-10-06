function list_jobs(state, limit, tagContains)
%LIST_JOBS List jobs known to the extension layer, filtered and bounded.
%   state       : all|running|queued|finished|failed|cancelled|unfinished ('' = all)
%   limit       : max rows, newest first ('' = 25). Unbounded, this printed every
%                 job ever submitted and swamped the tool output on a real
%                 project (25 rows by the end of a single QA session).
%   tagContains : substring of the job tag. A sweep writes its sweepId into every
%                 member job's tag, so this lists one sweep's jobs.
if nargin < 3, tagContains = ''; end
if nargin < 2, limit = ''; end
if nargin < 1, state = ''; end
ROOT = mcp_ext_root();
state = lower(strtrim(mcp_str(state)));
tagContains = mcp_str(tagContains);
nMax = mcp_num(limit, 25);
if ~isfinite(nMax) || nMax < 1
    nMax = 25;
end
mcp_tool_log('list_jobs', sprintf('state=%s limit=%g tag=%s', state, nMax, tagContains));
dd = fullfile(ROOT, 'jobs');
if ~exist(dd, 'dir')
    fprintf('no jobs yet (%s does not exist)\n', dd);
    return;
end
d = dir(dd);
d = d([d.isdir]);
names = {d.name};
names = names(~ismember(names, {'.', '..'}));
if isempty(names)
    fprintf('no jobs yet\n');
    return;
end
% dir() is alphabetical and jobIds begin with a timestamp, so reversing the list
% gives newest-first without contacting the cluster at all.
names = names(end:-1:1);
liveTags = {};
liveStates = {};
try
    c = parcluster('local');
    js = c.Jobs;
    for k = 1:numel(js)
        try
            liveTags{end+1} = char(js(k).Tag); %#ok<AGROW>
            [st, ~, ~] = mcp_job_state(js(k));
            liveStates{end+1} = st; %#ok<AGROW>
        catch
        end
    end
catch
end
fprintf('%-30s %-12s %-8s %-9s %s\n', 'jobId', 'state', 'done', 'elapsed', 'function');
shown = 0;
seen = 0;
tally = struct();
for k = 1:numel(names)
    jobDir = fullfile(dd, names{k});
    fn = '?';
    utag = '';
    metaPath = fullfile(jobDir, 'meta.json');
    if exist(metaPath, 'file')
        try
            meta = jsondecode(fileread(metaPath));
            fn = char(meta.function);
            if isfield(meta, 'userTag')
                utag = char(string(meta.userTag));
            end
            if isfield(meta, 'tag')
                utag = [utag ' ' char(string(meta.tag))];
            end
        catch
        end
    end
    idx = find(strcmp(liveTags, ['mcpjob:' names{k}]), 1);
    if ~isempty(idx)
        st = liveStates{idx};
    else
        st = 'n/a';
    end
    el = '';
    donePath = fullfile(jobDir, 'done.json');
    if exist(donePath, 'file')
        doneFlag = 'yes';
        % done.json is written by the runner itself and is the authoritative
        % terminal record; the live cluster handle can misclassify a successful
        % job (see mcp_job_state). Only defer to the handle while the job is
        % genuinely still in flight.
        try
            dn = jsondecode(fileread(donePath));
            if isfield(dn, 'status') && ~any(strcmp(st, {'queued', 'running'}))
                st = char(dn.status);
            end
            if isfield(dn, 'elapsedSec')
                el = sprintf('%.1fs', double(dn.elapsedSec));
            end
        catch
        end
    else
        doneFlag = 'no';
    end
    seen = seen + 1;
    fld = regexprep(st, '[^A-Za-z0-9]', '_');
    if ~isfield(tally, fld)
        tally.(fld) = 0;
    end
    tally.(fld) = tally.(fld) + 1;
    if ~isempty(state) && ~any(strcmp(state, {'all', '*'}))
        if strcmp(state, 'unfinished')
            if any(strcmp(st, {'finished', 'failed', 'cancelled'}))
                continue
            end
        elseif ~strcmp(state, st)
            continue
        end
    end
    if ~isempty(tagContains) && ~contains(utag, tagContains)
        continue
    end
    if shown >= nMax
        continue
    end
    shown = shown + 1;
    fprintf('%-30s %-12s %-8s %-9s %s\n', names{k}, st, doneFlag, el, fn);
end
tf = fieldnames(tally);
parts = cell(1, numel(tf));
for k = 1:numel(tf)
    parts{k} = sprintf('%s=%d', tf{k}, tally.(tf{k}));
end
fprintf('%d listed of %d matching jobs | all states: %s\n', shown, seen, strjoin(parts, ' '));
if shown < seen
    fprintf('(raise limit to see more of the matching jobs)\n');
end
end
