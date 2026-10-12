function capture_figure(target, outPath)
%CAPTURE_FIGURE Save a MATLAB figure to PNG and print the absolute path.
%   target: 'current' for gcf, or a figure number (e.g. '1'), or a figure
%           Name property string. Errors if no figure is open (never
%           creates one as a side effect).
%   outPath: destination PNG path; '' -> default under extensions\exports.
if nargin < 1, target = 'current'; end
if nargin < 2, outPath = ''; end
figs = findall(0, 'Type', 'figure');
if isempty(figs)
    error('capture_figure:noFigures', '[capture_figure:noFigures] No open figures to capture');
end
target = mcp_str(target); % MCP arg normalization, see mcp_str
if isempty(target) || strcmpi(target, 'current')
    fig = get(0, 'CurrentFigure');
    if isempty(fig)
        error('capture_figure:noFigure', '[capture_figure:noFigure] no current figure is open; gcf would CREATE a blank one, so pass an explicit target');
    end
elseif ~isnan(str2double(target)) && ~isempty(target)
    fig = findall(0, 'Type', 'figure', 'Number', str2double(target));
elseif ischar(target) || isstring(target)
    % Match Name first, then Tag: UI apps are conventionally identified by Tag
    % (findobj(0,'Tag','whsAppFig')) while plain figures carry a Name. The
    % Tag-only case previously failed with notFound even though the window was
    % open (reproduced 2026-10-11 with a Tag-only probe figure).
    fig = findall(0, 'Type', 'figure', 'Name', char(target));
    if isempty(fig)
        fig = findall(0, 'Type', 'figure', 'Tag', char(target));
    end
else
    error('capture_figure:badTarget', '[capture_figure:badTarget] target must be ''current'', a figure number, or a figure name');
end
if isempty(fig)
    error('capture_figure:notFound', '[capture_figure:notFound] No figure matches target: %s', char(target));
end
fig = fig(1);
outPath = mcp_str(outPath);
if isempty(outPath)
    outDir = fullfile(mcp_ext_root(), 'exports');
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    outPath = fullfile(outDir, sprintf('fig_%s.png', ...
        char(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))));
end
outPath = char(outPath);
mcp_tool_log('capture_figure', sprintf('target=%s out=%s', target, outPath));
[opDir, ~, ~] = fileparts(outPath);
if ~isempty(opDir) && exist(opDir, 'dir') ~= 7
    mkdir(opDir);
end
exportgraphics(fig, outPath, 'Resolution', 150);
fprintf('saved: %s\n', outPath);
end
