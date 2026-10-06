function file_op(action, target, optsJson)
%FILE_OP Read, write, hash, list, search and validate files through the MCP.
%   action: read | write | append | hash | list | tail | exists | stat | mkdir |
%           copy | delete | json | find | sub
%   target: absolute path (for copy: "SRC -> DST" is NOT used; put dst in opts.dst)
%   optsJson: {"content":"...", "encoding":"UTF-8", "startLine":1, "maxLines":200,
%              "cursor":0, "maxBytes":65536, "pattern":"error|Error",
%              "algo":"sha256", "recursive":false, "dst":"abs/path", "confirm":"yes",
%              "get":"counts.test_functions", "text":"literal", "regex":false,
%              "glob":"*.m", "find":"old", "replace":"new", "expect":1,
%              "noBackup":false, "allowQuote":false}
%
%   WHY: the extension layer had no file primitives at all, so every artifact a
%   simulation produced (HDF5 manifests, resolved configs, reference tables, run
%   logs) could only be touched by hand-written MATLAB inside evaluate_logged.
%   Two transport facts are baked in here instead of being rediscovered:
%     1) the code argument deletes newlines, so `content` must arrive as a JSON
%        STRING (its \n escapes survive the trip) - this tool jsondecodes it and
%        writes real line breaks;
%     2) client-side output is truncated from the front at roughly 44 KB, so
%        read/tail are bounded by maxBytes/maxLines and always report the total
%        size plus the next cursor rather than dumping a whole file.
%   delete requires confirm="yes" because it is irreversible; sub refuses when the
%   occurrence count differs from opts.expect, because a silent wrong-count
%   substitution edits governance documents.
%   Prints only; returns nothing.
if nargin < 3, optsJson = ''; end
action = lower(strtrim(mcp_str(action)));
target = mcp_str(target);
if isempty(action) || isempty(target)
    error('file_op:badArgs', '[file_op:badArgs] action and target are both required');
end
o = struct();
if ~isempty(strtrim(mcp_str(optsJson)))
    try
        o = jsondecode(mcp_str(optsJson));
    catch e
        error('file_op:badOpts', '[file_op:badOpts] optsJson must decode to an object: %s', e.message);
    end
