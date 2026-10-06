function s = mcp_out_summary(out)
%MCP_OUT_SUMMARY Compact value fingerprint of a job result.
%   job_status reports outClass/outSize, which cannot distinguish a correct
%   result from a corrupted one of the same shape. This adds a cheap numeric
%   summary so a caller can spot "right shape, wrong numbers" without
%   downloading result.mat.

s = '';
try
    if isnumeric(out) && ~isempty(out)
        v = double(out(:));
        vf = v(isfinite(v));
        if isempty(vf)
            s = sprintf('n=%d all-nonfinite', numel(out));
        else
            s = sprintf('n=%d sum=%.10g mean=%.10g min=%.10g max=%.10g h=%d', ...
                numel(out), sum(vf), mean(vf), min(vf), max(vf), mcp_hashify(vf));
        end
    elseif islogical(out) && ~isempty(out)
        s = sprintf('n=%d true=%d', numel(out), nnz(out));
    elseif ischar(out) || isstring(out)
        t = char(string(out));
        b = double(t(:))';
        s = sprintf('chars=%d h=%d', numel(t), mcp_hashify(b));
    elseif isstruct(out)
        fn = fieldnames(out);
        parts = cell(1, min(numel(fn), 8));
        for k = 1:numel(parts)
            parts{k} = sprintf('%s:%s', fn{k}, mcp_out_summary(out.(fn{k})));
        end
        s = sprintf('struct{%s}', strjoin(parts, '; '));
    elseif iscell(out)
        s = sprintf('cell %s', mat2str(size(out)));
    elseif istable(out) || istimetable(out)
        s = sprintf('%s %dx%d', class(out), height(out), width(out));
    else
        s = sprintf('class=%s size=%s', class(out), mat2str(size(out)));
    end
catch
    s = '(summary unavailable)';
end
end

function h = mcp_hashify(v)
% Position-weighted byte sum, folded into a positive 32-bit range. Deterministic
% and cheap; not cryptographic - only meant to make a changed result noticeable.
h = 0;
try
    % Both operands MUST be columns: with R2016b+ implicit expansion a (nx1) .*
    % (1xn) pair silently produces an nxn outer product, sum() then returns a
    % VECTOR, and sprintf cycles the format - which turned every char field into
    % a garbled repeated "chars=N h=..." blob in done.json (found 2026-09-19).
    v = v(:);
    n = min(numel(v), 100000);
    w = (1:n)';
    h = mod(sum(w .* mod(round(abs(v(1:n)) * 31), 1048576)) + ...
        mod(round(abs(v(1)) * 7), 1048576), 2147483647);
    h = h(1);
catch
end
end
