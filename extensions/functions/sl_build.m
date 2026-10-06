function sl_build(modelPath, specJson, optsJson)
%SL_BUILD Create a Simulink model from a JSON spec - no hand-written add_block.
%   modelPath : absolute .slx path to create or overwrite.
%   specJson  : {"model":"name" (optional, defaults to the file name),
%                "blocks":[{"id":"SRC","lib":"simulink/Sources/From Workspace",
%                          "type":"FromWorkspace",           <- alternative to lib
%                          "pos":[60 60 140 100],             <- optional
%                          "params":{"VariableName":"uet"}}],
%                "lines":[["SRC/1","CPA/1"],["CPA/1","LOG/1"]],
%                "modelParams":{"SolverType":"Fixed-step","Solver":"FixedStepDiscrete",
%                               "FixedStep":"2e-7","StopTime":"60e-6",
%                               "ReturnWorkspaceOutputs":"on","SaveOutput":"on"}}
%   optsJson  : {"overwrite":true, "check":true, "verbose":true}
%
%   WHY: building a model programmically previously meant hand-writing
%   new_system/add_block/add_line/set_param, and the two traps found while
%   measuring them are handled here: (1) the Simulink library is unsearchable
%   until load_system("simulink") has run - before that find_system reports 0
%   blocks and add_block of an empty path fails with the misleading
%   Simulink:Commands:InvSimulinkObjHandle "Simulink 对象句柄无效"; (2) block
%   paths must be the real library paths, e.g. "simulink/Sinks/To Workspace"
%   works while "simulink/Commonly Used Blocks/To Workspace" does not. So a
%   block may be given by "type" instead and is resolved by find_system.
%   Prints only; returns nothing.
if nargin < 3, optsJson = ''; end
modelPath = mcp_str(modelPath);
specJson = mcp_str(specJson);
if isempty(modelPath)
    error('sl_build:badArgs', '[sl_build:badArgs] modelPath is required (absolute .slx path)');
end
if isempty(specJson)
    error('sl_build:badArgs', '[sl_build:badArgs] specJson is required');
end
try
    spec = jsondecode(specJson);
catch e
    error('sl_build:badSpec', '[sl_build:badSpec] specJson must decode to an object: %s', e.message);
end
if ~isstruct(spec)
    error('sl_build:badSpec', '[sl_build:badSpec] specJson must be a JSON object');
end
mcp_tool_log('sl_build', sprintf('%s blocks=%d', modelPath, ...
    numel(getfielddef(spec, 'blocks', []))));
prevW = warning('off', 'all');
rest = onCleanup(@() warning(prevW)); %#ok<NASGU>
[fp, fn, ext] = fileparts(modelPath);
if ~strcmpi(ext, '.slx')
    error('sl_build:badExt', '[sl_build:badExt] modelPath must end in .slx, got %s', ext);
end
if ~isempty(fp) && ~exist(fp, 'dir')
    mkdir(fp);
end
mdl = fn;
if isfield(spec, 'model')
    mdl = char(string(spec.model));
end
try
    close_system(mdl, 0);
catch
end
load_system('simulink');
new_system(mdl);
if ~strcmp(mdl, fn)
    warning('sl_build:nameMismatch', ...
        'spec.model "%s" differs from the file name "%s"; the model is named after spec.model', mdl, fn);
