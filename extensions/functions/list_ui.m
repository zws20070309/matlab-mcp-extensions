function list_ui(target, verbose)
%LIST_UI Inventory the UI component tree of an open figure.
%   R2025a findall Type strings do not match the documented ones in all
%   cases (e.g. state buttons report Type='uistatebutton', not 'uibutton';
%   numeric edit fields may be invisible to findall by Type), so this tool
%   walks every object and groups by class instead of by Type. Only
%   matlab.ui.* components are listed line by line; graphics scene objects
%   (patches, lines, ...) are summarized by class so a dense 3D scene does
%   not flood the output. verbose=true lists every object class, including
%   graphics primitives.

if nargin < 1, target = 'current'; end
if nargin < 2, verbose = ''; end
target = mcp_str(target);
verbose = parseVerbose(verbose);

figs = findall(0, 'Type', 'figure');
if isempty(figs)
    error('list_ui:noFigures', '[list_ui:noFigures] No open figures to inspect');
end
if isempty(target) || strcmpi(target, 'current')
    % Documented contract: "empty lists all". An empty target first prints an
    % index of every open figure, then details the current one. Without this
    % the empty string fell through to the Name match below and died with
    % [list_ui:notFound] even though figures were open (reproduced 2026-10-11:
    % 1 visible figure, list_ui('') errored while capture_figure worked).
    if isempty(target) && numel(figs) > 1
        fprintf('%d open figures:\n', numel(figs));
        for kk = 1:numel(figs)
            nm = '';
            try, nm = figs(kk).Name; catch, end
            fprintf('  [%s] "%s" (%s)\n', mat2str(figs(kk).Number), char(nm), class(figs(kk)));
        end
    end
    try
        fig = gcf;
    catch
        fig = figs(1);
    end
elseif ~isnan(str2double(target)) && ~isempty(target)
    fig = findall(0, 'Type', 'figure', 'Number', str2double(target));
elseif ischar(target) || isstring(target)
    % Name first, then Tag: UI apps are conventionally located by Tag and a
    % Tag-only window used to fail here with notFound (reproduced 2026-10-11).
    fig = findall(0, 'Type', 'figure', 'Name', char(target));
    if isempty(fig)
        fig = findall(0, 'Type', 'figure', 'Tag', char(target));
    end
else
    error('list_ui:badTarget', '[list_ui:badTarget] target must be ''current'', a figure number, or a figure name');
end
if isempty(fig)
    error('list_ui:notFound', '[list_ui:notFound] No figure matches target: %s', char(target));
end
fig = fig(1);

allObjs = findall(fig);
mcp_tool_log('list_ui', sprintf('target=%s verbose=%s fig=%s', target, ...
    mat2str(verbose), char(fig.Name)));
allClasses = string(arrayfun(@(o) class(o), allObjs, 'UniformOutput', false));
uiMask = startsWith(allClasses, 'matlab.ui');
uiObjs = allObjs(uiMask);
otherObjs = allObjs(~uiMask);
otherClasses = allClasses(~uiMask);

figName = '';
try
    figName = fig.Name;
catch
end
fprintf('figure "%s" (%s): %d objects total, %d UI components\n', ...
    char(figName), class(fig), numel(allObjs), numel(uiObjs));

% `verbose` used to be inert here: both branches of this if/else printed the
% same line (caught by checkcode). It now genuinely widens the listing.
if verbose
    fprintf('%d UI components (verbose: no line cap):\n', numel(uiObjs));
    maxLines = Inf;
else
    fprintf('%d UI components:\n', numel(uiObjs));
    maxLines = 80;
end
for k = 1:numel(uiObjs)
    if k > maxLines
        fprintf('  ... %d more UI components omitted\n', numel(uiObjs)-maxLines);
        break
    end
    fprintf('  %s\n', describeUiComponent(uiObjs(k)));
end

if ~isempty(otherObjs)
    [uniq, ~, idx] = unique(otherClasses);
    counts = accumarray(idx, 1);
    fprintf('non-UI objects (%d total):\n', numel(otherObjs));
    if verbose
        % list every object, not just the per-class tally
        for k = 1:numel(otherObjs)
            if k > 400
                fprintf('  ... %d more objects omitted\n', numel(otherObjs)-k+1);
                break
            end
            fprintf('  %s\n', class(otherObjs(k)));
        end
    else
        for k = 1:numel(uniq)
            fprintf('  %-55s x%d\n', uniq(k), counts(k));
        end
    end
end
end

function doVerbose = parseVerbose(v)
if isnumeric(v) || islogical(v)
    doVerbose = ~isempty(v) && v(1) ~= 0;
    return
end
s = '';
try
    s = lower(mcp_str(v));
catch
end
doVerbose = any(strcmp(s, {'true', '1', 'on', 'yes', 'all'}));
end

function line = describeUiComponent(obj)
txt = '';
try
    if isprop(obj, 'Text') && (ischar(obj.Text) || isstring(obj.Text))
        txt = char(string(obj.Text));
    end
catch
end
try
    if isempty(txt) && isprop(obj, 'Title')
        t = obj.Title;
        if ischar(t) || isstring(t)
            txt = char(string(t));
        elseif isprop(t, 'String')
            txt = char(string(t.String));
        end
    end
catch
end
try
    if isempty(txt) && isprop(obj, 'Name') && (ischar(obj.Name) || isstring(obj.Name))
        txt = char(string(obj.Name));
    end
catch
end
extra = '';
try
    if isprop(obj, 'Value')
        extra = sprintf(' Value=%s', valueToString(obj.Value));
    end
catch
end
try
    if isprop(obj, 'Limits')
        extra = [extra sprintf(' Limits=[%s]', num2str(obj.Limits(:).'))];
    end
catch
end
try
    if isprop(obj, 'Items') && ~isempty(obj.Items)
        extra = [extra sprintf(' Items={%s}', strjoin(cellstr(string(obj.Items(1:min(4,end)))), ','))];
    end
catch
end
try
    if isprop(obj, 'Running')
        extra = [extra sprintf(' Running=%s', obj.Running)];
    end
catch
end
if isempty(txt) && isempty(extra)
    line = sprintf('%s (%s)', class(obj), objType(obj));
else
    line = sprintf('%s (%s) "%s"%s', class(obj), objType(obj), txt, extra);
end
end

function t = objType(obj)
t = '';
try
    t = char(obj.Type);
catch
    t = '?';
end
end

function s = valueToString(v)
if islogical(v)
    if isscalar(v)
        s = string(v);
    else
        s = sprintf('%dx%d logical', size(v, 1), size(v, 2));
    end
elseif isnumeric(v)
    if isscalar(v)
        s = sprintf('%.4g', v);
    else
        s = sprintf('%dx%d %s', size(v, 1), size(v, 2), class(v));
    end
elseif ischar(v) || isstring(v)
    s = string(v);
else
    s = string(class(v));
end
end
