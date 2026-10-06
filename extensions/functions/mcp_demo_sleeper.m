function out = mcp_demo_sleeper(params)
%MCP_DEMO_SLEEPER Sleeps N seconds, one at a time. Used to test cancel_job.
if isempty(params), params = struct(); end
if ~isfield(params, 'seconds'), params.seconds = 60; end
for k = 1:params.seconds
    pause(1);
    fprintf('slept %d/%d\n', k, params.seconds);
end
out = params;
end
