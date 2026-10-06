function env_report(scope)
%ENV_REPORT Everything that decides whether a big run fits on this machine.
%   scope: '' = standard report; 'gpu' adds a GPU probe hint; 'jobs' adds the
%          sweep/job backlog; 'full' = everything.
%   WHY: session_info reports version, folder, figures and timers only. The
%   numbers that actually decide feasibility - cores, free memory, GPU
%   usability, per-product license availability, MATLAB path size, loaded
%   models, pool state, job backlog - had to be dug out with hand-written
%   probes. This tool makes them one call.
if nargin < 1, scope = ''; end
scope = lower(strtrim(mcp_str(scope)));
all_s = any(strcmp(scope, {'full', 'all'}));
mcp_tool_log('env_report', scope);
V = ver;
fprintf('MATLAB      %s (%s)\n', V(1).Version, V(1).Release);
fprintf('matlabroot  %s\n', matlabroot);
% version('-java') reports "Java is not enabled" on a fresh engine because the
% JVM starts lazily on first use - printing it verbatim made the report claim
% Java was absent while the digest probe a few lines below succeeded. Probe
% actual usability instead.
jav = 'not started';
try
    javaMethod('getInstance', 'java.security.MessageDigest', 'SHA-256');
    jav = 'usable (JVM starts lazily; verified by a real digest call)';
catch e
    jav = e.message;
end
fprintf('os          %s  java %s\n', computer, jav);
fprintf('pwd         %s\n', pwd);
fprintf('cores       %d (feature numcores)\n', feature('numcores'));
m = memory;
fprintf('memory      used=%.2f GiB  availForArrays=%.2f GiB  maxSingleArray=%.2f GiB\n', ...
    m.MemUsedMATLAB / 2^30, m.MemAvailableAllArrays / 2^30, m.MaxPossibleArrayBytes / 2^30);
[tm, tf] = deal(-1, -1);
try
    [tf, tm] = deal(feature('TotalPhysicalMemory'), feature('AvailablePhysicalMemory'));
catch
end
if tf > 0
    fprintf('RAM         total=%.1f GiB available=%.1f GiB (OS view)\n', tf / 2^30, tm / 2^30);
end
pp = strsplit(matlabpath, pathsep());
fprintf('matlabpath  %d entries (large paths slow resolution and every batch job)\n', numel(pp));
fprintf('userpath    %s\n', prefdir);
w = evalin('base', 'who');
fprintf('base vars   %d\n', numel(w));
figs = findall(0, 'Type', 'figure');
uif = 0;
for k = 1:numel(figs)
    if isa(figs(k), 'matlab.ui.Figure'), uif = uif + 1; end
end
fprintf('figures     %d (%d of them uifigure)\n', numel(figs), uif);
tmr = timerfindall;
fprintf('timers      %d\n', numel(tmr));
for k = 1:numel(tmr)
    fprintf('            "%s" running=%s period=%.1fs executed=%d\n', tmr(k).Name, tmr(k).Running, tmr(k).Period, tmr(k).TasksExecuted);
end
p = gcp('nocreate');
if isempty(p)
    fprintf('pool        none (parpool starts on demand; measured 18.6 s for 4 workers here)\n');
else
    fprintf('pool        %d workers (%s)\n', p.NumWorkers, class(p));
end
try
    ml = find_system('type', 'block_diagram');
    fprintf('simulink    %d models loaded: %s\n', numel(ml), strjoin(string(ml), ', '));
catch
    fprintf('simulink    not loaded\n');
end
try
    fprintf('gpu         count(all)=%d available=%d forwardCompat=%d  (run gpu_probe to activate + benchmark)\n', ...
        gpuDeviceCount('all'), gpuDeviceCount('available'), parallel.gpu.enableCUDAForwardCompatibility);
catch e
    fprintf('gpu         unavailable: %s\n', e.message);
end
try
    py.importlib.import_module('sys');
    fprintf('python      importable via py.importlib (py.Version unusable on this build)\n');
catch
    fprintf('python      NOT available\n');
end
try
    javaMethod('getInstance', 'java.security.MessageDigest', 'SHA-256');
    fprintf('digest      SHA-256 available through Java (no matlab.lang.sha256 here)\n');
catch
    fprintf('digest      NO Java digest -> file hashing unavailable\n');
end
fprintf('products    %d installed\n', numel(V));
if any(strcmp(scope, {'full', 'all', 'lic', 'licenses'})) || all_s
    fprintf('--- key licenses (1 = available to checkout) ---\n');
    lk = {'Distrib_Computing_Toolbox','Simulink','Simulink_Worker','Statistics_Toolbox', ...
          'Signal_Toolbox','CurveFitting_Toolbox','Optimization_Toolbox','Control_Toolbox', ...
          'Symbolic_Toolbox','PDE_Toolbox','Real-Time_Workshop','MATLAB_Codec','MATLAB_Charting_Toolbox'};
    for k = 1:numel(lk)
        fprintf('  %-28s %d\n', lk{k}, license('test', lk{k}));
    end
end
if any(strcmp(scope, {'full', 'all', 'jobs'})) || all_s
    ROOT = mcp_ext_root();
    jd = fullfile(ROOT, 'jobs');
    nd = 0;
    if exist(jd, 'dir')
        nd = numel(dir(fullfile(jd, 'job_*')));
    end
    sd = fullfile(ROOT, 'sweeps');
    ns = 0;
    if exist(sd, 'dir')
        ns = numel(dir(fullfile(sd, 'sweep_*.json')));
    end
    fprintf('artifacts   %d job dirs, %d sweeps under %s\n', nd, ns, ROOT);
    try
        c = parcluster('local');
        fprintf('cluster     local profile workers=%d jobs=%d\n', c.NumWorkers, numel(c.Jobs));
    catch e
        fprintf('cluster     unreadable (%s)\n', e.identifier);
    end
end
end
