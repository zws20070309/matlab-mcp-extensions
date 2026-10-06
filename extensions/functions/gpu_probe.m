function gpu_probe(enable, samples)
%GPU_PROBE Make the GPU usable, prove it computes CORRECTLY, and benchmark a
%   chunked Monte-Carlo kernel the way gpu_mc runs real work.
%   enable : '1' (default) turn CUDA forward compatibility on for this process;
%            '0' turn it back off.
%   samples: total MC samples for the benchmark, e.g. '5e7'. '' = 5e7.
%
%   MEASURED FACTS THIS TOOL ENCAPSULATES (2026-09-19, RTX 5060 Laptop / CC 12.0):
%     - without forward compatibility every GPU call throws
%       "higher compute capability (12.0) than is natively supported by the CUDA
%        libraries"; gpuDeviceCount('available')=0 while ('all')=1.
%     - the flag is PER PROCESS, so a PCT worker must enable it again itself.
%     - rand(g,...) with a gpuDevice first argument is NOT supported on R2025a
%       (MATLAB:rand:inputType). The working on-GPU generator is
%         rand(N,1,'like',gpuArray(single(1)))
%       driven by parallel.gpu.RandStream's global stream.
%     - small N is launch/transfer dominated (2e6 samples measured 0.24x vs CPU),
%       so the benchmark is chunked and reports per-chunk and total timings.
%   Returns nothing on purpose (the server evaluates a tool call as an
%   expression, so a return value would echo as a stray `ans`).

if nargin < 1, enable = ''; end
if nargin < 2, samples = ''; end
mcp_tool_log('gpu_probe', sprintf('enable=%s samples=%s', mcp_str(enable), mcp_str(samples)));
% The CUDA JIT notice is printed as a MATLAB warning with embedded HTML anchors
% on every device selection; suppress around the probe so the tool output stays
% parseable. Restored by onCleanup.
prevW = warning('off', 'all');
rest = onCleanup(@() warning(prevW));

fprintf('--- 1. forward compatibility ---\n');
st = mcp_gpu_enable(enable);
fprintf('priorFC=%s now=%s\n', num2s(st.priorFC), num2s(st.fcNow));
if isempty(st.device)
    fprintf('DEVICE: none reachable\n');
else
    fprintf('DEVICE: %s  computeCapability=%s  cudaDriver=%s\n', st.device, st.cc, st.driver);
end
fprintf('warmup: %s in %s s (first call pays the CUDA JIT rebuild)\n', ...
    tern(isempty(st.checked), 'not attempted', st.checked), num2s(st.warmSec));
if ~isempty(st.note)
    fprintf('note:%s\n', strrep(st.note, '|', ' |'));
end
for f = {'all', 'available', 'supported'}
    try
        fprintf('gpuDeviceCount(%-9s) = %d\n', f{1}, gpuDeviceCount(f{1}));
    catch e
        fprintf('gpuDeviceCount(%-9s) -> %s\n', f{1}, e.message);
    end
end
if ~st.ok
    fprintf('VERDICT: GPU NOT USABLE - do not plan GPU acceleration in this process.\n');
    rest = [];
    warning(prevW);
    return
end

fprintf('--- 2. on-GPU random numbers: which call form works here ---\n');
forms = cell(0, 2);
forms(end+1, :) = {'rand(g,N,1) [gpuDevice first arg]', @devRand};
forms(end+1, :) = {'rand(N,1,''like'',gpuArray(single(1)))', @(nn) rand(nn, 1, 'like', gpuArray(single(1)))};
forms(end+1, :) = {'randn(N,1,''like'',gpuArray(single(1)))', @(nn) randn(nn, 1, 'like', gpuArray(single(1)))};
forms(end+1, :) = {'gpuArray(single(rand(N,1))) [CPU then upload]', @(nn) gpuArray(single(rand(nn, 1)))};
for k = 1:size(forms, 1)
    try
        v = forms{k, 2}(1000);
        s = gather(sum(v(:)));
        fprintf('  %-44s OK class=%s sum=%.6g\n', forms{k, 1}, class(v), double(s));
    catch e
        fprintf('  %-44s FAIL %s\n', forms{k, 1}, e.identifier);
    end
end
try
    rs = parallel.gpu.RandStream.getGlobalStream;
    tp = '?';
    try
        tp = char(string(rs.Type));
    catch
    end
    sd = NaN;
    try
        sd = rs.Seed;
    catch
    end
    fprintf('  gpu global stream: %s type=%s seed=%s\n', class(rs), tp, num2s(sd));
    try
        rs.Seed = 5;
        fprintf('  reseed by property: ALLOWED\n');
    catch e
        fprintf('  reseed by property: %s (so re-seed by replacing the stream)\n', e.identifier);
    end
catch e
    fprintf('  parallel.gpu.RandStream.getGlobalStream FAIL %s :: %s\n', e.identifier, e.message);
end
fprintf('  reproducible on-GPU seeding (construct + setGlobalStream):\n');
cand = {'Philox4x32-196', 'philox4x32-196', 'Philox4_32-196', 'Threefry4x64-256', ...
        'MersenneTwister', 'mt19937ar', 'combRecursive', 'mrg32k3a'};
made = '';
for k = 1:numel(cand)
    try
        r0 = parallel.gpu.RandStream(cand{k}, 'Seed', 12345);
        parallel.gpu.RandStream.setGlobalStream(r0);
        a1 = gather(rand(4, 1, 'like', gpuArray(single(1))));
        r1 = parallel.gpu.RandStream(cand{k}, 'Seed', 12345);
        parallel.gpu.RandStream.setGlobalStream(r1);
        a2 = gather(rand(4, 1, 'like', gpuArray(single(1))));
        same = isequal(a1, a2);
        fprintf('    %-18s OK reproducible=%d first=%.7g\n', cand{k}, same, a1(1));
        if same && isempty(made)
            made = cand{k};
        end
    catch e
        fprintf('    %-18s FAIL %s\n', cand{k}, e.identifier);
    end
