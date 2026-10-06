function h = mcp_tree_hash(rootPath, pattern, maxFiles)
%MCP_TREE_HASH Content digest of a source tree, so a log can prove WHICH tree it ran.
%   h = mcp_tree_hash(rootPath)            - SHA-256 over every .m file, 16 hex chars
%   h = mcp_tree_hash(rootPath, pattern)   - other glob
%   An archived certification is worthless later if it cannot be tied to a tree, and a
%   file/byte total can be shared by different trees, so this digests file CONTENT.
%   Verified on this host: java.security.MessageDigest gives the correct SHA-256 of "abc"
%   (DataHash/DigestStream are both unusable here). If Java is unavailable the result is
%   prefixed 'fnv' - still comparable between two calls, but explicitly not a SHA.
if nargin < 2, pattern = '*.m'; end
if nargin < 3, maxFiles = 5000; end
fl = cellstr(string(mcp_walk(rootPath, pattern)));
fl = fl(:);
n = lower(cellfun(@(p) strrep(p, '\', '/'), fl, 'UniformOutput', false));
[~, ord] = sort(n);
fl = fl(ord);
n = n(ord);
rootL = lower(strrep(strtrim(char(rootPath)), '\', '/'));
useJava = featureEnabled();
parts = strings(numel(fl), 1);
for k = 1:min(numel(fl), maxFiles)
    rel = n{k};
    if numel(rel) > numel(rootL) && strcmp(rel(1:numel(rootL)), rootL)
        rel = regexprep(strtrim(rel(numel(rootL) + 1:end)), '^/+', '');
    end
    parts(k) = string(sprintf('%s=%s', rel, oneDigest(fl{k}, useJava)));
end
if numel(fl) > maxFiles
    parts(end+1) = string(sprintf('TRUNCATED_AT=%d', maxFiles));
end
if useJava
    h = shaHex(strjoin(parts, '|'));
else
    h = ['fnv' fnvHex(strjoin(parts, '|'))];
end
h = h(1:min(16, numel(h)));
end

function on = featureEnabled()
try
    java.security.MessageDigest.getInstance('SHA-256');
    on = true;
catch
    on = false;
end
end

function s = oneDigest(p, useJava)
fid = fopen(p, 'rb');
if fid < 0
    s = 'unreadable';
    return
end
raw = fread(fid, Inf, 'uint8=>uint8');
fclose(fid);
raw = uint8(raw(:).');
if useJava
    s = shaBytes(raw);
else
    s = fnvBytes(raw);
end
end

function s = shaBytes(b)
jd = java.security.MessageDigest.getInstance('SHA-256');
jd.update(int8(b));
s = toHex(typecast(int8(jd.digest()), 'uint8'));
end

function s = shaHex(txt)
s = shaBytes(uint8(unicode2native(txt, 'UTF-8')));
end

function s = fnvBytes(b)
% FNV-1a 64-bit split over two 32-bit lanes; detects edits, not collisions-safe.
h1 = uint32(2166136261);
h2 = uint32(16777619);
p1 = uint32(16777619);
p2 = uint32(2246822519);
for k = 1:numel(b)
    v = b(k);
    h1 = bitxor(h1, uint32(v));
    h1 = h1 * p1;
    h2 = bitxor(h2, uint32(bitshift(v, 1)));
    h2 = h2 * p2;
end
s = toHex([typecast(h1, 'uint8') typecast(h2, 'uint8')]);
end

function s = fnvHex(txt)
s = fnvBytes(uint8(unicode2native(txt, 'UTF-8')));
end

function s = toHex(u)
s = lower(strtrim(strjoin(compose('%02x', u), '')));
end
