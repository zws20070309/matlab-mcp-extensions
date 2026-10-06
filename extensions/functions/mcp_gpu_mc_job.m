function out = mcp_gpu_mc_job(params)
%MCP_GPU_MC_JOB Batch-worker front end for gpu_mc (inJob=true path).
%   Runs the same core as the live-session tool, so a GPU Monte Carlo can be
%   left running without blocking the MATLAB session that the other MCP tools
%   share. The runner enables CUDA forward compatibility before this call
%   because that flag is per process.
%   Convention: out = f(params) - params arrives as the decoded specJson plus
%   the injected funPath field.
if isempty(params)
    error('gpu_mc_job:noSpec', '[gpu_mc_job:noSpec] params must be the gpu_mc spec object');
end
r = mcp_gpu_mc_core(params);
fprintf('gpu time %.3f s, %g samples/s, device=%s\n', r.secGpu, r.throughput, r.device);
for k = 1:numel(r.mean)
    fprintf('col%d mean=%.10g stderr=%.3g\n', k, r.mean(k), r.stderr(k));
end
if isfinite(r.seed)
    fprintf('seed %g via %s\n', r.seed, r.gpuStream);
end
out = r;
end
