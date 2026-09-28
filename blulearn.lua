addon.name      = 'blulearn';
addon.author    = 'Thorny, Zaldas';
addon.version   = '1.1';
addon.desc      = 'Animated banner naming each blue magic spell you learn.';
addon.link      = 'https://github.com/Zaldas/blulearn';

require('common');

local chat      = require('chat');
local d3d       = require('d3d8');
local ffi       = require('ffi');
local settings  = require('settings');
local gdi       = require('gdifonts.include');
local configUi  = require('config');

-- The banner draws its image layers and its text in one present callback, so
-- gdifonts must not render on its own tick -- otherwise the text order relative
-- to the layer sprite is whatever the handler registration order happens to be.
gdi:set_auto_render(false);

-- Message 419 (MsgBasic::LearnsSpell) in packet 0x0029. LSB puts the spell id in
-- the Data field, so the banner can name the spell rather than the event.
local MSG_LEARNS_SPELL  = 419;
local OFFSET_DATA       = 0x0C;
local OFFSET_MESSAGENUM = 0x18;

local TWO_PI = math.pi * 2;

-- Phase lengths in seconds. The mask starts fading the moment the spin lands;
-- the staff follows staffDelay later. hold then measures how long the text
-- stands alone before it fades.
local TIMELINE = {
    entrance   = 0.40,
    spin       = 0.70,
    textIn     = 0.15,
    maskOut    = 0.35,
    staffDelay = 0.20,
    staffOut   = 0.35,
    hold       = 0.90,
    textOut    = 0.50,
};


local defaults = T{
    -- Vertical placement as a percentage of screen height: 0 top, 100 bottom.
    screenPosY   = 30.0,
    soundEnabled = true,
    soundFile    = 'blu_action_learned.wav',

    -- Heights are frame heights. Both images are cropped tight, so visible
    -- height tracks these closely; re-padding an image breaks that.
    mask = T{
        image   = 'bluMask.png',
        height  = 85,
        opacity = .8,
        offsetY = 10,
    },

    staff = T{
        image      = 'bluCane.png',
        height     = 224,
        opacity    = .9,
        offsetY    = 0,
        riseHeight = 50,
        spins      = 1,
    },

    title = T{
        text          = 'Action Learned!',
        fontFamily    = 'Jupiter Pro',
        fontHeight    = 64,
        fontColor     = 0xFF003A8F,
        fontFlags     = gdi.FontFlags.Bold,
        outlineColor  = 0xFFC7DCFF,
        outlineWidth  = 4,
        gradientStyle = gdi.Gradient.BottomToTop,
        gradientColor = 0xFF2E6FD0,
        offsetY       = -36,
    },

    subtitle = T{
        text          = '${spell}',
        fontFamily    = 'Jupiter Pro',
        fontHeight    = 36,
        fontColor     = 0xFF003A8F,
        fontFlags     = gdi.FontFlags.Bold,
        outlineColor  = 0xFFC7DCFF,
        outlineWidth  = 2,
        gradientStyle = gdi.Gradient.TopToBottom,
        gradientColor = 0xFF2E6FD0,
        offsetY       = 44,
    },
};

-- settings.load deep merges defaults into the saved file, but any block the file
-- is missing entirely is aliased straight off the defaults table. Snapshot first
-- so Reset always has an untouched copy to restore from.
local PRISTINE = defaults:copy(true);

local config = settings.load(defaults);

local banner = T{
    active      = false,
    hold        = false,
    triggeredAt = 0,
};

local layers = T{
    mask  = T{ texture = nil, width = 0, height = 0 },
    staff = T{ texture = nil, width = 0, height = 0 },
};

local titleObj    = nil;
local subtitleObj = nil;

local sprite    = nil;
local vecScale  = ffi.new('D3DXVECTOR2', { 1.0, 1.0 });
local vecCenter = ffi.new('D3DXVECTOR2', { 0.0, 0.0 });
local vecPos    = ffi.new('D3DXVECTOR2', { 0.0, 0.0 });


local function GetScreenSize()
    local mgr = AshitaCore:GetConfigurationManager();
    local w   = mgr:GetFloat('boot', 'ffxi.registry', '0001', 1024);
    local h   = mgr:GetFloat('boot', 'ffxi.registry', '0002', 768);
    return w, h;
end

local function Clamp01(v)
    if v < 0 then return 0; elseif v > 1 then return 1; end
    return v;