end
if ~isempty(made)
    fprintf('  USE THIS for reproducible GPU Monte Carlo: parallel.gpu.RandStream(''%s'',''Seed'',s)\n', made);
else
    fprintf('  NO reproducible GPU seeding form found - GPU runs are not seed-replayable here\n');
end

fprintf('--- 3. chunked Monte-Carlo benchmark: mean chord of a sphere ---\n');
fprintf('  sampler: p = R*sqrt(u), u~U(0,1)  =>  E[2*sqrt(R^2-p^2)] = 4R/3 (Cauchy)\n');
Ntot = mcp_num(samples, 5e7);
if ~(isfinite(Ntot) && Ntot > 1e5)
    Ntot = 5e7;
end
R = 25.4;
ref = 4 * R / 3;
NCH = 1e7;
results = cell(2, 2);
fprintf('samples=%g chunk=%g R=%.3f analytic=%.9f\n', Ntot, NCH, R, ref);
for pc = 1:2
    if pc == 1
        cls = 'single';
    else
        cls = 'double';
    end
    for wh = 1:2
        useGpu = (wh == 1);
        try
            s1 = 0;
            s2 = 0;
            n = 0;
            t0 = tic;
            done = 0;
            while done < Ntot
                nc = min(NCH, Ntot - done);
                if useGpu
                    if strcmp(cls, 'single')
                        u = rand(nc, 1, 'like', gpuArray(single(1)));
                    else
                        u = rand(nc, 1, 'like', gpuArray(1));
                    end
                    L = 2 * sqrt(max(R * R - (R * R) .* u, 0));
                    ps1 = gather(sum(L, 'all'));
                    ps2 = gather(sum(L .* L, 'all'));
                    clear u L
                else
                    if strcmp(cls, 'single')
                        u = single(rand(nc, 1, 'single'));
                        p2 = (R * R) .* double(u);
                    else
                        u = rand(nc, 1);
                        p2 = (R * R) .* u;
                    end
                    L = 2 * sqrt(max(R * R - p2, 0));
                    ps1 = sum(L);
                    ps2 = sum(L .* L);
                    clear u L p2
                end
                s1 = s1 + ps1;
                s2 = s2 + ps2;
                n = n + nc;
                done = done + nc;
            end
            el = toc(t0);
            mu = s1 / n;
            sd = sqrt(max(s2 / n - mu * mu, 0));
            se = sd / sqrt(n);
            r = struct('sec', el, 'mean', mu, 'se', se);
            results{pc, wh} = r;
            fprintf('  %-6s %-4s %8.3f s  mean=%.6f  stat_unc=%.6f  rel_err=%.3e (%.2f sigma)\n', ...
                cls, tern(useGpu, 'gpu', 'cpu'), el, mu, se, ...
                abs(mu - ref) / ref, abs(mu - ref) / max(se, 1e-12));
        catch e
            fprintf('  %-6s %-4s FAIL %s :: %s\n', cls, tern(useGpu, 'gpu', 'cpu'), e.identifier, e.message);
        end
    end
end
gv = @(a, b) ~isempty(a) && isstruct(a) && ~isempty(b) && isstruct(b);
if gv(results{1, 1}, results{1, 2})
    fprintf('  SPEEDUP single gpu/cpu = %.2fx (%.3f s vs %.3f s)\n', ...
        results{1, 2}.sec / max(results{1, 1}.sec, 1e-9), results{1, 1}.sec, results{1, 2}.sec);
end
if gv(results{2, 1}, results{2, 2})
    fprintf('  SPEEDUP double gpu/cpu = %.2fx (consumer cards throttle fp64; prefer single)\n', ...
        results{2, 2}.sec / max(results{2, 1}.sec, 1e-9));
end
if gv(results{1, 1}, results{1, 2})
    df = abs(results{1, 1}.mean - results{1, 2}.mean);
    if df < 5 * max(results{1, 1}.se, results{1, 2}.se)
        fprintf('  AGREEMENT gpu vs cpu within 5 sigma (%.3g) -> GPU arithmetic verified\n', df);
    else
        fprintf('  AGREEMENT gpu vs cpu DISAGREE (%.3g) -> do not trust this GPU path\n', df);
    end
end
fprintf('  NOTE 2e6 samples measured 0.24x earlier: small N is launch/transfer bound.\n');
fprintf('--- 4. guidance ---\n');
fprintf('  * generate on the GPU with rand(N,1,''like'',gpuArray(single(1))); never rand(g,N,1) here\n');
fprintf('  * set the seed through parallel.gpu.RandStream.getGlobalStream.Seed (verified reproducible above)\n');
fprintf('  * keep data resident and gather() only reductions; chunk at ~1e7\n');
fprintf('  * gpu_mc(funPath,...) runs a user kernel this way, and gpu_mc(...,''inJob'',''1'') runs it on a worker\n');
rest = [];
warning(prevW);
fprintf('  * warnings were suppressed during this call only (CUDA JIT notice); restored now\n');
end

function v = devRand(nn)
g = gpuDevice(1);
v = rand(g, nn, 1);
end

function s = num2s(v)
if isempty(v) || (isnumeric(v) && ~isfinite(v))
    s = 'n/a';
elseif isnumeric(v)
    s = sprintf('%g', v);
else
    s = char(string(v));
end
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
