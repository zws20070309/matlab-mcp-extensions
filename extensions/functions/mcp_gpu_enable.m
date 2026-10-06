function st = mcp_gpu_enable(onOff)
%MCP_GPU_ENABLE Make the GPU usable and report what happened.
%   On this machine the GPU (RTX 5060, compute capability 12.0) is NEWER than
%   the CUDA libraries MATLAB R2025a ships natively, so every GPU call fails with
%     "GPU device is not supported because it has a higher compute capability
%      (12.0) than is natively supported by the CUDA libraries. Use
%      parallel.gpu.enableCUDAForwardCompatibility(true) ..."
%   until forward compatibility is turned on for the current MATLAB process.
%   The setting is PER PROCESS: a PCT batch worker starts with it OFF again
%   (verified: gpuDeviceCount('available')=0 in the session before enabling),
%   so anything that runs GPU code on a worker must call this helper first.
%
%   st = mcp_gpu_enable('1')   enable (default)
%   st = mcp_gpu_enable('0')   explicitly disable again
%
%   Enabling triggers a one-off JIT rebuild of the GPU libraries ("编译可能需要
%   几分钟"), so the first GPU operation is timed and reported as warmSec.
%   Returns a struct; MCP-facing tools print through gpu_probe so no value is
%   echoed as a stray `ans`.

st = struct('ok', false, 'priorFC', NaN, 'fcNow', NaN, 'device', '', ...
    'cc', '', 'driver', '', 'warmSec', NaN, 'checked', '', 'note', '');
% Selecting a device on a forward-compatibility build prints
% "将重新编译 GPU 库，因为您的设备比库更新..." as a MATLAB warning WITH EMBEDDED
% HTML ANCHORS on every process that touches the GPU first. That text is
% harmless to a human but destroys the parseability of a tool's output (the
% same output-pollution class as the checkpoint timer and the job diary), so it
% is suppressed for the duration of this call and restored by onCleanup.
prevW = warning('off', 'all');
rest = onCleanup(@() warning(prevW)); %#ok<NASGU> % must stay alive until the call ends
req = true;
if nargin >= 1
    s = lower(mcp_str(onOff));
    if any(strcmp(s, {'0', 'false', 'no', 'off', 'disable'}))
        req = false;
    end
end
try
    st.priorFC = parallel.gpu.enableCUDAForwardCompatibility;
catch e
    st.note = [st.note '| cannot read forward-compat flag: ' e.message];
end
try
    if req
        parallel.gpu.enableCUDAForwardCompatibility(true);
    else
        parallel.gpu.enableCUDAForwardCompatibility(false);
    end
catch e
    st.note = [st.note '| set failed: ' e.message];
end
try
    st.fcNow = parallel.gpu.enableCUDAForwardCompatibility;
catch
end
% A device handle is only obtainable once the library accepts the card.
try
    g = gpuDevice(1);
    st.device = char(string(g.Name));
    try
        st.cc = char(string(g.ComputeCapability));
    catch
    end
    try
        st.driver = char(string(g.DriverVersion));
    catch
    end
catch e
    st.note = [st.note '| gpuDevice: ' e.identifier ' ' e.message];
    return
end
% Warm-up doubles as proof that real arithmetic works, and measures the JIT cost.
try
    t0 = tic;
    A = gpuArray(single(rand(300)));
    P = A * A;
    c = gather(P(1, 1));
    st.warmSec = toc(t0);
    st.ok = isfinite(c);
    st.checked = sprintf('single 300x300 matmul = %.6g', c);
catch e
    st.note = [st.note '| warmup: ' e.identifier ' ' e.message];
end
end
