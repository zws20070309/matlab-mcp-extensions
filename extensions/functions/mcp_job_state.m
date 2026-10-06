function [status, errId, errMsg] = mcp_job_state(j)
%MCP_JOB_STATE Classify a batch job handle into live/finished/failed/cancelled.
%   Verified on R2025a local-cluster jobs (parallel.job.CJSIndependentJob):
%   j.State reports 'finished' for success, failure AND cancellation alike;
%   the only discriminator is the task's Error (MException):
%     identifier 'parallel:job:UserCancellation' -> cancelled
%     any other non-empty Error                  -> failed
%     empty Error + empty ErrorMessage           -> success ('finished')
status = 'unknown';
errId = '';
errMsg = '';
try
    status = char(j.State);
catch
end
try
    tk = j.Tasks(1);
    errObj = tk.Error;
    % A successful task can hand back a 0x0 MException array or an object with
    % an empty identifier, so test the identifier, not the container.
    idf = '';
    if isobject(errObj) && ~isempty(errObj)
        idf = strtrim(char(errObj(1).identifier));
    end
    if ~isempty(idf)
        errId = idf;
        errMsg = char(errObj(1).message);
        if strcmp(errId, 'parallel:job:UserCancellation')
            status = 'cancelled';
        else
            status = 'failed';
        end
    else
        % strtrim matters: a whitespace-only ErrorMessage previously made
        % perfectly successful jobs classify as 'failed' (verified - two
        % qa_job_fn runs with done.json status "finished" were listed as
        % failed by list_jobs).
        mt = strtrim(char(tk.ErrorMessage));
        if ~isempty(mt)
            errMsg = mt;
            if contains(errMsg, 'cancelled by user')
                status = 'cancelled';
            else
                status = 'failed';
            end
        end
    end
catch
end
end
