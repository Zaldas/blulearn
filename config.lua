-- config.lua
-- ImGui settings window for blulearn. Toggle with /blulearn.
-- Drawn every frame from blulearn.lua d3d_present, banner active or not.

local imgui = require('imgui');
local gdi   = require('gdifonts.include');
local uiTheme = require('libs/uiTheme');

local M    = {};
local open = { false };

local BUTTON_GAP = 6;
local WARN_COLOR = { 1.0, 0.4, 0.4, 1.0 };

local GRADIENT_LABELS = 'None\0Left to Right\0Top-Left to Bottom-Right\0Top to Bottom\0'
    .. 'Top-Right to Bottom-Left\0Right to Left\0Bottom-Right to Top-Left\0'
    .. 'Bottom to Top\0Bottom-Left to Top-Right\0\0';

-- InputText writes into a table it is handed, so the buffers must outlive the
-- frame. They are refilled from config whenever the window opens.
local buf = {
    titleText = { '' },
    titleFont = { '' },
    subText   = { '' },
    subFont   = { '' },
    soundFile = { '' },
};

local soundFound = false;
local fontMissing = { title = false, sub = false };

-- Set by text edits not yet saved; Flush saves them when the window closes or
-- the addon unloads mid-edit.
local dirty = false;

local function RefreshSoundFound(file)
    soundFound = ashita.fs.exists(string.format('%s/%s', addon.path, file));
end

function M.FontAvailable(name)
    return gdi:get_font_available(name) and true or false;
end

-- Font edits stay in the buffer until committed, so config always names the
-- font that is drawn.
local function CommitFont(tbl, fontBuf, id)
    fontMissing[id] = not M.FontAvailable(fontBuf[1]);
    if tbl.fontFamily == fontBuf[1] then
        return false;
    end
    tbl.fontFamily = fontBuf[1];
    return true;
end

-- LuaJIT bit ops return signed 32-bit results (bit.lshift(255, 24) is negative),
-- so the alpha byte is packed with arithmetic.
local function ArgbToFloats(argb)
    return {
        (math.floor(argb / 0x10000) % 0x100) / 255,
        (math.floor(argb / 0x100) % 0x100) / 255,
        (argb % 0x100) / 255,
        (math.floor(argb / 0x1000000) % 0x100) / 255,
    };
end

local function FloatsToArgb(c)
    local r = math.floor(c[1] * 255 + 0.5);
    local g = math.floor(c[2] * 255 + 0.5);
    local b = math.floor(c[3] * 255 + 0.5);
    local a = math.floor(c[4] * 255 + 0.5);
    return (a * 0x1000000) + (r * 0x10000) + (g * 0x100) + b;
end

local function HasFlag(value, flag)
    return (math.floor(value / flag) % 2) == 1;
end

local function SetFlag(value, flag, enabled)
    local has = HasFlag(value, flag);
    if enabled and not has then
        return value + flag;
    elseif (not enabled) and has then
        return value - flag;
    end
    return value;
end


local function AvailWidth()
    local avail = imgui.GetContentRegionAvail();
    if type(avail) == 'table' then
        return avail[1];
    end
    return avail;
end


local function SliderIntSaved(label, tbl, key, min, max, format, cb, apply)
    local ref = { tbl[key] };
    if imgui.SliderInt(label, ref, min, max, format) then
        tbl[key] = ref[1];
        if apply then cb.fonts(); end
    end
    if imgui.IsItemDeactivatedAfterEdit() then
        cb.save();
    end
end

local function ColorRow(label, tbl, key, cb)
    local col = ArgbToFloats(tbl[key]);
    if imgui.ColorEdit4(label, col, bit.bor(ImGuiColorEditFlags_AlphaBar, ImGuiColorEditFlags_NoInputs)) then
        tbl[key] = FloatsToArgb(col);
        cb.fonts();
    end
    if imgui.IsItemDeactivatedAfterEdit() then
        cb.save();
    end
end


