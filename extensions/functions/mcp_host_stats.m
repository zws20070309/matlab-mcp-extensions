function st = mcp_host_stats(skipSlow)
%MCP_HOST_STATS One-shot host facts a long MATLAB run must be gated on.
%   Returns a struct: pid, matlabProcs, freeMB, totalMB, ownCpuSec, ok flags.
%   Measured reason this exists: a second MATLAB started by a timed-out retry
%   cost 1.47 GB on a box with 1.1-2.9 GB free and wedged the machine, and the
%   only signals that separated "slow but alive" from "hung" were the OS-level
%   process count, free memory, and this process's CPU time. The source session
%   recorded ENV 1926 MB / PID 41004 style lines by hand; this collects them.
%   Powershell/tasklist calls cost ~1-2 s, so skipSlow=true returns just the
%   cheap in-MATLAB facts (pid + memory struct) for tight polling loops.
if nargin < 1, skipSlow = false; end
st = struct('pid', NaN, 'matlabProcs', NaN, 'freeMB', NaN, 'totalMB', NaN, ...
    'ownCpuSec', NaN, 'memUsedMB', NaN, 'memAvailMB', NaN, 'osError', '');
try
    pid = feature('getpid');
    if isnumeric(pid)
        st.pid = pid;
    end
catch e
    st.osError = [st.osError '| getpid: ' e.identifier];
end
try
    m = memory;
    st.memUsedMB = round(m.MemUsedMATLAB / 2^20);
    st.memAvailMB = round(m.MemAvailableAllArrays / 2^20);
catch
end
if skipSlow
    return
end
try
    if ispc
        [~, txt] = dos('tasklist /FI "IMAGENAME eq MATLAB.exe" /NH');
        L = regexp(txt, '\r?\n', 'split');
        st.matlabProcs = nnz(~cellfun('isempty', regexp(L, 'MATLAB\.exe', 'once')));
        cmd = sprintf(['powershell -NoProfile -Command "$o=Get-CimInstance ' ...
            'Win32_OperatingSystem; ''{0}|{1}|{2}'' -f $o.FreePhysicalMemory,' ...
            ' $o.TotalVisibleMemorySize,(Get-Process -Id %d).CPU"'], st.pid);
        [ok, txt] = dos(cmd);
        tok = regexp(strtrim(txt), '^(\d+)\|(\d+)\|([0-9.,]+)$', 'tokens');
        if ~isempty(tok)
            st.freeMB = round(str2double(strrep(tok{1}{1}, ',', '.')) / 1024);
            st.totalMB = round(str2double(strrep(tok{1}{2}, ',', '.')) / 1024);
            st.ownCpuSec = str2double(strrep(tok{1}{3}, ',', '.'));
        elseif ok == 0
            st.osError = [st.osError '| powershell output unparsed: ' strtrim(txt)];
        else
            st.osError = [st.osError '| powershell exit ' num2str(ok)];
        end
    else
        [~, txt] = system('pgrep -c -f "MATLAB" 2>/dev/null || true');
        st.matlabProcs = str2double(strtrim(txt));
        [~, txt] = system('free -m | awk ''/Mem:/{print $7"|"$2}''');
        tok = strsplit(strtrim(txt), '|');
        if numel(tok) == 2
            st.freeMB = str2double(tok{1});
            st.totalMB = str2double(tok{2});
        end
        [~, txt] = system(sprintf('ps -o cputime= -p %d', st.pid));
        cv = strtrim(txt);
        if ~isempty(cv)
            p = sscanf(cv, '%d:%d');
            if numel(p) == 2
                st.ownCpuSec = p(1) * 60 + p(2);
            end
        end
    end
catch e
    st.osError = [st.osError '| ' e.identifier ': ' strtrim(replace(e.message, newline, ' '))];
end
end
