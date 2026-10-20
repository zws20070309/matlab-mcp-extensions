function get_variable(name, mode)
%GET_VARIABLE Inspect a variable from the base workspace of this session.
%   name: variable name (validated).
%   mode: 'summary' (default) -> class/size/numeric stats or struct fields
%         'head'             -> first rows of the data
%         'csv'              -> write full data to a CSV and print its path
if nargin < 1, name = ''; end
name = mcp_str(name); % MCP arg normalization, see mcp_str
if isempty(name)
    error('get_variable:badArgs', '[get_variable:badArgs] name is required');
end
try
    v = evalin('base', name);
catch
    error('get_variable:notFound', '[get_variable:notFound] Variable not found in base workspace: %s', name);
end
% Normalize FIRST, then test for empty: the bridge delivers an empty JSON
% string as a 1x1 string scalar, for which isempty() is false, so checking
% isempty before mcp_str left mode as '' and fell through to badMode.
mode = mcp_str(mode);
if isempty(mode)
    mode = 'summary';
end
mcp_tool_log('get_variable', sprintf('%s mode=%s', name, mode));
switch mode
    case 'summary'
        fprintf('name:  %s\n', name);
        fprintf('class: %s\n', class(v));
        fprintf('size:  %s\n', mat2str(size(v)));
        if isnumeric(v) && ~isempty(v)
            fprintf('min:   %g\nmax:   %g\nmean:  %g\n', ...
                min(v(:)), max(v(:)), mean(v(:), 'omitnan'));
        elseif islogical(v) && ~isempty(v)
            fprintf('true:  %d of %d\n', sum(v(:)), numel(v));
        elseif istable(v)
            fprintf('vars:  %s\n', strjoin(v.Properties.VariableNames, ', '));
            disp(head(v, 5));
        elseif isstruct(v)
            fprintf('fields: %s\n', strjoin(fieldnames(v), ', '));
        end
    case 'head'
        if istable(v)
            disp(head(v, 10));
        elseif isnumeric(v)
            r = min(10, size(v, 1));
            cc = min(10, size(v, 2));
            disp(v(1:r, 1:cc));
        elseif iscell(v)
            disp(v(1:min(10, numel(v))));
        else
            disp(v);
        end
    case 'csv'
        outDir = fullfile(mcp_ext_root(), 'exports');
        if ~exist(outDir, 'dir'), mkdir(outDir); end
        f = fullfile(outDir, sprintf('%s_%s.csv', name, ...
            char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))));
        if istable(v)
            writetable(v, f);
        elseif istimetable(v)
            writetimetable(v, f);
        elseif isnumeric(v)
            writematrix(v, f);
        elseif islogical(v)
            writematrix(double(v), f);
        else
            error('get_variable:notExportable', ...
                'class %s cannot be written to CSV; use mode=summary', class(v));
        end
        fprintf('written: %s\n', f);
    case 'json'
        % The only mode that survives a struct, table or timeseries: csv refuses
        % them and summary/head flatten away the values an agent actually needs
        % (e.g. the Result object of a simulation run).
        js = mcp_var_to_json(v, name);
        outDir = fullfile(mcp_ext_root(), 'exports');
        if ~exist(outDir, 'dir'), mkdir(outDir); end
        if numel(js) > 30000
            f = fullfile(outDir, sprintf('%s_%s.json', name, ...
                char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))));
            fid = fopen(f, 'w');
            fwrite(fid, js);
            fclose(fid);
            fprintf('too large to print (%d chars); full JSON written to %s\n', numel(js), f);
            fprintf('--- first 4000 chars ---\n%s\n', js(1:min(4000, numel(js))));
        else
            fprintf('%s\n', js);
        end
    otherwise
        error('get_variable:badMode', ...
            '[get_variable:badMode] mode must be summary|head|csv|json, got: %s', mode);
end
end

