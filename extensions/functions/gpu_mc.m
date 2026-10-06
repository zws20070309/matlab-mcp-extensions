function gpu_mc(funPath, specJson)
%GPU_MC Run a vectorized Monte-Carlo kernel on the GPU, with correct statistics.
%   funPath : absolute path to "acc = kernel(u, extra)".
%             u = chunk x dim gpuArray of U(0,1] draws; extra = spec.params.
%             Return chunk x m (a column per scored quantity). Reduce on the GPU.
%   specJson: JSON object, any field optional:
%             {"totalN":1e8, "chunk":1e6, "seed":12345, "precision":"single",
%              "dim":2, "params":{...}, "cpuCompare":true, "inJob":false,
%              "reference":"33.8667", "refTolerance":"4/sqrt(N)"}
%               totalN     samples overall (default 1e7)
%               chunk      samples per GPU dispatch (default 1e6)
%               seed       set to make the run replayable; omit = NOT replayable
%               precision  single (default) | double
%               dim        columns of uniforms per sample (default 1)
%               params     passed through to the kernel as `extra`
%               cpuCompare true also runs the identical loop on CPU arrays and
%                          reports the measured speedup
%               inJob      true submits it through submit_job with gpu='1', so a
%                          long GPU run does not block this session
%   WHY: on this machine the GPU only becomes usable after CUDA forward
%   compatibility is enabled per process, on-GPU draws must use
%   rand(N,1,'like',gpuArray(...)), and re-seeding must replace the global GPU
%   stream - all three were established by measurement, and this tool hides
%   them. Prints only; returns nothing so no stray `ans` is echoed.
if nargin < 1, funPath = ''; end
if nargin < 2, specJson = ''; end
funPath = mcp_str(funPath);
specJson = mcp_str(specJson);
if isempty(funPath)
    error('gpu_mc:badArgs', '[gpu_mc:badArgs] funPath is required (absolute path to the kernel .m file)');
end
if isempty(specJson)
    spec = struct();
else
    try
        spec = jsondecode(specJson);
    catch e
        error('gpu_mc:badSpec', '[gpu_mc:badSpec] specJson must decode to a JSON object: %s', e.message);
    end
    if ~isstruct(spec) || isempty(spec)
        error('gpu_mc:badSpec', '[gpu_mc:badSpec] specJson must be a JSON object');
    end
end
spec.funPath = funPath;
mcp_tool_log('gpu_mc', sprintf('%s spec=%.160s', funPath, specJson));
inJob = flagof(spec, 'inJob');
if inJob
    pj = jsonencode(rmfield(spec, 'inJob'));
    [jobId, state, jobDir] = mcp_submit_job_core( ...
        fullfile(mcp_ext_root(), 'functions', 'mcp_gpu_mc_job.m'), pj, 'gpu_mc', '', '1', '');
    fprintf('submitted GPU job (forward compatibility will be enabled inside the worker)\n');
    fprintf('jobId=%s\nstate=%s\njobDir=%s\n', jobId, state, jobDir);
    fprintf('poll with job_status("%s")\n', jobId);
    return
end
r = mcp_gpu_mc_core(spec);
fprintf('device:      %s\n', r.device);
fprintf('kernel:      %s  precision=%s  dim=%d  N=%g  chunk=%g\n', ...
    r.kernel, r.precision, r.dim, r.totalN, r.chunk);
if isfinite(r.seed)
    fprintf('seed:        %g via %s (replayable)\n', r.seed, r.gpuStream);
else
    fprintf('seed:        NOT SET (this run cannot be replayed)\n');
end
fprintf('gpu time:    %.3f s   (%.3g samples/s)\n', r.secGpu, r.throughput);
if isfinite(r.secCpu)
    fprintf('cpu time:    %.3f s\n', r.secCpu);
    fprintf('MEASURED SPEEDUP cpu/gpu = %.2fx\n', r.speedup);
end
fprintf('columns returned: %d\n', numel(r.mean));
for k = 1:numel(r.mean)
    fprintf('  col%d mean=%.10g stderr=%.3g  (%.2f%% rel unc)\n', k, r.mean(k), r.stderr(k), ...
        100 * r.stderr(k) / max(abs(r.mean(k)), realmin));
end
if isfield(spec, 'reference')
    ref = mcp_num(spec.reference, NaN);
    if isfinite(ref) && numel(r.mean) >= 1
        sig = abs(r.mean(1) - ref) / max(r.stderr(1), realmin);
        fprintf('against reference %g: deviation = %.2f sigma -> %s\n', ...
            ref, sig, tern(sig < 4, 'CONSISTENT', 'INCONSISTENT (kernel or sampler is wrong)'));
    end
end
if ~isempty(r.note)
    fprintf('note:%s\n', strrep(r.note, '|', ' |'));
end
end

function tf = flagof(s, f)
tf = false;
if isfield(s, f)
    v = s.(f);
    if islogical(v) || isnumeric(v)
        tf = any(double(v(:)) ~= 0);
    else
        tf = any(strcmp(lower(strtrim(char(string(v)))), {'1', 'true', 'yes', 'on'}));
    end
end
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
