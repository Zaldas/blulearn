-- config.lua
-- ImGui settings window for blulearn. Toggle with /blulearn.
-- Drawn every frame from blulearn.lua d3d_present, banner active or not.

local imgui = require('imgui');
local gdi   = require('gdifonts.include');

local M    = {};
local open = { false };

local INDENT     = 8;
local BUTTON_GAP = 6;

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

-- Built with arithmetic rather than bit ops: bit.lshift(255, 24) is negative in
-- LuaJIT, which would round-trip colours to garbage.
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


-- primary -> solid blue, active -> amber (toggle is on), neither -> ghost.
local function StyledButton(label, size, primary, active)
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 6.0);

    if active then
        imgui.PushStyleColor(ImGuiCol_Button,        { 0.70, 0.45, 0.05, 1.00 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.80, 0.55, 0.10, 1.00 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 0.55, 0.35, 0.03, 1.00 });
    elseif primary then
        imgui.PushStyleColor(ImGuiCol_Button,        { 0.25, 0.40, 0.85, 1.00 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.30, 0.48, 0.95, 1.00 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 0.18, 0.32, 0.70, 1.00 });
    else
        imgui.PushStyleColor(ImGuiCol_Button,        { 0.00, 0.00, 0.00, 0.00 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 1.00, 1.00, 1.00, 0.12 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 1.00, 1.00, 1.00, 0.20 });
    end

    local clicked = imgui.Button(label, size);
    imgui.PopStyleColor(3);
    imgui.PopStyleVar(1);
    return clicked;
end

local function SectionHeader(text, availW, helpText)
    local drawList = imgui.GetWindowDrawList();
    local x, y     = imgui.GetCursorScreenPos();
    local lineH    = imgui.GetTextLineHeightWithSpacing();

    local colLeft     = { 0.25, 0.40, 0.85, 1.00 };
    local colRight    = { colLeft[1], colLeft[2], colLeft[3], 0.00 };
    local colLeftU32  = imgui.GetColorU32(colLeft);
    local colRightU32 = imgui.GetColorU32(colRight);
    drawList:AddRectFilledMultiColor(
        { x, y }, { x + availW * 0.75, y + lineH },
        colLeftU32, colRightU32, colRightU32, colLeftU32
    );

    imgui.SetCursorScreenPos({ x + 4, y + 2 });
    imgui.Text(text);

    if helpText then
        imgui.SameLine();
        imgui.TextDisabled('(?)');
        if imgui.IsItemHovered() then
            imgui.SetTooltip(helpText);
        end
    end

    local _, newY = imgui.GetCursorScreenPos();
    imgui.SetCursorScreenPos({ x, newY });
    imgui.Spacing();
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
    local availW  = AvailWidth();
    local comboW  = math.floor((availW - INDENT) * 0.65);

    SectionHeader('Text', availW, hint);
    imgui.Indent(INDENT);

        if imgui.InputText('Content##' .. id, textBuf, 256) then
            tbl.text = textBuf[1];
            cb.save();
        end

        if imgui.InputText('Font##' .. id, fontBuf, 128) then
            tbl.fontFamily = fontBuf[1];
            cb.fonts();
            cb.save();
        end
        if not gdi:get_font_available(tbl.fontFamily) then
            imgui.SameLine();
            imgui.TextColored({ 1.0, 0.4, 0.4, 1.0 }, 'not installed');
        end

        SliderIntSaved('Size##' .. id, tbl, 'fontHeight', 8, 160, '%d px', cb, true);

        local bold = { HasFlag(tbl.fontFlags, 1) };
        if imgui.Checkbox('Bold##' .. id, bold) then
            tbl.fontFlags = SetFlag(tbl.fontFlags, 1, bold[1]);
            cb.fonts();
            cb.save();
        end
        imgui.SameLine();
        local italic = { HasFlag(tbl.fontFlags, 2) };
        if imgui.Checkbox('Italic##' .. id, italic) then
            tbl.fontFlags = SetFlag(tbl.fontFlags, 2, italic[1]);
            cb.fonts();
            cb.save();
        end

    imgui.Unindent(INDENT);
    imgui.Spacing();

    SectionHeader('Colours', availW, 'Fill fades into the gradient colour along the fade direction.');
    imgui.Indent(INDENT);

        ColorRow('Fill##' .. id, tbl, 'fontColor', cb);
        ColorRow('Gradient##' .. id, tbl, 'gradientColor', cb);

        local style = { tbl.gradientStyle };
        imgui.SetNextItemWidth(comboW);
        if imgui.Combo('Fade##' .. id, style, GRADIENT_LABELS) then
            tbl.gradientStyle = style[1];
            cb.fonts();
            cb.save();
        end

        ColorRow('Outline##' .. id, tbl, 'outlineColor', cb);
        SliderIntSaved('Outline width##' .. id, tbl, 'outlineWidth', 0, 12, '%d px', cb, true);

    imgui.Unindent(INDENT);
    imgui.Spacing();

    SectionHeader('Placement', availW, 'Vertical offset from the banner centre.');
    imgui.Indent(INDENT);
        SliderIntSaved('Y offset##' .. id, tbl, 'offsetY', -200, 200, '%d px', cb, false);
    imgui.Unindent(INDENT);
    imgui.Spacing();