end
fprintf('model: %s (new)\n', mdl);
nb = 0;
badb = {};
if isfield(spec, 'blocks')
    bl = spec.blocks;
    if ~iscell(bl)
        bl = num2cell(bl);
    end
    for k = 1:numel(bl)
        b = bl{k};
        id = '';
        if isfield(b, 'id'), id = char(string(b.id)); end
        if isempty(id)
            badb{end+1} = sprintf('#%d no id', k); %#ok<AGROW>
            continue
        end
        src = '';
        if isfield(b, 'lib')
            src = char(string(b.lib));
        elseif isfield(b, 'type')
            src = resolveType(char(string(b.type)));
        else
            badb{end+1} = sprintf('%s: needs "lib" or "type"', id); %#ok<AGROW>
            continue
        end
        if isempty(src)
            badb{end+1} = sprintf('%s: block source unresolved', id); %#ok<AGROW>
            continue
        end
        dst = [mdl '/' id];
        try
            if isfield(b, 'pos')
                p = b.pos;
                add_block(src, dst, 'Position', round(double(p(:))'));
            else
                add_block(src, dst, 'Position', [60 + 120*k 60 140 + 120*k 100]);
            end
        catch e
            badb{end+1} = sprintf('%s: add_block(%s) -> %s', id, src, strtrim(replace(e.message, newline, ' '))); %#ok<AGROW>
            continue
        end
        nb = nb + 1;
        % find_system hands back these library paths with an embedded newline
        % where the block name has a space ("simulink/Sources/From\nWorkspace").
        % Simulink accepts it, but printing it raw makes the path look broken to
        % whoever reads the tool output and tries to reuse it, so flatten it.
        fprintf('  block %-10s <- %s\n', id, strtrim(strrep(src, newline, ' ')));
        if isfield(b, 'params') && ~isempty(b.params)
            pf = fieldnames(b.params);
            for j = 1:numel(pf)
                val = b.params.(pf{j});
                if isnumeric(val) || islogical(val)
                    vs = mat2str(val);
                elseif iscell(val)
                    vs = char(string(val{1}));
                else
                    vs = char(string(val));
                end
                try
                    set_param(dst, pf{j}, vs);
                catch e
                    badb{end+1} = sprintf('%s: set %s=%s -> %s', id, pf{j}, vs, ...
                        strtrim(replace(e.message, newline, ' '))); %#ok<AGROW>
                end
            end
        end
    end
end
fprintf('blocks added: %d\n', nb);
nl = 0;
if isfield(spec, 'lines')
    ls = spec.lines;
    if ~iscell(ls)
        ls = num2cell(ls);
    end
    for k = 1:numel(ls)
        l = ls{k};
        if ~iscell(l) || numel(l) < 2
            badb{end+1} = sprintf('line #%d needs [src dst]', k); %#ok<AGROW>
            continue
        end
        try
            add_line(mdl, char(string(l{1})), char(string(l{2})), 'autorouting', 'on');
            nl = nl + 1;
        catch e
            badb{end+1} = sprintf('line %s->%s: %s', char(string(l{1})), char(string(l{2})), ...
                strtrim(replace(e.message, newline, ' '))); %#ok<AGROW>
        end
    end
end
fprintf('lines connected: %d\n', nl);
if isfield(spec, 'modelParams')
    mf = fieldnames(spec.modelParams);
    for k = 1:numel(mf)
        v = spec.modelParams.(mf{k});
        if isnumeric(v) || islogical(v)
            vs = mat2str(v);
        else
            vs = char(string(v));
        end
        try
            set_param(mdl, mf{k}, vs);
        catch e
            badb{end+1} = sprintf('model %s=%s -> %s', mf{k}, vs, strtrim(replace(e.message, newline, ' '))); %#ok<AGROW>
        end
    end
    fprintf('model parameters set: %d\n', numel(mf));
end
if numel(badb) > 0
    fprintf('PROBLEMS (%d):\n', numel(badb));
    for k = 1:min(15, numel(badb))
        fprintf('  %s\n', badb{k});
    end
end
ok = true;
try
    save_system(mdl, modelPath);
catch e
    ok = false;
    fprintf('SAVE_FAIL %s :: %s\n', e.identifier, e.message);
end
rest = [];
warning(prevW);
if ok
    d = dir(modelPath);
    fprintf('saved: %s (%d bytes)\n', modelPath, d.bytes);
end
if numel(badb) == 0 && ok
    fprintf('VERDICT: built clean - next call sl_sim("%s", ...)\n', modelPath);
else
    fprintf('VERDICT: built with %d issue(s); fix the spec and rerun\n', numel(badb));
end
end

function src = resolveType(bt)
%RESOLVETYPE Find the real library path for a BlockType.
p = find_system('simulink', 'SearchDepth', 4, 'BlockType', bt);
lib = p(startsWith(p, 'simulink/'));
if isempty(lib)
    src = '';
else
    src = lib{1};
end
end

function v = getfielddef(s, f, d)
v = d;
if isstruct(s) && isfield(s, f)
    v = s.(f);
end
end
