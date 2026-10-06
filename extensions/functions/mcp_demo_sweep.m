function out = mcp_demo_sweep(params)
%MCP_DEMO_SWEEP Tiny fake parameter sweep used to verify the async job layer.
%   params.reps     number of iterations (default 6)
%   params.delaySec pause per iteration (default 0.5)
%   params.gain     linear gain (default 2.0)
if isempty(params), params = struct(); end
if ~isfield(params, 'reps'), params.reps = 6; end
if ~isfield(params, 'delaySec'), params.delaySec = 0.5; end
if ~isfield(params, 'gain'), params.gain = 2.0; end
vals = zeros(params.reps, 1);
for k = 1:params.reps
    pause(params.delaySec);
    vals(k) = params.gain * k + 0.1 * randn;
    fprintf('rep %d/%d: %.3f\n', k, params.reps, vals(k));
end
out = struct('vals', vals, 'meanVal', mean(vals), 'maxVal', max(vals), 'reps', params.reps);
end
