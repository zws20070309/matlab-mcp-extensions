function r = mcp_gpu_mc_core(p)
%MCP_GPU_MC_CORE Chunked GPU Monte-Carlo driver with correct statistics.
%   Called by the gpu_mc tool (live session) and by mcp_gpu_mc_job (batch
%   worker). Kept as one core so both paths behave identically.
%
%   Kernel contract:  acc = kernel(u, extra)
%     u     nc x dim gpuArray of U(0,1] draws in the requested precision
%     extra the spec.params value as-is (struct/array/[]), for geometry, W
%           value, cross sections, whatever the run needs
%     acc   nc x m gpuArray (or nc x 1). Returning a scalar is allowed and is
%           treated as m=1. Reduce on the GPU; the driver only gathers the two
%           per-chunk scalars per column, so PCIe never carries the samples.
%
%   Verified on this machine (see gpu_probe): on-GPU generation must use
%   rand(N,1,'like',gpuArray(single(1))); rand(g,N,1) is NOT supported on
%   R2025a. Re-seeding is done by replacing the global GPU stream.
%   Measured throughput on an RTX 5060 for a sqrt-heavy chord kernel:
%   5e7 samples in 0.04 s GPU vs 0.74 s CPU (19x).
dflt = struct('totalN', 1e7, 'chunk', 1e6, 'seed', [], 'precision', 'single', ...
    'dim', 1, 'params', [], 'cpuCompare', false);
f = fieldnames(dflt);
for k = 1:numel(f)
    if ~isfield(p, f{k})
        p.(f{k}) = dflt.(f{k});
    end
end
cls = lower(mcp_str(p.precision));
if ~any(strcmp(cls, {'single', 'double'}))
    error('gpu_mc:badPrecision', '[gpu_mc:badPrecision] precision must be single|double, got: %s', cls);
end
Ntot = round(mcp_num(p.totalN, 1e7));
NCH = round(mcp_num(p.chunk, 1e6));
if ~(isfinite(Ntot) && Ntot > 0)
    error('gpu_mc:badN', '[gpu_mc:badN] totalN must be a positive integer');
end
if ~(isfinite(NCH) && NCH > 0)
    NCH = 1e6;
end
NCH = min(NCH, Ntot);
dim = max(1, round(mcp_num(p.dim, 1)));
st = mcp_gpu_enable('1');
if ~st.ok
    error('gpu_mc:noGpu', '[gpu_mc:noGpu] GPU unusable after enabling forward compatibility (%s)', st.note);
end
scriptPath = mcp_str(p.funPath);
if ~exist(scriptPath, 'file')
    error('gpu_mc:noFun', '[gpu_mc:noFun] kernel file not found: %s', scriptPath);
end
[~, fn, ext] = fileparts(scriptPath);
if ~strcmpi(ext, '.m')
    error('gpu_mc:noFun', '[gpu_mc:noFun] kernel must be a .m file, got: %s', scriptPath);
end
addpath(fileparts(scriptPath));
fh = str2func(fn);
extra = p.params;
if isstruct(extra) && isfield(extra, 'mcpJson')
    extra = jsondecode(char(string(extra.mcpJson)));
end
seed = mcp_num(p.seed, []);
gpuStream = '';
if isfinite(seed)
    % Replacing the global GPU stream is the only re-seeding form accepted here
    % (assigning rs.Seed throws MATLAB:RandStream:subsasgn:IllegalSeedAssignment).
    names = {'combRecursive', 'mrg32k3a', 'Philox4x32-196', 'Threefry4x64-256', 'MersenneTwister'};
    for k = 1:numel(names)
        try
            rs = parallel.gpu.RandStream(names{k}, 'Seed', seed);
            parallel.gpu.RandStream.setGlobalStream(rs);
            gpuStream = names{k};
            break
        catch
        end
    end
    if isempty(gpuStream)
        error('gpu_mc:noSeed', ...
            '[gpu_mc:noSeed] no GPU random stream accepted Seed=%g; run gpu_probe to see the supported types', seed);
    end
end
tmpl = gpuArray(single(1));
if strcmp(cls, 'double')
    tmpl = gpuArray(1);
end
r = struct('device', st.device, 'precision', cls, 'totalN', Ntot, 'chunk', NCH, ...
    'dim', dim, 'seed', seed, 'gpuStream', gpuStream, 'kernel', fn, ...
    'secGpu', NaN, 'secCpu', NaN, 'speedup', NaN, 'throughput', NaN, ...
    'mean', [], 'stderr', [], 'n', Ntot, 'note', '');
t0 = tic;
s1 = [];
s2 = [];
done = 0;
m = 0;
while done < Ntot
    nc = min(NCH, Ntot - done);
    u = rand(nc, dim, 'like', tmpl);
    acc = fh(u, extra);
    if ~isa(acc, 'gpuArray')
        acc = gpuArray(acc);
    end
    if isvector(acc) && numel(acc) ~= nc
        acc = acc(:);
    end
    if size(acc, 2) ~= m && m == 0
        m = size(acc, 2);
        s1 = zeros(1, m, 'double');
        s2 = zeros(1, m, 'double');
    end
    if size(acc, 2) ~= m
        error('gpu_mc:shape', ...
            '[gpu_mc:shape] kernel returned %dx%d, earlier chunk was %dx%d - the column count must be stable', ...
            size(acc, 1), size(acc, 2), nc, m);
    end
    ps1 = gather(sum(acc, 1));
    ps2 = gather(sum(acc .* acc, 1));
    s1 = s1 + double(ps1(:).');
    s2 = s2 + double(ps2(:).');
    clear u acc
    done = done + nc;
end
r.secGpu = toc(t0);
r.mean = s1 / Ntot;
var = max((s2 - Ntot * r.mean.^2) / max(Ntot - 1, 1), 0);
r.stderr = sqrt(var / Ntot);
r.throughput = Ntot / max(r.secGpu, 1e-9);
if isfinite(seed)
    r.note = [r.note '| seeded GPU stream ' gpuStream ' -> replayable'];
else
    r.note = [r.note '| NO seed given: the run used the existing GPU stream and is NOT replayable'];
end
if isfield(p, 'cpuCompare') && (isequaltrue(p.cpuCompare))
    t1 = tic;
    c1 = zeros(1, 0);
    c2 = c1;
    done = 0;
    mc = 0;
    while done < Ntot
        nc = min(NCH, Ntot - done);
        if strcmp(cls, 'single')
            uc = single(rand(nc, dim, 'single'));
        else
            uc = rand(nc, dim);
        end
        ac = fh(uc, extra);
        ac = double(ac);
        if isvector(ac) && numel(ac) ~= nc
            ac = ac(:);
        end
        if mc == 0
            mc = size(ac, 2);
            c1 = zeros(1, mc);
            c2 = zeros(1, mc);
        end
        c1 = c1 + sum(ac, 1);
        c2 = c2 + sum(ac .* ac, 1);
        clear uc ac
        done = done + nc;
    end
    r.secCpu = toc(t1);
    r.speedup = r.secCpu / max(r.secGpu, 1e-9);
    cm = c1 / Ntot;
    r.note = [r.note sprintf(' | cpu mean diff (relative) = %.3e', max(abs(cm - r.mean) ./ max(abs(r.mean), 1e-30)))];
end
end

function tf = isequaltrue(v)
tf = false;
if islogical(v)
    tf = any(v(:));
elseif isnumeric(v)
    tf = any(v(:) ~= 0);
elseif ischar(v) || isstring(v)
    tf = any(strcmp(lower(strtrim(char(string(v)))), {'1', 'true', 'yes', 'on'}));
end
end
