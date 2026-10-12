function capture_app(target, outPath, mode)
%CAPTURE_APP Capture an open figure or uifigure to PNG.
%   mode='auto' (default) uses exportapp, which handles BOTH traditional
%   figures and uifigures on R2025a (verified: exportapp succeeds on a
%   traditional figure, and R2025a exposes an identical property set for both
%   classes, so there is no reliable class-based discriminator to branch on).
%   exportgraphics is kept as a fallback if exportapp fails, but note it
%   drops uifigure UI components.
%
%   'auto' NEVER falls back to screen capture. Raising a Visible='off' window
%   and grabbing the screen records whatever happens to be behind it instead
%   of the figure: this previously leaked the entire desktop (other
%   applications, taskbar, terminal text) into the exports folder while
%   reporting success.
%
%   mode='screen' is an explicit opt-in and is refused unless the figure is
%   actually visible, for the same reason.

if nargin < 1, target = ''; end
if nargin < 2, outPath = ''; end
if nargin < 3, mode = ''; end

target = mcp_str(target);
outPath = mcp_str(outPath);
mode = mcp_str(mode);
if isempty(mode)
    mode = 'auto';
end

figs = findall(0, 'Type', 'figure');
if isempty(figs)
    error('capture_app:noFigures', '[capture_app:noFigures] No open figures to capture');
end
if isempty(target) || strcmpi(target, 'current')
    try
        fig = get(0, 'CurrentFigure');
    if isempty(fig)
        error('capture_app:noFigure', '[capture_app:noFigure] no current figure is open; gcf would CREATE a blank one, so pass an explicit target');
    end
    catch
        fig = figs(1);
    end
elseif ~isnan(str2double(target))
    fig = findall(0, 'Type', 'figure', 'Number', str2double(target));
else
    % Name first, then Tag (UI apps are usually Tag-identified; a Tag-only app
    % previously failed capture with notFound, reproduced 2026-10-11).
    fig = findall(0, 'Type', 'figure', 'Name', target);
    if isempty(fig)
        fig = findall(0, 'Type', 'figure', 'Tag', target);
    end
end
if isempty(fig)
    error('capture_app:notFound', '[capture_app:notFound] No figure matches target: %s', target);
end
fig = fig(1);

outDir = fullfile(mcp_ext_root(), 'exports');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
if isempty(outPath)
    outPath = fullfile(outDir, sprintf('app_%s.png', ...
        char(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))));
end
outPath = char(outPath);
[opDir, ~, ~] = fileparts(outPath);
if ~isempty(opDir) && exist(opDir, 'dir') ~= 7
    mkdir(opDir);
end

switch lower(mode)
    case {'auto', 'exportapp'}
        method = 'exportapp';
    case 'exportgraphics'
        method = 'exportgraphics';
    case 'screen'
        method = 'screen';
    otherwise
        error('capture_app:badMode', ...
            'mode must be one of: auto, exportapp, exportgraphics, screen');
end
mcp_tool_log('capture_app', sprintf('target=%s mode=%s->%s out=%s', target, mode, method, outPath));

if strcmp(method, 'screen')
    if ~strcmpi(fig.Visible, 'on')
        error('capture_app:notVisible', '[capture_app:notVisible] %s', strjoin({ ...
            'mode=''screen'' refuses a non-visible figure: an on-screen grab of a', ...
            'hidden window captures whatever is behind it, not the figure. Make the', ...
            'figure Visible=''on'' first, or use mode=''auto'' (exportapp), which', ...
            'works on hidden figures.'}, ' '));
    end
    if strcmpi(fig.WindowState, 'minimized')
        error('capture_app:minimized', ...
            'mode=''screen'' cannot capture a minimized window; restore it first.');
    end
    doScreen(fig, outPath);
    return
end

ok = false;
firstErr = '';
try
    exportapp(fig, outPath);
    ok = true;
catch e
    firstErr = e.message;
end
if ~ok && strcmp(method, 'exportapp')
    try
        exportgraphics(fig, outPath);
        ok = true;
        fprintf('saved: %s (method: exportgraphics, fallback after exportapp failed: %s)\n', ...
            outPath, firstErr);
        return
    catch e2
        error('capture_app:exportFailed', ...
            'exportapp failed (%s) and exportgraphics failed (%s)', firstErr, e2.message);
    end
end
if ~ok
    error('capture_app:exportFailed', '[capture_app:exportFailed] exportgraphics failed: %s', firstErr);
end
fprintf('saved: %s (method: %s)\n', outPath, method);
end

function doScreen(fig, outPath)
% On-screen pixel grab, only for a genuinely visible window.
wasMin = false;
if strcmpi(fig.WindowState, 'minimized')
    wasMin = true;
    fig.WindowState = 'normal';
    drawnow;
    pause(0.3);
end
figure(fig);   % bring to front (this steals focus; only for explicit screen mode)
drawnow;
pause(0.5);

pos = fig.Position;
scr = get(0, 'ScreenSize');
tk = java.awt.Toolkit.getDefaultToolkit();
jd = tk.getScreenSize();
scaleX = jd.width / scr(3);
scaleY = jd.height / scr(4);
x = round(pos(1) * scaleX);
y = round(jd.height - (pos(2) + pos(4)) * scaleY);
w = round(pos(3) * scaleX);
h = round(pos(4) * scaleY);
% Clamp to the screen so a bad Position cannot silently grab the whole display.
x = max(0, min(x, jd.width - 1));
y = max(0, min(y, jd.height - 1));
w = max(1, min(w, jd.width - x));
h = max(1, min(h, jd.height - y));
rect = java.awt.Rectangle(x, y, w, h);
robot = java.awt.Robot;
img = robot.createScreenCapture(rect);
if ~javax.imageio.ImageIO.write(img, 'png', java.io.File(outPath))
    error('capture_app:writeFailed', '[capture_app:writeFailed] ImageIO.write returned false for %s', outPath);
end
if wasMin
    try
        fig.WindowState = 'minimized';
    catch
    end
end
fprintf('saved: %s (method: screen, %dx%d px, visible figure)\n', outPath, w, h);
end
