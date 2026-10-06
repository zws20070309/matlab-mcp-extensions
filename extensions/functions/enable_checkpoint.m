function enable_checkpoint(periodSeconds)
%ENABLE_CHECKPOINT Install a periodic base-workspace snapshot timer.
%   periodSeconds > 0: snapshot cadence in seconds (clamped to >= 10 s and
%                      quantized to the 1 ms timer resolution).
%   periodSeconds = 0: stop and remove the checkpoint timer. The checkpoint
%   file itself is kept so restore_checkpoint can still be used.
%   Snapshots are written atomically to <extensions>\checkpoint.mat by
%   mcp_checkpoint_apply; restore_checkpoint loads them after a
%   kill-and-restart recovery of a hung session. The timer dies with the
%   MATLAB process, so re-run enable_checkpoint after any restart.

if nargin < 1, periodSeconds = 60; end
% The MCP schema delivers periodSeconds as a STRING. The previous guard rejected
% anything non-numeric by silently falling back to 60 s, so "0" - the documented
% way to STOP the timer - quietly re-armed a 60 s checkpoint instead
% (found by the v8 acceptance sweep: enable_checkpoint('0') printed
% "checkpoint enabled: every 60 s"). Normalise through mcp_num instead.
v = mcp_num(periodSeconds, 60);
if ~isfinite(v)
    v = 60;
end
period = max(0, v);
mcp_tool_log('enable_checkpoint', sprintf('periodSeconds=%g', period));
old = timerfindall('Name', 'MCPCheckpointTimer');
for k = 1:numel(old)
    try
        stop(old(k));
        delete(old(k));
    catch
    end
end
if period == 0
    fprintf('checkpoint timer removed (existing checkpoint file kept)\n');
    return
end
period = max(10, round(period*1000)/1000); % >= 10 s, ms-quantized
chkPath = fullfile(mcp_ext_root(), 'checkpoint.mat');
t = timer('Name', 'MCPCheckpointTimer', 'ExecutionMode', 'fixedRate', ...
    'Period', period, 'BusyMode', 'drop', ...
    'TimerFcn', @(~,~) mcp_checkpoint_apply(chkPath), ...
    'ErrorFcn', @(~,~)[]);
start(t);
fprintf('checkpoint enabled: every %g s -> %s\n', period, chkPath);
end