local function TextTab(id, tbl, textBuf, fontBuf, cb, hint)
    uiTheme.header('Text', hint);
    imgui.Indent(uiTheme.indent);

        if imgui.InputText('Content##' .. id, textBuf, 256) then
            tbl.text = textBuf[1];
            cb.text();
            dirty = true;
        end
        if imgui.IsItemDeactivatedAfterEdit() then
            cb.save();
            dirty = false;
        end

        if imgui.InputText('Font##' .. id, fontBuf, 128) then
            dirty = true;
        end
        if imgui.IsItemDeactivatedAfterEdit() then
            CommitFont(tbl, fontBuf, id);
            cb.fonts();
            cb.save();
            dirty = false;
        end
        if fontMissing[id] then
            imgui.SameLine();
            imgui.TextColored(WARN_COLOR, 'not installed');
        end

        SliderIntSaved('Size##' .. id, tbl, 'fontHeight', 8, 160, '%d px', cb, true);

        local bold = { HasFlag(tbl.fontFlags, gdi.FontFlags.Bold) };
        if imgui.Checkbox('Bold##' .. id, bold) then
            tbl.fontFlags = SetFlag(tbl.fontFlags, gdi.FontFlags.Bold, bold[1]);
            cb.fonts();
            cb.save();
        end
        uiTheme.helpMarker('Draw this text in bold.');
        imgui.SameLine();
        local italic = { HasFlag(tbl.fontFlags, gdi.FontFlags.Italic) };
        if imgui.Checkbox('Italic##' .. id, italic) then
            tbl.fontFlags = SetFlag(tbl.fontFlags, gdi.FontFlags.Italic, italic[1]);
            cb.fonts();
            cb.save();
        end
        uiTheme.helpMarker('Draw this text in italics.');

    imgui.Unindent(uiTheme.indent);
    imgui.Spacing();

    uiTheme.header('Colours', 'Fill fades into the gradient colour along the fade direction.');
    imgui.Indent(uiTheme.indent);

        ColorRow('Fill##' .. id, tbl, 'fontColor', cb);
        ColorRow('Gradient##' .. id, tbl, 'gradientColor', cb);

        local style = { tbl.gradientStyle };
        imgui.SetNextItemWidth(uiTheme.comboWidth());
        if imgui.Combo('Fade##' .. id, style, GRADIENT_LABELS) then
            tbl.gradientStyle = style[1];
            cb.fonts();
            cb.save();
        end

        ColorRow('Outline##' .. id, tbl, 'outlineColor', cb);
        SliderIntSaved('Outline width##' .. id, tbl, 'outlineWidth', 0, 12, '%d px', cb, true);

    imgui.Unindent(uiTheme.indent);
    imgui.Spacing();

    uiTheme.header('Placement', 'Vertical offset from the banner centre.');
    imgui.Indent(uiTheme.indent);
        SliderIntSaved('Y offset##' .. id, tbl, 'offsetY', -200, 200, '%d px', cb, false);
    imgui.Unindent(uiTheme.indent);
    imgui.Spacing();
end

local function GeneralTab(config, cb)
    uiTheme.header('Position', 'Where the banner sits vertically.\n0 is the top of the screen, 100 the bottom.');
    imgui.Indent(uiTheme.indent);

        local posY = { config.screenPosY };
        if imgui.SliderFloat('Screen Y', posY, 0.0, 100.0, '%.1f%%') then
            config.screenPosY = posY[1];
        end
        if imgui.IsItemDeactivatedAfterEdit() then
            cb.save();
        end

    imgui.Unindent(uiTheme.indent);
    imgui.Spacing();

    uiTheme.header('Sound', 'Played once when a spell is learned.\nThe file must sit in the blulearn folder.');
    imgui.Indent(uiTheme.indent);

        local enabled = { config.soundEnabled };
        if imgui.Checkbox('Play a sound', enabled) then
            config.soundEnabled = enabled[1];
            cb.save();
        end
        uiTheme.helpMarker('Mute the banner without clearing the filename.');

        if imgui.InputText('File##sound', buf.soundFile, 128) then
            config.soundFile = buf.soundFile[1];
            RefreshSoundFound(config.soundFile);
            dirty = true;
        end
        if imgui.IsItemDeactivatedAfterEdit() then
            cb.save();
            dirty = false;
        end
        if not soundFound then
            imgui.SameLine();
            imgui.TextColored(WARN_COLOR, 'not found');
        end

    imgui.Unindent(uiTheme.indent);
    imgui.Spacing();
    imgui.Separator();
    imgui.Spacing();

    if uiTheme.centeredButton('Reload settings file', 'primary') then
        cb.reload();
    end
    if imgui.IsItemHovered() then
        uiTheme.tooltipBegin();
        imgui.TextUnformatted('Re-read settings.lua from disk. Use after editing\nthe values this window does not expose.');
        uiTheme.tooltipEnd();
    end

    imgui.Spacing();

    if uiTheme.centeredButton('Reset to defaults', 'ghost') then
        cb.reset();
        M.SyncBuffers(config);
    end