end

local function EaseOut(t)
    local inv = 1.0 - Clamp01(t);
    return 1.0 - (inv * inv);
end

-- 0 before the phase opens, 1 once it has closed. A zero-length phase is treated
-- as already complete rather than dividing by zero.
local function Phase(elapsed, start, length)
    if elapsed <= start then
        return 0.0;
    end
    if length <= 0 then
        return 1.0;
    end
    return Clamp01((elapsed - start) / length);
end


-- Midpoint of the title top and the subtitle bottom, relative to centre. The
-- images centre on this rather than on centre itself, so they stay aligned with
-- the text block when font sizes or offsets change.
--
-- The subtitle's measured texture height is used rather than its fontHeight,
-- since the rasterised text carries the outline and the font's internal leading
-- on top of the requested cell. get_text_size is cached unless the text changed.
local function TextBlockCenter()
    local height = config.subtitle.fontHeight;

    if subtitleObj ~= nil then
        local _, measured = subtitleObj:get_text_size();
        if (measured ~= nil) and (measured > 0) then
            height = measured;
        end
    end

    return (config.title.offsetY + config.subtitle.offsetY + height) / 2;
end

local function ApplyFont(obj, cfg)
    obj:set_font_family(cfg.fontFamily);
    obj:set_font_height(cfg.fontHeight);
    obj:set_font_color(cfg.fontColor);
    obj:set_font_flags(cfg.fontFlags);
    obj:set_outline_color(cfg.outlineColor);
    obj:set_outline_width(cfg.outlineWidth);
    obj:set_gradient_style(cfg.gradientStyle);
    obj:set_gradient_color(cfg.gradientColor);
    obj:set_font_alignment(gdi.Alignment.Center);
end

local function ApplyFonts()
    ApplyFont(titleObj, config.title);
    ApplyFont(subtitleObj, config.subtitle);
end

-- Kept out of ApplyFont: that runs from slider drags, so a missing font would
-- print once per frame. Only call this from load, reload and reset.
local function WarnMissingFonts()
    for _, cfg in ipairs({ config.title, config.subtitle }) do
        if not gdi:get_font_available(cfg.fontFamily) then
            print(chat.header(addon.name) .. chat.warning(('Font \'%s\' is not installed; GDI will substitute a default.'):format(cfg.fontFamily)));
        end
    end
end

local function CreateTextObjects()
    titleObj    = gdi:create_object({ text = '', visible = false, opacity = 0, z_order = 1 });
    subtitleObj = gdi:create_object({ text = '', visible = false, opacity = 0, z_order = 1 });
    ApplyFonts();
    WarnMissingFonts();
end


local function LoadLayer(layer, file)
    layer.texture = nil;
    layer.width   = 0;
    layer.height  = 0;

    if (file == nil) or (file == '') then
        return;
    end

    local path = string.format('%s/%s', addon.path, file);
    if not ashita.fs.exists(path) then
        print(chat.header(addon.name) .. chat.warning(('Image not found: %s'):format(path)));
        return;
    end

    -- Wrapped: a d3dx8 build missing either export raises on the ffi.C index
    -- itself, which would otherwise abort the load event.
    local ok, err = pcall(function()
        local info = ffi.new('D3DXIMAGE_INFO[1]');
        if (ffi.C.D3DXGetImageInfoFromFileA(path, info) ~= ffi.C.S_OK) then
            error(('could not read image info: %s'):format(file), 0);
        end

        local tex = ffi.new('IDirect3DTexture8*[1]');
        if (ffi.C.D3DXCreateTextureFromFileA(d3d.get_device(), path, tex) ~= ffi.C.S_OK) then
            error(('could not load texture: %s'):format(file), 0);
        end

        layer.texture = d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', tex[0]));
        layer.width   = info[0].Width;
        layer.height  = info[0].Height;
    end);

    if not ok then
        layer.texture = nil;
        layer.width   = 0;
        layer.height  = 0;
        print(chat.header(addon.name) .. chat.error(('Layer disabled - %s'):format(err)));
    end
end

local function LoadLayers()
    LoadLayer(layers.mask, config.mask.image);
    LoadLayer(layers.staff, config.staff.image);
end

