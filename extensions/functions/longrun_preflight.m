function longrun_preflight(optsJson)
%LONGRUN_PREFLIGHT Decide whether this machine can start a long MATLAB run right now.
%   optsJson (all optional):
%     {"minFreeMB":2048, "maxMatlabProcs":2, "repoRoot":"D:/...", "testsDir":"D:/.../tests"}
%
%   WHY this is a tool and not a rule in someone's head: on this host a second
%   MATLAB started after a client timeout cost 1.5-1.59 GB while only 1.1-2.9 GB
%   was free, and the machine spent ~70 min paging - the suite looked hung but was
%   thrashing. The measured gate the source session converged on is "more than 2
%   MATLAB processes or less than 2 GB free means do not start". This checks it,
%   reports which MATLAB pid you are talking to (so a retry can be recognised as a
%   NEW session), and flags repo-root artifacts (slprj/, html/, derived/, gcache/,
%   *.slx_autosave, sl_proj.xml) that have previously turned an otherwise green
%   certification red.
%   Prints only; returns nothing.
if nargin < 1, optsJson = ''; end
o = struct();
if ~isempty(strtrim(mcp_str(optsJson)))
    try
        o = jsondecode(mcp_str(optsJson));
    catch e
        error('longrun_preflight:badOpts', '[longrun_preflight:badOpts] %s', e.message);
    end
end
minFree = 2048;
maxProc = 2;
repo = '';
if isfield(o, 'minFreeMB'), minFree = mcp_num(o.minFreeMB, 2048); end
if isfield(o, 'maxMatlabProcs'), maxProc = mcp_num(o.maxMatlabProcs, 2); end
if isfield(o, 'repoRoot'), repo = mcp_str(o.repoRoot); end
mcp_tool_log('longrun_preflight', sprintf('minFree=%g maxProc=%g repo=%s', minFree, maxProc, repo));
st = mcp_host_stats(false);
fprintf('this session pid      = %s\n', num2s(st.pid));
fprintf('MATLAB processes      = %s\n', num2s(st.matlabProcs));
fprintf('free physical memory  = %s MB of %s MB\n', num2s(st.freeMB), num2s(st.totalMB));
fprintf('MATLAB own heap       = %s MB used, %s MB available to arrays\n', num2s(st.memUsedMB), num2s(st.memAvailMB));
fprintf('this process CPU time = %s s (compare across polls: rising = alive, flat = wedged)\n', num2s(st.ownCpuSec));
if ~isempty(st.osError)
    fprintf('host-stat notes      :%s\n', strrep(st.osError, '|', ' |'));
end
reasons = {};
if isfinite(st.freeMB) && st.freeMB < minFree
    reasons{end+1} = sprintf('free %d MB < required %d MB', round(st.freeMB), round(minFree));
end
if isfinite(st.matlabProcs) && st.matlabProcs > maxProc
    reasons{end+1} = sprintf('%d MATLAB processes > allowed %d (a timeout retry likely spawned another)', ...
        round(st.matlabProcs), round(maxProc));
end
if ~isempty(repo) && exist(repo, 'dir') == 7
    fprintf('--- repo hygiene (%s) ---\n', repo);
    junk = {'slprj', 'html', 'derived', 'gcache', 'matlab_coder', 'sl_proj.xml'};
    for k = 1:numel(junk)
        p = fullfile(repo, junk{k});
        if exist(p) > 0
            reasons{end+1} = sprintf('stray %s at repo root', junk{k});
            fprintf('  STRAY   %s\n', p);
        end
    end
    as = dir(fullfile(repo, '*.slx_autosave'));
    if ~isempty(as)
        reasons{end+1} = sprintf('%d .slx_autosave at repo root', numel(as));
        fprintf('  STRAY   %d *.slx_autosave\n', numel(as));
    end
    % Simulink writes cache folders into the current directory: recommend a scratch cwd.
    fprintf('  current pwd = %s  (derive a scratch dir under it, not the repo)\n', pwd);
    d = fullfile(repo, 'tests');
    if isfield(o, 'testsDir') && ~isempty(strtrim(mcp_str(o.testsDir)))
        d = mcp_str(o.testsDir);
    end
    if exist(d, 'dir') == 7
        tf = mcp_walk(d, 'test_*.m');
        fprintf('  test files on disk = %d\n', numel(tf));
        % 0 discoverable tests is the empty-scan trap: a certification of nothing prints green
        if isempty(tf)
            reasons{end+1} = sprintf('0 test_*.m under %s - a run here would certify nothing', d);
        end
    else
        reasons{end+1} = sprintf('no tests folder at %s', d);
    end
    % Generated artifacts must be regenerated BEFORE a long run starts, otherwise the
    % locks that read them go red at the end of a run that already cost the whole budget.
    if isfield(o, 'evidenceFile') && ~isempty(strtrim(mcp_str(o.evidenceFile)))
        ev = mcp_repo_path(repo, mcp_str(o.evidenceFile));
        de = dir(ev);
        if isempty(de) || de.isdir
            reasons{end+1} = sprintf('evidenceFile missing: %s', mcp_str(o.evidenceFile));
        else
            srcDirs = {'src', 'tests', 'tools', 'app', 'config'};
            if isfield(o, 'sourceDirs') && ~isempty(o.sourceDirs)
                srcDirs = cellstr(string(o.sourceDirs(:)));
            end
            newer = {};
            for q = 1:numel(srcDirs)
                one = mcp_walk(mcp_repo_path(repo, srcDirs{q}), '*.m');
                for w = 1:numel(one)
                    dw = dir(one{w});
                    if ~isempty(dw) && dw.datenum > de.datenum + 1e-9
                        newer{end+1} = one{w}; %#ok<AGROW>
                    end
                end
            end
            fprintf('  evidence %s age=%.0fs  sources newer = %d\n', ...
                mcp_str(o.evidenceFile), (now - de.datenum) * 86400, numel(newer));
            if ~isempty(newer)
                reasons{end+1} = sprintf('%s is older than %d source file(s) - run the evidence generator first', ...
                    mcp_str(o.evidenceFile), numel(newer));
            end
        end
    end
elseif ~isempty(repo)
    reasons{end+1} = sprintf('repoRoot not found: %s', repo);
end
if isempty(reasons)
    fprintf('VERDICT: GO - safe to start a long run (single chain, memory headroom ok)\n');
else
    fprintf('VERDICT: NO-GO (%d reason(s)):\n', numel(reasons));
    for k = 1:numel(reasons)
        fprintf('  - %s\n', reasons{k});
    end
    fprintf('do NOT retry a timed-out call hoping it will fit; re-clean or wait first.\n');
end
end

function s = num2s(v)
if isempty(v) || (isnumeric(v) && ~isfinite(v))
    s = 'n/a';
elseif isnumeric(v)
    s = sprintf('%.0f', v);
else
    s = char(string(v));
end
end
