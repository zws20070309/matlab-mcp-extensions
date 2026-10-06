function sl_compare(aRef, bRef, tolJson, maxShift)
%SL_COMPARE Judge a MATLAB trace against a Simulink trace WITHOUT being fooled
%   by the logging offset.
%   aRef / bRef : "ws:VAR" for a base-workspace variable, or the path to a
%                2-column CSV (time, value) as written by sl_sim.
%   tolJson     : {"peak":1e-3,"area":1e-3,"sample":1e-6} relative tolerances
%                 ('' = those defaults; "sample" is absolute).
%   maxShift    : how many integer samples of relative offset to try ('' = 4).
%
%   The reason this exists is a measured trap: a To Workspace trace of a
%   300-step run arrived as 301 samples, so comparing index-for-index gave
%   area_rel=5.4e-3 (a false FAIL against a 0.1% gate) while the same pair
%   compared after a one-sample shift agreed to 2.2e-14 (a true PASS). Shifts are
%   searched, reported honestly with the metrics at shift 0, and the verdict
%   names the offset instead of blaming physics.
%   Prints only; returns nothing.
if nargin < 4, maxShift = ''; end
if nargin < 3, tolJson = ''; end
a = mcp_load_ref(mcp_str(aRef));
b = mcp_load_ref(mcp_str(bRef));
if isempty(a.y) || isempty(b.y)
    error('sl_compare:load', ...
        '[sl_compare:load] could not load both traces. Use "ws:VAR" or a 2-column CSV path. (a ok=%d, b ok=%d)', ...
        ~isempty(a.y), ~isempty(b.y));
end
tp = struct('peak', 1e-3, 'area', 1e-3, 'sample', 1e-6);
if ~isempty(strtrim(mcp_str(tolJson)))
    try
        tj = jsondecode(mcp_str(tolJson));
        for f = fieldnames(tj)'
            if isfield(tp, f{1})
                tp.(f{1}) = mcp_num(tj.(f{1}), tp.(f{1}));
            end
        end
    catch e
        error('sl_compare:badTol', '[sl_compare:badTol] tolJson must be an object of numbers: %s', e.message);
    end
end
S = max(0, round(mcp_num(maxShift, 4)));
if ~isfinite(S), S = 4; end
fprintf('a: %s  n=%d  t=[%g .. %g]\n', a.src, numel(a.y), a.t(1), a.t(end));
fprintf('b: %s  n=%d  t=[%g .. %g]\n', b.src, numel(b.y), b.t(1), b.t(end));
if numel(a.y) ~= numel(b.y)
    fprintf('NOTE length differs by %d sample(s) - exactly the shape a leading/trailing log sample produces\n', ...
        numel(a.y) - numel(b.y));
end
dtb = NaN;
if numel(b.t) > 1
    dtb = median(diff(b.t(:)));
end
if ~isfinite(dtb) || dtb <= 0
    dtb = 1;
end
best = struct('s', NaN, 'mx', Inf, 'pk', NaN, 'ar', NaN);
zero = struct('mx', NaN, 'pk', NaN, 'ar', NaN);
for s = -S:S
    m0 = metrics(a, b, s, dtb);
    if isnan(m0.mx)
        continue
    end
    tag = '      ';
    if s == 0, tag = '(*0)  '; end
    fprintf('  shift %+d  max_abs=%.4e  peak_rel=%.4e  area_rel=%.4e %s\n', s, m0.mx, m0.pk, m0.ar, tag);
    if m0.mx < best.mx
        best = struct('s', s, 'mx', m0.mx, 'pk', m0.pk, 'ar', m0.ar);
    end
    if s == 0
        zero = m0;
    end
end
if ~isfinite(zero.mx)
    error('sl_compare:noOverlap', '[sl_compare:noOverlap] the two time axes never overlap (shift range +/-%d)', S);
end
fprintf('at shift 0 : max_abs=%.4e peak_rel=%.4e area_rel=%.4e\n', zero.mx, zero.pk, zero.ar);
fprintf('best shift %+d : max_abs=%.4e peak_rel=%.4e area_rel=%.4e\n', best.s, best.mx, best.pk, best.ar);
if best.s ~= 0 && best.mx < zero.mx / 100
    fprintf('DIAGNOSIS the traces are offset by %+d sample(s) (%.9g s); removing it improves max_abs from %.3e to %.3e, so the mismatch was bookkeeping not physics\n', ...
        best.s, best.s * dtb, zero.mx, best.mx);