-- targetHeight is the on-screen frame height; the scale is derived here so the
-- guard and the division that needs it cannot drift apart.
local function DrawLayer(layer, targetHeight, rotation, centerX, centerY, alpha)
    if (layer.texture == nil) or (layer.height == 0) or (alpha <= 0) then
        return;
    end

    local scale = targetHeight / layer.height;
    local drawW = layer.width * scale;
    local drawH = layer.height * scale;

    vecScale.x  = scale;
    vecScale.y  = scale;
    vecCenter.x = drawW / 2;
    vecCenter.y = drawH / 2;
    vecPos.x    = centerX - (drawW / 2);
    vecPos.y    = centerY - (drawH / 2);

    sprite:Draw(layer.texture, nil, vecScale, vecCenter, rotation,
        vecPos, d3d.D3DCOLOR_ARGB(math.floor(255 * alpha), 255, 255, 255));
end


local function HideBanner()
    banner.active = false;
    banner.hold   = false;
    if titleObj ~= nil then titleObj:set_visible(false); end
    if subtitleObj ~= nil then subtitleObj:set_visible(false); end
end

local function ExpandTokens(format, spellName)
    local playerName = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0) or '';
    local out = string.gsub(format, '%${spell}', spellName);
    out = string.gsub(out, '%${player}', playerName);
    return out;
end

local function PlaySound()
    if (not config.soundEnabled) or (config.soundFile == '') then
        return;
    end

    local path = string.format('%s/%s', addon.path, config.soundFile);
    if not ashita.fs.exists(path) then
        print(chat.header(addon.name) .. chat.warning(('Sound file not found: %s'):format(path)));
        return;
    end

    ashita.misc.play_sound(path);
end

-- hold freezes every element in its settled position for layout work: no
-- animation, no expiry, and no sound since it is toggled repeatedly.
local function TriggerBanner(spellName, hold)
    if (titleObj == nil) or (subtitleObj == nil) then
        return;
    end

    titleObj:set_text(ExpandTokens(config.title.text, spellName));
    subtitleObj:set_text(ExpandTokens(config.subtitle.text, spellName));
    titleObj:set_visible(true);
    subtitleObj:set_visible(true);

    banner.active      = true;
    banner.hold        = (hold == true);
    banner.triggeredAt = os.clock();

    if not banner.hold then
        PlaySound();
    end
end


-- config is mutated in place rather than replaced: the settings library saves
-- the table it cached at load time, so reassigning it would silently stop
-- anything from persisting.
local uiCallbacks = {
    save    = function() settings.save(); end,
    test    = function() TriggerBanner('Frenetic Rip'); end,
    holding = function() return banner.active and banner.hold; end,
    fonts   = ApplyFonts,

    hold = function()
        if banner.active and banner.hold then
            HideBanner();
        else
            TriggerBanner('Frenetic Rip', true);
        end
    end,

    close = function()
        if banner.active and banner.hold then
            HideBanner();
        end
    end,

    -- settings.load raises the settings-changed event, whose handler reapplies
    -- the fonts and reloads the layers. Repeating that here would build every
    -- texture twice.
    reload = function()
        config = settings.load(defaults);
    end,

    reset = function()
        for k in pairs(config) do
            config[k] = nil;
        end
        config:merge(PRISTINE:copy(true));
        settings.save();
        ApplyFonts();
        WarnMissingFonts();
        LoadLayers();
    end,
};


