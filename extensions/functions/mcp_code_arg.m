function code = mcp_code_arg(code, toolName)
%MCP_CODE_ARG Normalize and sanity-check a `code` argument.
%   Newline characters are removed in transit **on the custom-tool (extension
%   file) argument path**: a two-line code argument arrives as a single line
%   with the rows concatenated (verified live: '[1 2<nl>3 4]' became '[1 23 4]',
%   producing a 1x3 matrix instead of 2x2 with no error at all). Because the
%   result is still syntactically valid MATLAB, no general syntactic check can
%   detect it, so this helper provides:
%     1. '@@NL@@' -> newline expansion. The token is plain ASCII and survives
%        transit intact, so multi-line code CAN be sent through `code`.
%     2. A loud guard for the one corruption shape that is detectable: no line
%        breaks anywhere plus a '%' comment with code after it, which would
%        silently discard the remainder of the program.
%   codeFile remains the preferred channel for long programs.
%
%   SCOPE CORRECTION (2026-10-07, re-measured against v0.13.0): the v8 report
%   attributed this to "the MCP argument pipeline" / the Go layer generally,
%   which is too broad and partly wrong. Measured on the same host:
%     evaluate_matlab_code  '[1 2<nl>3 4]'  -> ROWS=2 COLS=2   (newlines KEPT)
%     evaluate_matlab_code  '[10 20<nl>30 40]' -> ROWS=2 COLS=2 SUM=100 (KEPT)
%     evaluate_logged       same input       -> ROWS=1 COLS=3   (STRIPPED)
%     file_op write  "ALPHA\nBRAVO\nCHARLIE\n" -> 20 bytes, 3 lines back (KEPT)
%   So the built-in tools are NOT affected, and the JSON argument layer is not
%   the culprit either. Both callers of this helper are custom tools registered
%   through --extension-file, which is where the stripping lives. The exact
%   layer (Go-side command assembly vs. the MATLAB-side eval of the generated
%   call) has NOT been isolated -- do not claim more than "custom-tool argument
%   path" until it is.

if nargin < 2, toolName = 'mcp_code_arg'; end
NL = char(10);
code = mcp_str(code);
code = strrep(code, '@@NL@@', NL);
if isempty(code)
    return
end
if any(code == NL) || any(code == char(13))
    return   % line structure present: nothing to guard against
end
q = mcp_first_comment(code);
if q > 0
    tail = code(q+1:end);
    if numel(strtrim(tail)) > 3 && ~isempty(regexp(tail, '[=;(]', 'once'))
        % The identifier is repeated inside the message text on purpose: the
        % server flattens MATLAB exceptions to "matlab error: <localized text>"
        % and drops the identifier entirely (its own log calls this an
        % "Unstructured handler returned an error"), so a client could not
        % branch on it. With the tag inline, the failure is machine-detectable.
        tag = [toolName ':multilineStripped'];
        error(tag, '[%s] %s', tag, strjoin({ ...
            'The code argument has no line breaks but contains a ''%'' comment', ...
            'followed by what looks like more code. Its newlines were lost in', ...
            'transit, so everything after the ''%'' would be silently discarded.', ...
            'Send the code through codeFile, or replace each line break with the', ...
            '@@NL@@ token. Caveat measured 2026-09-19: @@NL@@ is for breaks', ...
            'BETWEEN statements only - inside a single-quoted string it expands to', ...
            'a real newline and MATLAB rejects a literal containing one', ...
            '(m_unterminated_string). Inside a string use newline, char(10), or', ...
            'disp() instead.'}, ' '));
    end
end
end

function q = mcp_first_comment(code)
% Index of the first '%' that is outside a quoted literal; 0 if there is none.
q = 0;
inS = false;
inD = false;
n = numel(code);
k = 1;
while k <= n
    ch = code(k);
    if inS
        if ch == ''''
            if k < n && code(k+1) == ''''
                k = k + 2;
                continue
            end
            inS = false;
        end
    elseif inD
        if ch == '"'
            if k < n && code(k+1) == '"'
                k = k + 2;
                continue
            end
            inD = false;
        end
    else
        switch ch
            case '''', inS = true;
            case '"',  inD = true;
            case '%',  q = k; return
        end
    end
    k = k + 1;
end
end
