function hex = mcp_hash_file(path, algo)
%MCP_HASH_FILE Stream a file through a Java MessageDigest and return hex.
%   MATLAB has no matlab.lang.sha256 on this release (exist=0) and no built-in
%   digest function, yet provenance requirements ask for SHA-256 of every input
%   and output file. Java is present (verified: SHA-256 digest length 32), so
%   hashing goes through java.security.MessageDigest in a streaming loop and a
%   multi-GB file costs no extra memory.
if nargin < 2, algo = 'sha256'; end
path = mcp_str(path);
if ~isfile(path)
    % isfile, not exist(p,'file')==2: for a .slx/.mdl exist() returns 4 (Simulink
    % model), so the old guard declared real model files "not found" - found by
    % the v8 sweep while hashing a Simulink artifact.
    error('hash_file:notFound', '[hash_file:notFound] no such file: %s', path);
end
switch lower(strtrim(algo))
    case {'sha256', 'sha-256'}
        a = 'SHA-256';
    case {'sha1', 'sha-1'}
        a = 'SHA-1';
    case {'md5'}
        a = 'MD5';
    case {'sha512', 'sha-512'}
        a = 'SHA-512';
    otherwise
        error('hash_file:badAlgo', '[hash_file:badAlgo] algo must be sha256|sha512|sha1|md5, got %s', algo);
end
md = javaMethod('getInstance', 'java.security.MessageDigest', a);
% Stream through java.nio FileChannel + heap ByteBuffer. The data NEVER crosses
% the MATLAB<->Java array boundary: direct int8->byte[] marshalling mangles every
% byte >= 0x80 into 0x7F in this R2025a build (found 2026-10-12 hashing the
% v0.13.0 backup exe: MATLAB said 15690ded..., certutil/GitHub digest said
% 4e065398.... Pure-ASCII files were unaffected, which is why the v8-v12
% sweeps never caught it - every binary (exe/mat/png/slx) and every non-ASCII
% text (Chinese UTF-8 docs) hashed wrong until now.
pathJ = java.lang.String(path);
% RandomAccessFile.getChannel() instead of FileChannel.open(Paths.get(...)):
% Paths.get's (String, String...) varargs overload fails MATLAB method
% dispatch ("no matching signature"), RandomAccessFile's constructor is plain.
raf = java.io.RandomAccessFile(pathJ, 'r');
ch = raf.getChannel();
cr = onCleanup(@() closeQuietly(raf)); %#ok<NASGU>
bb = java.nio.ByteBuffer.allocate(2 ^ 20);
while true
    n = ch.read(bb);
    if n < 0
        break;
    end
    if n > 0
        bb.flip();
        md.update(bb);
    end
    bb.clear();
end
ch.close();
cr = []; %#ok<NASGU>
dj = md.digest();
d = double(dj(:));
d(d < 0) = d(d < 0) + 256;
digits = '0123456789abcdef';
out = blanks(numel(d) * 2);
for k = 1:numel(d)
    v = d(k);
    out(2*k-1) = digits(bitshift(uint8(v), -4) + 1);
    out(2*k)   = digits(bitand(uint8(v), uint8(15)) + 1);
end
hex = out;
end

function closeQuietly(ch)
try
    ch.close();
catch
end
end