function js = mcp_var_to_json(v, name)
%MCP_VAR_TO_JSON Serialise a base-workspace variable to JSON text, bounded.
%   NaN/Inf become null through jsonencode's default ConvertInfAndNaN=true, which
%   is what a valid JSON consumer needs; large arrays are reduced to statistics
%   plus a head so a single tool result cannot blow past the client's output cap.
CAP = 20000;
p = struct('name', name, 'class', class(v), 'size', mat2str(size(v)), 'kind', '', 'note', '');
try
    if isstruct(v) && ~isempty(v)
        p.kind = 'struct';
        p.fields = string(fieldnames(v));
        if numel(v) == 1
            p.value = v;
        else
            p.note = sprintf('%dx%d struct array; element (1) expanded only', size(v, 1), size(v, 2));
            p.value = v(1);
        end
    elseif istable(v)
        p.kind = 'table';
        p.variables = string(v.Properties.VariableNames);
        p.rows = height(v);
        h = min(200, height(v));
        p.data = table2array(v(1:h, :));
        if height(v) > h
            p.note = 'first 200 rows only; use mode=csv for the whole table';
        end
    elseif istimetable(v)
        p.kind = 'timetable';
        p.rows = height(v);
        h = min(200, height(v));
        p.time = seconds(v.Time(1:h));
        p.data = table2array(v(1:h, :));
    elseif isa(v, 'timeseries')
        p.kind = 'timeseries';
        n = min(20000, size(v.Data, 1));
        p.time = double(v.Time(1:n));
        d = double(v.Data(1:n, :));
        if size(d, 1) == 1
            d = d.';
        end
        p.data = d;
        if size(v.Data, 1) > n
            p.note = sprintf('truncated to %d of %d samples; use mode=csv for all', n, size(v.Data, 1));
        end
    elseif iscell(v)
        p.kind = 'cell';
        p.numel = numel(v);
        if numel(v) <= 200
            p.value = v;
        else
            p.value = v(1:min(200, numel(v)));
            p.note = 'first 200 elements only';
        end
    elseif isnumeric(v) || islogical(v)
        p.kind = 'array';
        fv = double(v(:));
        if isreal(v) && isinteger(v)
            % Integer classes must NOT round-trip through double: int64(2^53+1)
            % loses its last digit (measured 2026-10-20: 9007199254740993 was
            % emitted as 9.007199254740992E+15). Emit exact decimal strings so a
            % consumer can parse them without precision loss.
            if numel(v) <= CAP
                p.value = int_exact(v);
                p.note = 'integer values emitted as exact decimal strings to avoid double precision loss';
            else
                p.value = int_exact(v(1:min(200, numel(v))));
                p.note = 'large integer array: first 200 exact values; use mode=csv for all';
            end
        elseif ~isreal(v)
            % jsonencode rejects complex values outright (measured 2026-10-20:
            % "Unable to encode complex-valued objects of class double"). A
            % complex variable used to abort the whole json mode instead of
            % degrading, so emit real/imag explicitly.
            if numel(v) <= CAP
                p.value = struct('real', real(v), 'imag', imag(v));
                p.note = 'complex values split into real/imag (JSON has no native complex type)';
            else
                p.value = struct('real', real(v(1:200)), 'imag', imag(v(1:200)));
                p.note = 'large complex array: first 200 real/imag pairs; use mode=csv for all';
            end
        elseif numel(fv) <= CAP
            p.value = reshape(double(v), size(v));
        else
            p.stats = struct('n', numel(fv), 'min', min(fv, [], 'all', 'omitnan'), ...
                'max', max(fv, [], 'all', 'omitnan'), 'mean', mean(fv, 'omitnan'), ...
                'std', std(fv, 0, 'omitnan'));
            p.value = fv(1:200).';
            p.note = 'large array: statistics + first 200 values; use mode=csv for all';
        end
    elseif ischar(v) || isstring(v)
        p.kind = 'text';
        t = char(string(v));
        if numel(t) > CAP
            t = t(1:CAP);
            p.note = 'text truncated';
        end
        p.value = t;
    else
        p.kind = 'unsupported';
        p.note = 'no JSON form for this class; use mode=summary, or write it with jsonencode/save yourself';
    end
catch e
    p.kind = 'error';
    p.note = [e.identifier ': ' e.message];
end
% jsonencode itself can throw (complex values, unsupported classes). It used to
% sit OUTSIDE the try block, so one bad variable aborted the entire tool call
% (measured 2026-10-20). Degrade to a diagnostic payload instead.
try
    js = jsonencode(p);
catch e
    p = struct('name', name, 'class', class(v), 'size', mat2str(size(v)), ...
        'kind', 'unserializable', ...
        'note', ['jsonencode failed: ' e.identifier ': ' e.message]);
    js = jsonencode(p);
end
end

function out = int_exact(v)
%INT_EXACT Exact decimal text for integer arrays, shape preserved.
%   string(v) keeps the class's full precision, unlike double(v) which rounds
%   int64 values above 2^53. Returns char for scalars (JSON string) and a cell
%   of char for arrays so the shape survives serialisation.
if isscalar(v)
    out = char(string(v));
    return
end
s = string(v);
if isvector(v)
    out = cellstr(s(:).');
else
    out = cellstr(reshape(s, size(v)));
end
end
