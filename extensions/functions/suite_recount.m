function r = suite_recount(logPath, runId, diskFiles)
%SUITE_RECOUNT Recompute suite accounts from the durable log, not from one line.
%   r = suite_recount(logPath, runId, diskFiles)
%   diskFiles: cell of relative test names currently on disk (empty = skip that account).
%
%   A certification is normally spread over several resumed invocations of one runId, so
%   the last COVERAGE/CERTIFIED line describes only the round that just ended. This walks
%   every END record and keeps, per file, only its LAST one: a file that failed in round 1
%   and passed in round 3 is green, and a file that never appears is missing.

r = struct('ok', false, 'reasons', {{}}, 'filesPass', 0, 'filesInc', 0, 'filesBad', 0, ...
    'filesSeen', 0, 'filesDisk', numel(diskFiles), 'casesTotal', 0, 'fails', 0, 'incs', 0, ...
    'rounds', 0, 'mutated', 0, 'nonGreen', {{}}, 'missing', {{}}, 'extra', {{}}, ...
    'digestRun', '', 'digests', {{}}, 'nDigests', 0, 'lastDigest', '', ...
    'lines', 0, 'otherRun', 0);
if exist(logPath, 'file') ~= 2
    r.reasons{end+1} = sprintf('NO_LOG:%s', strrep(logPath, '\', '/')); %#ok<AGROW>
    return
end
L = regexp(mcp_read_text(logPath), '\r?\n', 'split');
PV = '^(RUN|BEGIN|END|COVERAGE|CERTIFIED|NOT_CERTIFIED|PROGRESS|RUNERR)\|';
last = containers.Map('KeyType', 'char', 'ValueType', 'any');
for k = 1:numel(L)
    s = strtrim(L{k});
    if isempty(s), continue; end
    if isempty(regexp(s, [PV runId '\|'], 'once'))
        if ~isempty(regexp(s, PV, 'once')), r.otherRun = r.otherRun + 1; end
        continue
    end
    r.lines = r.lines + 1;
    if startsWith(s, ['END|' runId '|'])
        f = strsplit(s, '|');
        % END|runId|file|STATUS|cases=..|fail=..|inc=..|sec=..|msg
        if numel(f) < 4, continue; end
        last(f{3}) = struct('status', f{4}, 'cases', fldnum(s, 'cases='), ...
            'fail', fldnum(s, 'fail='), 'inc', fldnum(s, 'inc='));
    elseif startsWith(s, ['COVERAGE|' runId '|'])
        r.rounds = r.rounds + 1;
        if ~isempty(regexp(s, 'tree=MUTATED', 'once'))
            r.mutated = r.mutated + 1;
        end
    elseif startsWith(s, ['RUN|' runId '|'])
        t = regexp(s, 'TREE=([0-9a-z]+)', 'tokens', 'once');
        if ~isempty(t)
            r.digestRun = char(t{1});
            r.digests{end+1} = char(t{1}); %#ok<AGROW>
        end
    end
end
if ~isempty(r.digests)
    r.lastDigest = r.digests{end};
    r.nDigests = numel(unique(r.digests));
end
names = keys(last);
r.filesSeen = numel(names);
for k = 1:numel(names)
    e = last(names{k});
    r.fails = r.fails + e.fail;
    r.incs = r.incs + e.inc;
    switch e.status
        case 'PASS'
            r.filesPass = r.filesPass + 1;
            r.casesTotal = r.casesTotal + e.cases;
        case 'INC'
            r.filesInc = r.filesInc + 1;
            r.casesTotal = r.casesTotal + e.cases;
            r.nonGreen{end+1} = sprintf('%s INC inc=%g', names{k}, e.inc); %#ok<AGROW>
        otherwise
            r.filesBad = r.filesBad + 1;
            r.casesTotal = r.casesTotal + e.cases;
            r.nonGreen{end+1} = sprintf('%s %s fail=%g', names{k}, e.status, e.fail); %#ok<AGROW>
    end
end
if r.filesSeen == 0
    r.reasons{end+1} = 'NO_END_RECORDS'; %#ok<AGROW>
end
if r.filesBad > 0 || r.fails > 0
    r.reasons{end+1} = sprintf('FAILURES=%d', r.filesBad); %#ok<AGROW>
end
if r.mutated > 0
    r.reasons{end+1} = sprintf('TREE_MUTATED_ROUNDS=%d', r.mutated); %#ok<AGROW>
end
if r.filesDisk > 0
    diskN = cellfun(@normName, cellstr(string(diskFiles(:))), 'UniformOutput', false);
    seen = cellfun(@normName, names, 'UniformOutput', false);
    for k = 1:numel(names)
        if ~any(strcmp(diskN, seen{k}))
            r.extra{end+1} = names{k}; %#ok<AGROW>
        end
    end
    for k = 1:numel(diskN)
        if ~any(strcmp(diskN{k}, seen))
            r.missing{end+1} = char(diskFiles{k}); %#ok<AGROW>
        end
    end
    if ~isempty(r.missing)
        r.reasons{end+1} = sprintf('NOT_RUN=%d', numel(r.missing)); %#ok<AGROW>
    end
    if ~isempty(r.extra)
        r.reasons{end+1} = sprintf('RUN_NOT_ON_DISK=%d', numel(r.extra)); %#ok<AGROW>
    end
end
r.ok = isempty(r.reasons) && r.filesSeen > 0 && r.filesDisk > 0;
if ~r.ok && isempty(r.reasons)
    r.reasons{end+1} = 'NO_FILES_DISCOVERED'; %#ok<AGROW>
end
end

function n = normName(p)
n = lower(strrep(strtrim(char(p)), '\', '/'));
end

function c = num2cellstr(v)
c = cellstr(string(v(:)));
end

function v = fldnum(s, tag)
v = 0;
t = regexp(s, [tag '([0-9.]+)'], 'tokens', 'once');
if ~isempty(t), v = str2double(t{1}); end
end