ashita.events.register('d3d_present', 'blulearn_present_cb', function()
    configUi.Draw(config, uiCallbacks);

    if not banner.active then
        return;
    end

    local maskAlpha, staffAlpha, textAlpha, rise, rotation;

    if banner.hold then
        maskAlpha, staffAlpha, textAlpha, rise, rotation = 1.0, 1.0, 1.0, 0.0, 0.0;
    else
        local t = os.clock() - banner.triggeredAt;

        local tEntrance  = TIMELINE.entrance;
        local tSpin      = tEntrance + TIMELINE.spin;
        local tStaffOut  = tSpin + TIMELINE.staffDelay;
        local imagesGone = math.max(tSpin + TIMELINE.maskOut, tStaffOut + TIMELINE.staffOut);
        local tTextOut   = imagesGone + TIMELINE.hold;
        local tEnd       = tTextOut + TIMELINE.textOut;

        if t >= tEnd then
            HideBanner();
            return;
        end

        local entrance = EaseOut(Phase(t, 0, TIMELINE.entrance));

        maskAlpha  = entrance * (1.0 - Phase(t, tSpin, TIMELINE.maskOut));
        staffAlpha = entrance * (1.0 - Phase(t, tStaffOut, TIMELINE.staffOut));
        textAlpha  = Phase(t, tEntrance, TIMELINE.textIn) * (1.0 - Phase(t, tTextOut, TIMELINE.textOut));
        rise       = config.staff.riseHeight * (1.0 - entrance);
        -- Negated: D3DX8 rotates counter-clockwise for a positive angle, so a
        -- positive spins value reads as clockwise.
        rotation   = -TWO_PI * config.staff.spins * EaseOut(Phase(t, tEntrance, TIMELINE.spin));
    end

    local screenW, screenH = GetScreenSize();
    local centerX = screenW / 2;
    local centerY = screenH * (config.screenPosY / 100);

    local imageY = centerY + TextBlockCenter();

    if sprite ~= nil then
        sprite:Begin();

        DrawLayer(layers.mask,
            config.mask.height,
            0.0,
            centerX,
            imageY + config.mask.offsetY,
            maskAlpha * config.mask.opacity);

        -- Drawn after the mask so the staff sweeps across its face. Rotation
        -- eases out, so the flourish starts fast and settles on the full turn.
        DrawLayer(layers.staff,
            config.staff.height,
            rotation,
            centerX,
            imageY + config.staff.offsetY - rise,
            staffAlpha * config.staff.opacity);

        sprite:End();
    end

    titleObj:set_position_x(centerX);
    titleObj:set_position_y(centerY + config.title.offsetY);
    titleObj:set_opacity(textAlpha);

    subtitleObj:set_position_x(centerX);
    subtitleObj:set_position_y(centerY + config.subtitle.offsetY);
    subtitleObj:set_opacity(textAlpha);

    gdi:render();
end);


ashita.events.register('packet_in', 'blulearn_packet_cb', function(e)
    if e.id ~= 0x0029 then
        return;
    end

    if struct.unpack('H', e.data, OFFSET_MESSAGENUM + 0x01) ~= MSG_LEARNS_SPELL then
        return;
    end

    local spellId = struct.unpack('I', e.data, OFFSET_DATA + 0x01);
    local spell   = AshitaCore:GetResourceManager():GetSpellById(spellId);

    local name;
    if spell ~= nil then
        name = spell.Name[1];
    end
    if (name == nil) or (name == '') then
        name = string.format('Spell #%d', spellId);
    end

    TriggerBanner(name);
end);


ashita.events.register('command', 'blulearn_command_cb', function(e)
    local args = e.command:args();
    if #args == 0 then
        return;
    end

    local cmd = args[1]:lower();
    if (cmd ~= '/blulearn') and (cmd ~= '/bl') then
        return;
    end

    e.blocked = true;

    -- Toggling shut bypasses the window's own close handling, which would leave
    -- a held banner on screen with nothing left to expire it.
    if not configUi.Toggle(config) then
        uiCallbacks.close();
    end
end);


settings.register('settings', 'blulearn_settings_update', function(s)
    if s == nil then
        return;
    end
    config = s;
    configUi.SyncBuffers(config);
    if titleObj == nil then
        return;
    end
    ApplyFonts();
    WarnMissingFonts();
    LoadLayers();
end);


ashita.events.register('load', 'blulearn_load_cb', function()
    local spriteRef = ffi.new('ID3DXSprite*[1]');
    if (ffi.C.D3DXCreateSprite(d3d.get_device(), spriteRef) == ffi.C.S_OK) then
        sprite = d3d.gc_safe_release(ffi.cast('ID3DXSprite*', spriteRef[0]));
    else
        print(chat.header(addon.name) .. chat.error('Could not create sprite; the images will not render.'));
    end

    CreateTextObjects();
    LoadLayers();
end);


ashita.events.register('unload', 'blulearn_unload_cb', function()
    HideBanner();

    if titleObj ~= nil then gdi:destroy_object(titleObj); end
    if subtitleObj ~= nil then gdi:destroy_object(subtitleObj); end
    gdi:destroy_interface();

    layers.mask.texture  = nil;
    layers.staff.texture = nil;
    sprite               = nil;

    ashita.events.unregister('d3d_present', 'blulearn_present_cb');
    ashita.events.unregister('packet_in', 'blulearn_packet_cb');
    ashita.events.unregister('command', 'blulearn_command_cb');
    ashita.events.unregister('load', 'blulearn_load_cb');
    ashita.events.unregister('unload', 'blulearn_unload_cb');
end);
