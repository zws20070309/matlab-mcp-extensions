function resolve_capability(namesJson, showTable)
%RESOLVE_CAPABILITY Tell me which product a function belongs to and whether it exists.
%   namesJson: JSON array of names, e.g. '["lhsdesign","pwelch","H5S.set_extent_simple","sim"]'
%              '' = print the product/license table only.
%   showTable: '1' also prints the full installed-product list with license state.
%
%   WHY (all measured here): a missing toolbox does not announce itself. Calling
%   lhsdesign throws MATLAB:UndefinedFunction with no mention of Statistics and
%   Machine Learning Toolbox, and exist() is actively misleading for package
%   namespaces - exist('H5F')=0 while the low-level HDF5 package really is
%   installed. This tool therefore resolves with which() (which understands +pkg)
%   and attributes the hit to an installed product by matching ver().Folder.
%   Prints only; returns nothing.
if nargin < 2, showTable = ''; end
namesJson = mcp_str(namesJson);
mcp_tool_log('resolve_capability', namesJson);
V = ver;
folders = cell(numel(V), 1);
names = cell(numel(V), 1);
vers = cell(numel(V), 1);
mr = strrep(matlabroot, '\', '/');
for k = 1:numel(V)
    try
        fk = strrep(char(string(V(k).Folder)), '\', '/');
        % ver().Folder is not always an absolute path; when it is relative it is
        % relative to matlabroot, and a prefix match against which()'s absolute
        % path silently fails unless this is normalised first.
        if isempty(regexp(fk, '^[A-Za-z]:', 'once'))
            fk = [mr '/' fk];
        end
        folders{k} = fk;
    catch
        folders{k} = '';
    end
    try
        names{k} = char(string(V(k).Name));
    catch
        names{k} = '?';
    end
    try
        vers{k} = char(string(V(k).Version));
    catch
        vers{k} = '?';
    end
end
fprintf('installed products: %d\n', numel(V));
guess = aliasMap();
if ~isempty(strtrim(namesJson))
    try
        arr = jsondecode(namesJson);
    catch e
        error('resolve_capability:badJson', '[resolve_capability:badJson] %s', e.message);
    end
    if ischar(arr) || isstring(arr)
        arr = cellstr(string(arr));
    elseif ~iscell(arr)
        arr = cellstr(string(arr(:)));
    end
    dirNotePrinted = false;
    for k = 1:numel(arr)
        nm = strtrim(char(string(arr{k})));
        if isempty(nm)
            continue
        end
        w = '';
        try
            w = strrep(which(nm), '\', '/');
        catch
        end
        % which() reports built-ins as "built-in (<MATLABROOT>/toolbox/...)" - that
        % wrapper has to come off before a path prefix can be matched.
        tok = regexp(w, '^built-in \((.*)\)$', 'tokens', 'once');
        if ~isempty(tok)
            w = char(tok{1});
        end
        owner = '-';
        if ~isempty(w)
            bl = -1;
            for j = 1:numel(folders)
                if ~isempty(folders{j}) && numel(w) >= numel(folders{j}) && ...
                        strcmpi(w(1:numel(folders{j})), folders{j}) && numel(folders{j}) > bl
                    bl = numel(folders{j});
                    owner = sprintf('%s (v%s)', names{j}, vers{j});
                end
            end
            if bl < 0
                seg = '?';
                pp = strsplit(w, '/');
                for q = 1:numel(pp) - 1
                    if any(strcmp(pp{q}, {'toolbox', 'extern', 'sys'}))
                        seg = pp{q + 1};
                        break
                    end
                end
                % WHY the fallback is the answer, not a degradation: ver() on
                % R2025a exposes no Folder field (verified - referencing it
                % throws "无法识别的字段名称 Folder"), so no product->folder table is
                % available from it. The toolbox directory segment is the
                % defensible attribution and is labelled as such.
                if ~strcmp(seg, '?')
                    owner = sprintf('provided by toolbox directory "%s"', seg);
                elseif exist(w, 'file') == 2
                    % seg=='?' only means the path has no toolbox/extern/sys segment - a project or
                    % user folder. Calling that "built-in" contradicted the path line printed below it.
                    owner = sprintf('provided by a folder outside any toolbox (%s)', fileparts(w));
                else
                    owner = 'built-in (no .m file on the path to attribute)';
                end
                % The caveat belongs to the release, not to each name, so it is printed once per
                % call instead of once per resolved function (7 copies of an 86-char sentence
                % were measured on a single 8-name query).
                if ~dirNotePrinted
                    fprintf('%-28s   note: ver() exposes no Folder field on this release, so attribution below', '');
                    fprintf(newline);
                    fprintf('%-28s   is by toolbox DIRECTORY, not product name', '');
                    fprintf(newline);
                    dirNotePrinted = true;
                end
            end
            fprintf('%-28s AVAILABLE   %s\n', nm, owner);
            fprintf('%-28s   path: %s\n', '', w);
        else
            g = '';
            if isKey(guess, nm)
                g = sget(guess, nm);
            end
            if isempty(g)
                fprintf('%-28s MISSING     no owning product on this machine (not on any path)\n', nm);
            else
                inst = any(strcmp(names, g));
                lic = NaN;
                keys = licenseKeys();
                if isKey(keys, g)
                    lic = license('test', sget(keys, g));
                end
                fprintf('%-28s MISSING     needs product: "%s" installed=%d licensed=%s\n', ...
                    nm, g, inst, num2s(lic));
                if ~inst && isfinite(lic) && lic > 0
                    fprintf('%-28s   -> your license ALREADY covers it; only the product files are missing\n', '');
                end
            end
        end
    end
end
if any(strcmp(mcp_str(showTable), {'1', 'true', 'yes', 'on'}))
    fprintf('--- product / license table (only products with a known license key) ---\n');
    % Iterate the ORIGINAL product names, not fieldnames(licenseKeys()): those are
    % sanitised by mat2labname (spaces -> '_'), so comparing them against ver().Name
    % would silently report installed=0 for every product.
    pairs = licensePairs();
    for k = 1:size(pairs, 1)
        pn = pairs{k, 1};
        fprintf('  %-42s installed=%d license_test=%d\n', pn, ...
            any(strcmp(names, pn)), license('test', pairs{k, 2}));
    end
    fprintf('--- all installed products ---\n');
    for k = 1:numel(names)
        fprintf('  %-46s %s\n', names{k}, vers{k});
    end
end
end

function m = aliasMap()
m = struct();
a = {'lhsdesign','Statistics and Machine Learning Toolbox'; ...
     'random','Statistics and Machine Learning Toolbox'; ...
     'poissrnd','Statistics and Machine Learning Toolbox'; ...
     'datasample','Statistics and Machine Learning Toolbox'; ...
     'bootstrp','Statistics and Machine Learning Toolbox'; ...
     'bootstrap','Statistics and Machine Learning Toolbox'; ...
     'corr','Statistics and Machine Learning Toolbox'; ...
     'fitlm','Statistics and Machine Learning Toolbox'; ...
     'fitglm','Statistics and Machine Learning Toolbox'; ...
     'fitnlm','Statistics and Machine Learning Toolbox'; ...
     'fitdist','Statistics and Machine Learning Toolbox'; ...
     'mvnrnd','Statistics and Machine Learning Toolbox'; ...
     'kmeans','Statistics and Machine Learning Toolbox'; ...
     'pca','Statistics and Machine Learning Toolbox'; ...
     'cvpartition','Statistics and Machine Learning Toolbox'; ...
     'gmdistribution','Statistics and Machine Learning Toolbox'; ...
     'copulafit','Statistics and Machine Learning Toolbox'; ...
     'fit','Curve Fitting Toolbox'; ...
     'pwelch','Signal Processing Toolbox'; ...
     'periodogram','Signal Processing Toolbox'; ...
     'tf','Control System Toolbox'; ...
     'lsqnonlin','Optimization Toolbox'; ...
     'fmincon','Optimization Toolbox'; ...
     'gpuArray','Parallel Computing Toolbox'; ...
     'parpool','Parallel Computing Toolbox'; ...
     'createpde','Partial Differential Equation Toolbox'; ...
     'syms','Symbolic Math Toolbox'; ...
     'mlreportgen.dom.Document','MATLAB Report Generator'; ...
     'Simulink.sdi','Simulink'};
for k = 1:size(a, 1)
    m.(mat2labname(a{k, 1})) = a{k, 2};
end
end

function p = licensePairs()
% Single source of truth: {product name as ver() reports it, license feature key}.
% licenseKeys() and the product/license table both read this, so they cannot drift.
p = {'Statistics and Machine Learning Toolbox','Statistics_Toolbox'; ...
     'Signal Processing Toolbox','Signal_Toolbox'; ...
     'Curve Fitting Toolbox','CurveFitting_Toolbox'; ...
     'Optimization Toolbox','Optimization_Toolbox'; ...
     'Control System Toolbox','Control_Toolbox'; ...
     'Parallel Computing Toolbox','Distrib_Computing_Toolbox'; ...
     'Simulink','Simulink'; ...
     'Symbolic Math Toolbox','Symbolic_Toolbox'; ...
     'Partial Differential Equation Toolbox','PDE_Toolbox'};
end

function m = licenseKeys()
m = struct();
p = licensePairs();
for k = 1:size(p, 1)
    m.(mat2labname(p{k, 1})) = p{k, 2};
end
end

function s = mat2labname(nm)
s = regexprep(nm, '[^A-Za-z0-9]', '_');
if isempty(regexp(s, '^[A-Za-z]', 'once'))
    s = ['x' s];
end
end

function tf = isKey(s, nm)
tf = isfield(s, mat2labname(nm));
end

function v = sget(s, nm)
v = s.(mat2labname(nm));
end

function out = num2s(v)
if isempty(v) || (isnumeric(v) && ~isfinite(v))
    out = 'n/a';
else
    out = sprintf('%g', v);
end
end