end

local function GeneralTab(config, cb)
    local availW = AvailWidth();
    local itemW  = math.floor(availW * 0.80);
    local pad    = math.floor((availW - itemW) * 0.5);

    SectionHeader('Position', availW, 'Where the banner sits vertically.\n0 is the top of the screen, 100 the bottom.');
    imgui.Indent(INDENT);

        local posY = { config.screenPosY };
        if imgui.SliderFloat('Screen Y', posY, 0.0, 100.0, '%.1f%%') then
            config.screenPosY = posY[1];
        end
        if imgui.IsItemDeactivatedAfterEdit() then
            cb.save();
        end

    imgui.Unindent(INDENT);
    imgui.Spacing();

    SectionHeader('Sound', availW, 'Played once when a spell is learned.\nThe file must sit in the blulearn folder.');
    imgui.Indent(INDENT);

        local enabled = { config.soundEnabled };
        if imgui.Checkbox('Play a sound', enabled) then
            config.soundEnabled = enabled[1];
            cb.save();
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Mute the banner without clearing the filename.');
        end

        if imgui.InputText('File##sound', buf.soundFile, 128) then
            config.soundFile = buf.soundFile[1];
            cb.save();
        end
        if not ashita.fs.exists(string.format('%s/%s', addon.path, config.soundFile)) then
            imgui.SameLine();
            imgui.TextColored({ 1.0, 0.4, 0.4, 1.0 }, 'not found');
        end

    imgui.Unindent(INDENT);
    imgui.Spacing();

    imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
    if StyledButton('Reload settings file', { itemW, 0 }, true, false) then
        cb.reload();
        M.SyncBuffers(config);
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Re-read settings.lua from disk. Use after editing\nthe values this window does not expose.');
    end

    imgui.Spacing();

    imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
    if StyledButton('Reset to defaults', { itemW, 0 }, false, false) then
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
* @param {table} cb - { save, fonts, test, hold, holding, reset, close }
--]]
function M.Draw(config, cb)
    if not open[1] then
        return;
    end

    -- No NoSavedSettings flag: imgui.ini persists the position by window title.
    -- AlwaysAutoResize fits the height to the active tab and drops the resize
    -- grip; the window is still draggable by its title bar.
    if imgui.Begin('blulearn.' .. addon.version, open, ImGuiWindowFlags_AlwaysAutoResize) then
        -- Pins the content width. Without it, auto-resize would size to whichever
        -- tab is widest and the window would jump on every tab switch.
        imgui.Dummy({ 370, 1 });

        local availW = AvailWidth();
        local rowW   = math.floor(availW * 0.80);
        local btnW   = math.floor((rowW - BUTTON_GAP) * 0.5);
        local pad    = math.floor((availW - rowW) * 0.5);

        imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
        if StyledButton('Play', { btnW, 0 }, true, false) then
            cb.test();
        end
        imgui.SameLine(0, BUTTON_GAP);
        if StyledButton('Hold', { btnW, 0 }, false, cb.holding()) then
            cb.hold();
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Freeze the banner in its final position\nso you can adjust it live.');
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
    imgui.End();

    -- Closing via the X leaves a held banner stuck on screen otherwise.
    if not open[1] then
        cb.close();
    end
end

return M;