end


function M.SyncBuffers(config)
    buf.titleText[1] = config.title.text;
    buf.titleFont[1] = config.title.fontFamily;
    buf.subText[1]   = config.subtitle.text;
    buf.subFont[1]   = config.subtitle.fontFamily;
    buf.soundFile[1] = config.soundFile;
    RefreshSoundFound(config.soundFile);
    fontMissing.title = not M.FontAvailable(config.title.fontFamily);
    fontMissing.sub   = not M.FontAvailable(config.subtitle.fontFamily);
    dirty = false;
end

-- Saves text edits still in progress, committing any pending font change.
function M.Flush(config, cb)
    if not dirty then
        return;
    end
    local titleChanged = CommitFont(config.title, buf.titleFont, 'title');
    local subChanged   = CommitFont(config.subtitle, buf.subFont, 'sub');
    if titleChanged or subChanged then
        cb.fonts();
    end
    cb.save();
    dirty = false;
end

function M.Toggle(config)
    open[1] = not open[1];
    if open[1] then
        M.SyncBuffers(config);
    end
    return open[1];
end

--[[
* Draws the window. Safe to call every frame whether or not the banner is up.
*
* @param {table} config - the live settings table
* @param {table} cb - { save, fonts, text, test, hold, holding, reload, reset, close }
--]]
function M.Draw(config, cb)
    if not open[1] then
        return;
    end

    local function drawBody()
        -- Pins the content width. Without it, auto-resize would size to whichever
        -- tab is widest and the window would jump on every tab switch.
        imgui.Dummy({ 370, 1 });

        local availW = AvailWidth();
        local rowW   = math.floor(availW * 0.80);
        local btnW   = math.floor((rowW - BUTTON_GAP) * 0.5);
        local pad    = math.floor((availW - rowW) * 0.5);

        imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
        if uiTheme.button('Play', btnW, 'primary') then
            cb.test();
            RefreshSoundFound(config.soundFile);
        end
        imgui.SameLine(0, BUTTON_GAP);
        if uiTheme.button('Hold', btnW, cb.holding() and 'active' or 'ghost') then
            cb.hold();
        end
        if imgui.IsItemHovered() then
            uiTheme.tooltipBegin();
            imgui.TextUnformatted('Freeze the banner in its final position\nso you can adjust it live.');
            uiTheme.tooltipEnd();
        end

        imgui.Spacing();

        if imgui.BeginTabBar('##blulearn_tabs', ImGuiTabBarFlags_NoCloseWithMiddleMouseButton) then
            if imgui.BeginTabItem('General') then
                imgui.Spacing();
                GeneralTab(config, cb);
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Heading') then
                imgui.Spacing();
                TextTab('title', config.title, buf.titleText, buf.titleFont, cb, nil);
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Spell name') then
                imgui.Spacing();
                TextTab('sub', config.subtitle, buf.subText, buf.subFont, cb,
                    '${spell} is replaced with the learned spell,\n${player} with your name.');
                imgui.EndTabItem();
            end

            imgui.EndTabBar();
        end
    end

    local n = uiTheme.push();
    local ok, err = true, nil;
    -- No NoSavedSettings flag: imgui.ini persists the position under the ###id,
    -- which is independent of the version in the title.
    -- AlwaysAutoResize fits the height to the active tab and drops the resize
    -- grip; the window is still draggable by its title bar.
    if imgui.Begin(('blulearn.%s###blulearnConfig'):format(addon.version), open, ImGuiWindowFlags_AlwaysAutoResize) then
        ok, err = pcall(drawBody);
    end
    imgui.End();
    uiTheme.pop(n);

    -- Closing via the X leaves a held banner stuck on screen otherwise.
    if not open[1] then
        M.Flush(config, cb);
        cb.close();
    end
    if not ok then error(err, 0); end
end

return M;