end
mcp_tool_log('file_op', sprintf('%s %s', action, target));
enc = 'UTF-8';
if isfield(o, 'encoding'), enc = char(string(o.encoding)); end
switch action
    case {'read', 'tail'}
        if ~isfile(target)
            % isfile rather than exist(p,'file')==2: .slx/.mdl make exist() return
            % 4, which would report a real model file as missing.
            error('file_op:notFound', '[file_op:notFound] no such file: %s', target);
        end
        d = dir(target);
        maxB = 65536;
        if isfield(o, 'maxBytes'), maxB = max(1, round(mcp_num(o.maxBytes, 65536))); end
        if isfield(o, 'cursor')
            cur = max(0, round(mcp_num(o.cursor, 0)));
        else
            % No cursor means "show me the end of this file" - the question that
            % is actually being asked when someone reads a run log. One handle,
            % one seek: an earlier version closed and reopened the file here and
            % printed nothing at all.
            cur = max(0, d.bytes - maxB);
        end
        fid = fopen(target, 'r', 'n', enc);
        if fid < 0
            error('file_op:openFail', '[file_op:openFail] cannot open %s', target);
        end
        cr = onCleanup(@() quietClose(fid));
        fseek(fid, cur, 'bof');
        raw = fread(fid, maxB, 'uint8');
        got = numel(raw);
        txt = mcp_decode(raw, enc);
        if cur > 0
            % drop a partial leading line: a window that starts mid-UTF-8 or
            % mid-line produces garbage that reads like corruption
            q = strfind(txt, newline);
            if ~isempty(q) && q(1) < 200
                txt = txt(q(1) + 1:end);
            end
        end
        pnote = '';
        if isfield(o, 'pattern')
            pat = char(string(o.pattern));
            lines = regexp(txt, '\r?\n', 'split');
            hit = regexp(lines, pat, 'once');
            keepc = ~cellfun('isempty', hit);
            lines = lines(keepc);
            txt = strjoin(lines, newline);
            pnote = sprintf('pattern "%s" kept %d of %d line(s)', pat, numel(lines), numel(hit));
        end
        if isfield(o, 'maxLines')
            ml = max(1, round(mcp_num(o.maxLines, 200)));
            lines = regexp(txt, '\r?\n', 'split');
            if numel(lines) > ml
                lines = lines(end-min(ml, numel(lines))+1:end);
                txt = strjoin(lines, newline);
                pnote = [pnote ' | capped to the last ' num2str(ml) ' line(s)'];
            end
        end
        fprintf('file: %s  total=%d bytes  returned=%d bytes  window=[%d..%d]\n', ...
            target, d.bytes, got, cur, cur + got);
        fprintf('next_cursor=%d (pass it as opts.cursor to continue forward; window already at EOF=%d)\n', ...
            cur + got, cur + got >= d.bytes);
        if ~isempty(pnote)
            fprintf('filter: %s\n', pnote);
        end
        fprintf('---\n%s\n', txt);
    case {'write', 'append'}
        if ~isfield(o, 'content')
            error('file_op:badArgs', '[file_op:badArgs] write/append need opts.content (a JSON string; use \\n for line breaks)');
        end
        txt = o.content;
        if ~ischar(txt) && ~isstring(txt)
            txt = jsonencode(txt);
        else
            txt = char(string(txt));
        end
        p = fileparts(target);
        if ~isempty(p) && ~exist(p, 'dir')
            mkdir(p);
        end
        mode = 'w';
        if strcmp(action, 'append')
            mode = 'a';
        end
        fid = fopen(target, mode, 'n', enc);
        if fid < 0
            error('file_op:openFail', '[file_op:openFail] cannot open %s for %s', target, action);
        end
        c2 = onCleanup(@() quietClose(fid));
        txt = mcp_flat(txt);
        fwrite(fid, unicode2native(txt, enc));
        fclose(fid);
        c2 = []; %#ok<NASGU>
        d = dir(target);
        fprintf('wrote %s (%d bytes, mode=%s, encoding=%s)\n', target, d.bytes, action, enc);
        try
            fprintf('sha256=%s\n', mcp_hash_file(target, 'sha256'));
        catch
        end
    case 'hash'
        algo = 'sha256';
        if isfield(o, 'algo'), algo = lower(char(string(o.algo))); end
        rec = false;
        if isfield(o, 'recursive'), rec = truthy(o.recursive); end
        if exist(target, 'dir') == 7 || rec
            fl = mcp_walk(target);
            fprintf('%-70s %s\n', 'file', algo);
            for k = 1:numel(fl)
                try
                    fprintf('%-70s %s\n', strrep(fl{k}, '\', '/'), mcp_hash_file(fl{k}, algo));
                catch e
                    fprintf('%-70s ERR %s\n', fl{k}, e.identifier);
                end
            end
            fprintf('%d file(s) hashed under %s\n', numel(fl), target);
        else
            fprintf('%s  %s=%s\n', target, algo, mcp_hash_file(target, algo));
        end
    case 'list'
        if exist(target, 'dir') ~= 7
            error('file_op:notFound', '[file_op:notFound] no such directory: %s', target);
        end
        pat = '*';
        if isfield(o, 'pattern'), pat = char(string(o.pattern)); end
        maxE = 200;
        if isfield(o, 'maxLines'), maxE = max(1, round(mcp_num(o.maxLines, 200))); end
        d = dir(fullfile(target, pat));
        if truthyget(o, 'recursive')
            all = mcp_walk(target);
            fprintf('%-80s size\n', 'path');
            for k = 1:min(maxE, numel(all))
                dd = dir(all{k});
                fprintf('%-80s %d\n', strrep(all{k}, '\', '/'), dd.bytes);
            end
            fprintf('%d entries shown of %d total\n', min(maxE, numel(all)), numel(all));
            return
        end
        fprintf('%-60s %10s %-12s %s\n', 'name', 'bytes', 'date', 'kind');
        for k = 1:min(maxE, numel(d))
            if strcmp(d(k).name, '.') || strcmp(d(k).name, '..')
                continue
            end
            fprintf('%-60s %10d %-12s %s\n', d(k).name, d(k).bytes, d(k).date(1:10), ...
                tern(d(k).isdir, 'dir', 'file'));
        end
        fprintf('%d entries (maxLines controls the cap; total=%d)\n', min(maxE, numel(d)), numel(d));
    case 'exists'
        kind = '-';
        if isdir(target)
            kind = 'dir';
        elseif isfile(target)
            kind = 'file';
        end
        fprintf('%s exists=%d kind=%s\n', target, exist(target), kind);
    case 'mkdir'
        if ~exist(target, 'dir')
            mkdir(target);
        end
        fprintf('dir ready: %s\n', target);
    case 'copy'
        if ~isfield(o, 'dst')
            error('file_op:badArgs', '[file_op:badArgs] copy needs opts.dst');
        end
        dst = char(string(o.dst));
        p = fileparts(dst);
        if ~isempty(p) && ~exist(p, 'dir')
            mkdir(p);
        end
        copyfile(target, dst, 'f');
        d = dir(dst);
        fprintf('copied -> %s (%d bytes)\n', dst, d.bytes);
    case 'delete'
        if ~isfield(o, 'confirm') || ~strcmp(lower(char(string(o.confirm))), 'yes')
            fprintf('DRY RUN: would delete %s (rerun with opts.confirm="yes")\n', target);
            if exist(target, 'file') == 2
                d = dir(target);
                fprintf('  size=%d bytes modified=%s\n', d.bytes, d.date);
            end
            return
        end
        delete(target);
        fprintf('deleted %s (still present=%d)\n', target, exist(target));
    case 'stat'
        d = dir(target);
        if isempty(d)
            fprintf('%s exists=0\n', target);
            return
        end
        if numel(d) > 1
            % dir() on a pattern returns many rows; the aggregate is what matters
            fprintf('%s matches=%d bytes=%d newest=%s silence=%ds\n', target, numel(d), ...
                sum([d.bytes]), char(datetime(max([d.datenum]), 'ConvertFrom', 'datenum')), ...
                round((now - max([d.datenum])) * 86400));
            return
        end
        fprintf('%s exists=1 kind=%s bytes=%d lines=%s modified=%s age_sec=%d\n', ...
            target, tern(d.isdir, 'dir', 'file'), d.bytes, mat2s(line_count(target)), ...
            d.date, round((now - d.datenum) * 86400));
    case 'json'
        txt = mcp_read_text(target);
        if isempty(txt) && ~isfile(target)
            error('file_op:notFound', '[file_op:notFound] no such file: %s', target);
        end
        try
            js = jsondecode(txt);
        catch e
            fprintf('JSON INVALID: %s\n', e.message);
            susp = bad_quote_offset(txt);
            if ~isempty(susp)
                fprintf('suspect offset=%d line=%d: an ASCII double quote inside a string value that does not close it\n', ...
                    susp, numel(strfind(txt(1:susp), newline)) + 1);
                fprintf('context: ...%s...\n', oneLine(txt(max(1, susp - 70):min(numel(txt), susp + 40)), 220));
                fprintf('governance rule for register/manifest files: use 「」 instead of ASCII quotes inside Chinese text\n');
            end
            return
        end
        if ~isstruct(js) && ~iscell(js)
            fprintf('JSON VALID (%d bytes, scalar %s)\n', numel(txt), class(js));
            return
        end
        fprintf('JSON VALID: %d bytes, top-level keys: %s\n', numel(txt), strjoin(fieldnames_of(js), ', '));
        if isfield(o, 'get')
            v = dotget(js, char(string(o.get)));
            fprintf('%s = %s\n', char(string(o.get)), val_str(v));
        end
    case 'find'
        % Literal (or regex) search with line numbers: the way to prove an
        % evidence anchor exists verbatim in the file it points at, and the way
        % to answer "does this identifier appear anywhere" without reading trees.
        if isfield(o, 'text')
            needle = char(string(o.text));
        elseif isfield(o, 'pattern')
            needle = char(string(o.pattern));
        else
            error('file_op:badArgs', '[file_op:badArgs] find needs opts.text (literal) or opts.pattern (regex)');
        end
        useRe = truthyget(o, 'regex');
        maxH = 40;
        if isfield(o, 'maxLines'), maxH = max(1, round(mcp_num(o.maxLines, 40))); end
        files = {target};
        if exist(target, 'dir') == 7
            glob = '*.m';
            if isfield(o, 'glob'), glob = char(string(o.glob)); end
            files = mcp_walk(target, glob);
            if isempty(files)
                fprintf(['WARNING: 0 files matched glob "%s" under %s - NOTHING was searched, ' ...
                    'so matches=0 below is NOT evidence of absence (pass opts.glob, e.g. "*.json" or "*")' ...
                    newline], char(string(glob)), target);
            end
        end
        total = 0;
        for k = 1:numel(files)
            txt = mcp_read_text(files{k});
            if isempty(txt), continue; end
            lines = regexp(txt, '\r?\n', 'split');
            for j = 1:numel(lines)
                if useRe
                    hit = ~isempty(regexp(lines{j}, needle, 'once'));
                else
                    hit = ~isempty(strfind(lines{j}, needle));
                end
                if hit
                    total = total + 1;
                    if total <= maxH
                        fprintf('%s:%d: %s\n', strrep(files{k}, '\', '/'), j, oneLine(lines{j}, 160));
                    end
                end
            end
        end
        fprintf('matches=%d in %d file(s), cap %d shown, %ssearch=%s\n', ...
            total, numel(files), maxH, tern(useRe, 'regex ', 'literal '), needle);
    case 'sub'
        if ~isfile(target)
            error('file_op:notFound', '[file_op:notFound] no such file: %s', target);
        end
        if ~isfield(o, 'find') || ~isfield(o, 'replace')
            error('file_op:badArgs', '[file_op:badArgs] sub needs opts.find and opts.replace (literal text)');
        end
        a = char(string(o.find));
        b = char(string(o.replace));
        txt = mcp_read_text(target);
        hits = strfind(txt, a);
        want = mcp_num(fldnum(o, 'expect', 1), 1);
        fprintf('occurrences=%d (expect=%g)\n', numel(hits), want);
        if numel(hits) ~= want
            error('file_op:count', ...
                ['[file_op:count] refusing to substitute: found %d occurrence(s) of the find-text, expected %g. ' ...
                 'Widen opts.find to unique context, or pass the real expect value.'], numel(hits), want);
        end
        if isempty(hits)
            error('file_op:notFoundText', '[file_op:notFoundText] text not present in %s', target);
        end
        if any(b == '"') && endsWith(lower(target), '.json') && ~truthyget(o, 'allowQuote')
            error('file_op:quote', ...
                ['[file_op:quote] opts.replace contains an ASCII double quote and the target is a .json file. ' ...
                 'Unescaped quotes inside Chinese register strings have broken this repository''s JSON twice. ' ...
                 'Use 「」 or pass allowQuote=true if the quotes are escaped and intended.']);
        end
        out = strrep(txt, a, b);
        if ~isempty(out) && numel(out) > 4e6
            error('file_op:tooBig', '[file_op:tooBig] %d bytes after substitution; use a script', numel(out));
        end
        bak = '';
        if ~truthyget(o, 'noBackup')
            bak = [target '.bak-' char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd''T''HHmmss''Z'''))];
            copyfile(target, bak, 'f');
        end
        fid = fopen(target, 'wb');
        if fid < 0
            error('file_op:openFail', '[file_op:openFail] cannot write %s', target);
        end
        fwrite(fid, unicode2native(out, 'UTF-8'));
        fclose(fid);
        fprintf('substituted %d occurrence(s) in %s (%d -> %d bytes)\n', numel(hits), target, numel(txt), numel(out));
        if ~isempty(bak)
            fprintf('backup: %s\n', bak);
        end
    otherwise
        error('file_op:badAction', ...
            ['[file_op:badAction] unknown action "%s"; use read|write|append|hash|list|tail|exists|stat|' ...
             'json|find|sub|mkdir|copy|delete'], action);
end
end

function t = mcp_decode(b, enc)
%MCP_DECODE Turn raw bytes into text using the requested encoding.
%   fread(fid, n, 'uint8=>char') reinterprets every BYTE as a char, which turns
%   UTF-8 multi-byte text (any non-ASCII path on this machine) into mojibake even
%   when fopen was given the right encoding - fopen's encoding argument only
%   applies to text-class reads. This was the real cause of the garbled
%   <WORKSPACE>/... paths seen while reading tools.log; the log writer itself was
%   already UTF-8 (confirmed at byte level).
t = '';
try
    b = uint8(b(:).');
    if isempty(b)
        return
    end
    t = char(native2unicode(b, enc));
catch
    t = char(b);
end
end

function t = mcp_flat(t)
%MCP_FLAT Force a char row vector, joining multi-row char with newlines so a
%   written file keeps the caller's line structure instead of failing the
%   orientation check inside unicode2native.
try
    if iscell(t)
        t = strjoin(string(t), newline);
        t = char(t);
    end
    if size(t, 1) > 1
        rows = cell(size(t, 1), 1);
        for k = 1:size(t, 1)
            rows{k} = t(k, :);
        end
        t = strjoin(rows, newline);
    end
    t = t(:).';
catch
end
end

function tf = truthyget(s, f)
tf = false;
if isfield(s, f)
    tf = truthy(s.(f));
end
end

function tf = truthy(v)
if islogical(v) || isnumeric(v)
    tf = any(double(v(:)) ~= 0);
else
    tf = any(strcmp(lower(strtrim(char(string(v)))), {'1', 'true', 'yes', 'on'}));
end
end

function out = tern(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end

function quietClose(fid)
try
    if fid > 0
        fclose(fid);
    end
catch
end
end

function s = mat2s(v)
if isempty(v)
    s = 'n/a';
elseif isnumeric(v) || islogical(v)
    s = mat2str(v);
else
    s = char(string(v));
end
end

function n = line_count(p)
% Byte-accurate line count: read in windows so a 50 MB log does not load whole.
n = 0;
fid = fopen(p, 'rb');
if fid < 0
    n = [];
    return
end
c = onCleanup(@() quietClose(fid));
while true
    raw = fread(fid, 4194304, 'uint8');
    if isempty(raw)
        break
    end
    n = n + nnz(raw == 10);
end
clear c
end

function names = fieldnames_of(js)
if isstruct(js)
    names = fieldnames(js);
elseif iscell(js)
    names = {sprintf('cell array, %d element(s)', numel(js))};
else
    names = {};
end
end

function v = dotget(s, pathStr)
v = [];
parts = strsplit(pathStr, '.');
for k = 1:numel(parts)
    if isstruct(s) && isfield(s, parts{k})
        s = s.(parts{k});
    else
        return
    end
end
v = s;
end

function s = val_str(v)
if isempty(v)
    s = '(absent)';
elseif isnumeric(v) || islogical(v)
    if numel(v) == 1
        s = sprintf('%g', double(v));
    else
        s = sprintf('[%s]', strjoin(cellstr(num2str(v(:))), ', '));
    end
elseif iscell(v)
    s = sprintf('cell(%dx%d)', size(v, 1), size(v, 2));
else
    s = char(string(v));
end
if numel(s) > 200
    s = [s(1:200) '...'];
end
end

function n = fldnum(s, f, dflt)
n = dflt;
if isfield(s, f)
    n = mcp_num(s.(f), dflt);
end
end

function pos = bad_quote_offset(txt)
% First position that looks like a stray ASCII double quote inside a JSON string
% value: a '"' that closes no string, because the next non-space character is not
% one of , } ] :. Reported as a suspect, not a proof - the measured breakage in
% this workspace was exactly this defect at a stable character offset.
pos = [];
inStr = false;
esc = false;
for k = 1:numel(txt)
    c = txt(k);
    if inStr
        if esc
            esc = false;
        elseif c == '\'
            esc = true;
        elseif c == '"'
            j = k + 1;
            while j <= numel(txt) && (txt(j) == ' ' || txt(j) == char(9) || txt(j) == char(13) || txt(j) == char(10))
                j = j + 1;
            end
            if j > numel(txt) || ~any(txt(j) == [',}]:'])
                pos = k;
                return
            end
            inStr = false;
        end
    elseif c == '"'
        inStr = true;
    end
end
end

function s = oneLine(v, nw)
s = strtrim(strrep(char(string(v)), newline, ' '));
if numel(s) > nw
    s = [s(1:nw) '...'];
end
end
