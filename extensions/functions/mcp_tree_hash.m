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
% Outer fingerprint over the per-file digest list. CORRECTION 2026-10-28:
% this used to be a Java SHA-256 over the parts string - but the parts carry
% RELATIVE PATHS, which on this host are routinely Chinese, and the
% int8->byte[] marshalling mangled exactly those (same defect as oneDigest).
% FNV-1a is pure MATLAB over unicode2native bytes, crosses no boundary, and
% stays deterministic; its job here is change detection, not cryptography.
h = ['fnv' fnvHex(strjoin(parts, '|'))];
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
%   CORRECTION 2026-10-28: this used to be jd.update(int8(raw)) - and that
%   MATLAB-int8 -> Java-byte[] marshalling mangles every byte >= 0x80 into
%   0x7F (the exact defect mcp_hash_file was fixed for with a FileChannel).
%   Live proof: on a file with Chinese text the two paths produced DIFFERENT
%   digests, so every tree with non-ASCII source got a fake "SHA-256". The
%   per-file digest now reuses mcp_hash_file's streaming channel path, where
%   the bytes never cross the MATLAB<->Java array boundary.
if useJava
    try
        s = mcp_hash_file(p, 'sha256');
    catch
        s = 'unreadable';
    end
    return
end
fid = fopen(p, 'rb');
if fid < 0
    s = 'unreadable';
    return
end
raw = fread(fid, Inf, 'uint8=>uint8');
fclose(fid);
raw = uint8(raw(:).');
s = fnvBytes(raw);
end

function s = fnvBytes(b)
% FNV-1a 64-bit split over two 32-bit lanes; detects edits, not collisions-safe.
%   CORRECTION 2026-10-28: this used uint32 arithmetic for the multiply, but
%   MATLAB integer arithmetic SATURATES on overflow instead of wrapping, so
%   h1 locked at 0xFFFFFFFF after the first multiply and every digest came out
%   as an all-FF constant (found when the outer fingerprint switched to this
%   path and returned 'fnvfffffffffffff' for every tree). The lanes now run in
%   double with explicit mod-2^32 multiplies, which are exact below 2^53.
h1 = 2166136261;
h2 = 16777619;
p1 = 16777619;
p2 = 2246822519;
for k = 1:numel(b)
    v = double(b(k));
    h1 = mul32(bitxor(h1, v), p1);
    h2 = mul32(bitxor(h2, bitshift(v, 1)), p2);
end
s = [toHexLane(h1) toHexLane(h2)];
end

function h = mul32(a, b)
% (a*b) mod 2^32 for 0 <= a,b < 2^32 kept in double. Split into 16-bit halves:
% every partial product stays below 2^45, well inside double's 53-bit mantissa.
alo = mod(a, 65536);
ahi = bitshift(a, -16);
blo = mod(b, 65536);
bhi = bitshift(b, -16);
lo = mod(alo * blo, 4294967296);
mid = mod(mod(ahi * blo, 4294967296) + mod(alo * bhi, 4294967296), 4294967296);
h = mod(mid * 65536 + lo, 4294967296);
end

function s = toHexLane(v)
% 8 lowercase hex digits of one 32-bit lane (big-endian order), no Java.
d = [bitshift(v, -28) bitand(bitshift(v, -24), 15) bitand(bitshift(v, -20), 15) ...
     bitand(bitshift(v, -16), 15) bitand(bitshift(v, -12), 15) bitand(bitshift(v, -8), 15) ...
     bitand(bitshift(v, -4), 15) bitand(v, 15)];
digits = '0123456789abcdef';
s = digits(d + 1);
end

function s = fnvHex(txt)
s = fnvBytes(uint8(unicode2native(txt, 'UTF-8')));
end

function s = toHex(u)
s = lower(strtrim(strjoin(compose('%02x', u), '')));
end