elseif best.s ~= 0
    % Metrics that barely move across the whole shift range mean no offset
    % explains the difference; claiming "bookkeeping" there would be a lie.
    fprintf('NOTE best shift is %+d but the metrics are flat across shifts (%.3e -> %.3e): this is a real signal difference, NOT a logging offset\n', ...
        best.s, zero.mx, best.mx);
end
okS = best.mx <= tp.sample;
okP = best.pk <= tp.peak;
okA = best.ar <= tp.area;
fprintf('GATES sample<=%.3g:%d  peak<=%.3g:%d  area<=%.3g:%d -> %s\n', ...
    tp.sample, okS, tp.peak, okP, tp.area, okA, tern(all([okS okP okA]), 'PASS', 'FAIL'));
if ~all([okS okP okA]) && best.s ~= 0
    fprintf('hint: still failing after removing the offset - check solver step vs sample time, initial conditions and block delays\n');
elseif ~all([okS okP okA])
    fprintf('hint: with no offset left to remove this is a real model/implementation difference\n');
end
mcp_tool_log('sl_compare', sprintf('%s vs %s best=%d pass=%d', a.src, b.src, best.s, all([okS okP okA])));
end

function m = metrics(a, b, s, dtb)
m = struct('mx', NaN, 'pk', NaN, 'ar', NaN);
tb = b.t(:) + s * dtb;
lo = max(a.t(1), tb(1));
hi = min(a.t(end), tb(end));
if hi <= lo
    return
end
g = (lo:(dtb / 50):hi)';
ya = interp1(a.t(:), a.y(:), g, 'linear', NaN);
yb = interp1(tb, b.y(:), g, 'linear', NaN);
ok = isfinite(ya) & isfinite(yb);
if nnz(ok) < 3
    return
end
ya = ya(ok);
yb = yb(ok);
g = g(ok);
m.mx = max(abs(ya - yb));
pa = max(ya);
pb = max(yb);
den = max([abs(pa) abs(pb)]);
if den > 0
    m.pk = abs(pa - pb) / den;
else
    m.pk = 0;
end
aa = trapz(g, ya);
ab = trapz(g, yb);
if abs(aa) > 0
    m.ar = abs(aa - ab) / abs(aa);
else
    m.ar = abs(aa - ab);
end
end

function r = mcp_load_ref(ref)
r = struct('t', [], 'y', [], 'src', ref);
if numel(ref) > 3 && strcmp(ref(1:3), 'ws:')
    nm = ref(4:end);
    try
        v = evalin('base', nm);
    catch e
        fprintf('  load %s failed: %s\n', nm, e.identifier);
        return
    end
    if isa(v, 'timeseries')
        r.t = v.Time(:);
        r.y = double(v.Data(:));
    elseif isnumeric(v) && isvector(v)
        r.y = double(v(:));
        r.t = (1:numel(v))';
        % sl_sim stores each logged signal as <name>__t / <name>__y; when asked
        % for the value half, pick up the matching time axis so the comparison is
        % done on real simulation time instead of an index surrogate.
        if numel(nm) > 3 && strcmp(nm(end-2:end), '__y')
            tn = [nm(1:end-3) '__t'];
            try
                tv = evalin('base', tn);
                if isnumeric(tv) && numel(tv) == numel(r.y)
                    r.t = double(tv(:));
                    r.src = [ref ' (time from ' tn ')'];
                end
            catch
            end
        end
    elseif istable(v)
        cn = v.Properties.VariableNames;
        ti = find(contains(lower(cn), 'time'), 1);
        yi = find(contains(lower(cn), {'data','y','val'}), 1);
        if ~isempty(ti) && ~isempty(yi)
            r.t = double(v.(cn{ti})(:));
            r.y = double(v.(cn{yi})(:));
        end
    end
    return
end
if exist(ref, 'file') ~= 2
    fprintf('  file not found: %s\n', ref);
    return
end
M = readmatrix(ref);
if size(M, 2) < 2
    fprintf('  %s has %d columns, need 2 (time,value)\n', ref, size(M, 2));
    return
end
r.t = M(:, 1);
r.y = M(:, 2);
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
