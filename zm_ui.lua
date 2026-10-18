--[[
    ZoneMusic - Crystal window.

    Draws the jukebox (Zones / Bosses / Events / Cutscenes) and hosts the
    existing settings pages under a Settings tab. Everything the window needs
    comes through the ctx table built in zonemusic.lua (jukebox.ui); this file
    never reaches into addon locals, which keeps the main file's closures
    under the upvalue limit.

    Only draw-list primitives are used (filled/gradient rects, lines,
    circles, triangles, sized text) so the look holds on any ImGui build
    Ashita ships.
--]]

require('common');
local imgui = require('imgui');

local zm_ui = {};

-- Palette (0-1 RGBA). Navy glass, gold hairlines, cyan for "live/selected".
local C = {
    window  = { 0.047, 0.075, 0.129, 0.93 },
    gold    = { 0.788, 0.643, 0.361, 1.00 },
    cyan    = { 0.435, 0.765, 0.875, 1.00 },
    ivory   = { 0.910, 0.894, 0.847, 1.00 },
    title   = { 0.945, 0.906, 0.800, 1.00 },
    text    = { 0.812, 0.827, 0.863, 1.00 },
    muted   = { 0.541, 0.576, 0.651, 1.00 },
    faint   = { 0.373, 0.408, 0.475, 1.00 },
    card    = { 1.000, 1.000, 1.000, 0.03 },
    edge    = { 0.149, 0.184, 0.259, 1.00 },
    edge_hi = { 0.239, 0.353, 0.451, 1.00 },
    track   = { 0.137, 0.169, 0.231, 1.00 },
    coral   = { 0.878, 0.565, 0.478, 1.00 },
    frame   = { 0.000, 0.000, 0.000, 0.35 },
};

local HEADER_H = 40;
local FOOTER_H = 88;
local LIST_W   = 320;
local NAV_W    = 190;
local BOTTOM_GAP = 14;  -- breathing room above the footer in every pane

local TABS = { 'Zones', 'Bosses', 'Events', 'Cutscenes', 'Settings' };
local REVIEW_TAB = 5;  -- zero-based; only shown while review.lua exists
local SETTINGS_PAGES = { 'Status', 'Battle', 'Playback', 'Fade & Duck', 'Events', 'Health' };
local HEALTH_PAGE = 5;  -- zero-based index of 'Health'; drawn here, not by the addon
local TRACK_KINDS = {
    { key = 'day',   label = 'Day' },
    { key = 'night', label = 'Night' },
    { key = 'solo',  label = 'Battle - Solo' },
    { key = 'party', label = 'Battle - Party' },
};

-- Balance tracking so an error mid-frame can still unwind the ImGui stacks
-- instead of tripping an assert and taking the client down with it.
local open_children = 0;
local error_reported = false;

-- Draw-list colors are packed ABGR. Prefer the binding's GetColorU32 (it
-- honors the global style alpha); if this build rejects a table argument,
-- pack the bits ourselves from then on.
local color_mode = nil; -- nil = untested, 'imgui', or 'packed'

local function channel(v)
    v = math.floor(v * 255 + 0.5);
    if (v < 0) then return 0; end
    if (v > 255) then return 255; end
    return v;
end

local function u32(c, alpha)
    local a = c[4] * (alpha or 1);
    if (color_mode ~= 'packed') then
        local ok, value = pcall(imgui.GetColorU32, { c[1], c[2], c[3], a });
        if (ok and type(value) == 'number') then
            color_mode = 'imgui';
            return value;
        end
        color_mode = 'packed';
    end
    return bit.bor(bit.lshift(channel(a), 24), bit.lshift(channel(c[3]), 16),
        bit.lshift(channel(c[2]), 8), channel(c[1]));
end

local function begin_child(id, w, h, padding)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, padding or { 0, 0 });
    imgui.BeginChild(id, { w, h }, ImGuiChildFlags_AlwaysUseWindowPadding or 0);
    imgui.PopStyleVar(1);
    open_children = open_children + 1;
end

local function end_child()
    imgui.EndChild();
    open_children = open_children - 1;
end

local function font_size()
    local ok, size = pcall(imgui.GetFontSize);
    return (ok and size) or 13;
end

-- Text on the draw list at an arbitrary pixel size; falls back to the
-- default size where the sized AddText overload is missing.
local function text_at(dl, x, y, color, text, size)
    if (size ~= nil) then
        local ok = pcall(function()
            dl:AddText(imgui.GetFont(), size, { x, y }, color, text);
        end);
        if (ok) then return; end
    end
    dl:AddText({ x, y }, color, text);
end

local function text_width(text, size)
    local w = imgui.CalcTextSize(text);
    if (size ~= nil) then
        return w * size / font_size();
    end
    return w;
end

-- Shorten text with an ellipsis until it fits max_w pixels.
local function fit_text(text, max_w, size)
    if (text_width(text, size) <= max_w) then return text; end
    local cut = #text;
    while (cut > 1 and text_width(text:sub(1, cut) .. '...', size) > max_w) do
        cut = cut - 1;
    end
    return (text:sub(1, cut):gsub('%s+$', '')) .. '...';
end

local function fmt_time(ms)
    local s = math.floor((ms or 0) / 1000);
    return string.format('%d:%02d', math.floor(s / 60), s % 60);
end

-- No SetMouseCursor anywhere in this file: the game draws its own cursor,
-- and asking ImGui for a hand cursor makes the backend swap it for an OS
-- cursor the game hides, so the pointer vanishes over the window.

-- Left-to-right gradient bar, used for section rules and the progress bar.
local function fade_line(dl, x1, y, x2, color, thickness)
    dl:AddRectFilledMultiColor({ x1, y }, { x2, y + (thickness or 1) },
        u32(color, 0.55), u32(color, 0.0), u32(color, 0.0), u32(color, 0.55));
end

-- Transport glyphs, drawn from primitives so they never depend on the
-- font having symbol characters.
local function glyph(dl, kind, cx, cy, r, color)
    local s = r * 0.42;
    if (kind == 'pause') then
        local bw = s * 0.55;
        dl:AddRectFilled({ cx - s * 0.8, cy - s }, { cx - s * 0.8 + bw, cy + s }, color);
        dl:AddRectFilled({ cx + s * 0.8 - bw, cy - s }, { cx + s * 0.8, cy + s }, color);
    elseif (kind == 'stop') then
        s = r * 0.36;
        dl:AddRectFilled({ cx - s, cy - s }, { cx + s, cy + s }, color);
    elseif (kind == 'next') then
        dl:AddTriangleFilled({ cx - s, cy - s }, { cx - s, cy + s }, { cx + s * 0.6, cy }, color);
        dl:AddRectFilled({ cx + s * 0.6, cy - s }, { cx + s * 0.95, cy + s }, color);
    elseif (kind == 'prev') then
        dl:AddTriangleFilled({ cx + s, cy - s }, { cx + s, cy + s }, { cx - s * 0.6, cy }, color);
        dl:AddRectFilled({ cx - s * 0.95, cy - s }, { cx - s * 0.6, cy + s }, color);
    else
        dl:AddTriangleFilled({ cx - s * 0.7, cy - s }, { cx - s * 0.7, cy + s }, { cx + s, cy }, color);
    end
end

local INK = { 0.047, 0.075, 0.129, 1.00 }; -- glyph color on the gold play button

local function tooltip(text)
    if (imgui.IsItemHovered() and imgui.SetTooltip ~= nil) then
        imgui.SetTooltip(text);
    end
end

-- Pill switch. Returns true when clicked.
local function switch(id, on)
    local x, y = imgui.GetCursorScreenPos();
    local clicked = imgui.InvisibleButton(id, { 38, 20 });
    local hovered = imgui.IsItemHovered();
    local dl = imgui.GetWindowDrawList();
    dl:AddRectFilled({ x, y }, { x + 38, y + 20 },
        on and u32({ 0.184, 0.435, 0.525, 1 }) or u32(C.track), 10);
    local knob_x = on and (x + 29) or (x + 10);
    dl:AddCircleFilled({ knob_x, y + 10 }, 7,
        on and u32({ 0.741, 0.941, 1.0, 1 }) or u32(C.muted), 16);
    return clicked;
end

-- One track card. Returns true when clicked.
local function track_card(ctx, id, w, h, kind_label, title, sub, file, missing_text)
    local jb = ctx.jukebox;
    local x, y = imgui.GetCursorScreenPos();
    local clicked = imgui.InvisibleButton(id, { w, h });
    local hovered = imgui.IsItemHovered();
    local dl = imgui.GetWindowDrawList();
    local missing = (file == nil);
    local playing = (not missing) and jb.active and jb.file == file;
    local sounding = playing and not jb.paused;
    local alpha = missing and 0.4 or 1.0;

    dl:AddRectFilled({ x, y }, { x + w, y + h },
        playing and u32(C.cyan, 0.09) or u32(C.card), 3);
    dl:AddRect({ x, y }, { x + w, y + h },
        playing and u32(C.cyan) or ((hovered and not missing) and u32(C.edge_hi) or u32(C.edge)), 3);

    local cy = y + h * 0.5;
    dl:AddCircle({ x + 26, cy }, 16, u32(C.gold, alpha), 24, 1.0);
    glyph(dl, sounding and 'pause' or 'play', x + 26, cy, 16, u32(C.gold, alpha));

    local tx = x + 52;
    if (kind_label ~= nil) then
        text_at(dl, tx, cy - 17, u32(C.gold, alpha), string.upper(kind_label), font_size() * 0.85);
        text_at(dl, tx, cy + 1, u32(C.muted, alpha), missing and (missing_text or 'No file') or title);
    else
        text_at(dl, tx, cy - 17, u32(C.ivory, alpha), title);
        text_at(dl, tx, cy + 1, u32(C.muted, alpha), sub or '');
    end

    if (playing) then
        local t = jb.paused and 'PAUSED'
            or string.format('%s / %s', fmt_time(jb.position_ms()), fmt_time(jb.length_ms));
        text_at(dl, x + w - 12 - text_width(t), cy - 7, u32(C.cyan), t);
    end

    return clicked and not missing, playing;
end

local function section_rule(dl, x, y, w, label)
    local size = font_size() * 0.85;
    local text = string.upper(label);
    text_at(dl, x, y, u32(C.gold), text, size);
    local tw = text_width(text, size);
    fade_line(dl, x + tw + 8, y + size * 0.55, x + w, C.gold, 1);
end

------------------------------------------------------------
-- Header (title + tabs + close)
------------------------------------------------------------
local function draw_header(ctx, wx, wy, ww)
    local gs = ctx.gui_state;
    local dl = imgui.GetWindowDrawList();
    dl:AddRectFilledMultiColor({ wx, wy }, { wx + ww, wy + HEADER_H },
        u32(C.gold, 0.22), u32(C.gold, 0.0), u32(C.gold, 0.0), u32(C.gold, 0.22));
    dl:AddLine({ wx, wy + HEADER_H }, { wx + ww, wy + HEADER_H }, u32(C.gold, 0.4), 1);
    local title = 'Z O N E M U S I C';
    text_at(dl, wx + 16, wy + 11, u32(C.title), title, font_size() * 1.15);

    -- Master switch next to the title: one click turns the whole addon off
    -- (game music everywhere) or back on, from any tab.
    local enabled = ctx.live().enabled;
    local sx = wx + 16 + text_width(title, font_size() * 1.15) + 18;
    imgui.SetCursorScreenPos({ sx, wy + 10 });
    if (switch('##zm_master', enabled)) then
        ctx.set_addon_enabled(not enabled);
    end
    tooltip(enabled and 'ZoneMusic is on. Click to turn it off everywhere (game music plays).'
        or 'ZoneMusic is off everywhere. Click to turn it back on.');
    text_at(dl, sx + 46, wy + 14, enabled and u32(C.cyan) or u32(C.coral), enabled and 'ON' or 'OFF', font_size() * 0.85);

    -- Close button, far right.
    local cx = wx + ww - 34;
    imgui.SetCursorScreenPos({ cx, wy + 8 });
    if (imgui.InvisibleButton('##zm_close', { 24, 24 })) then
        gs.is_open[1] = false;
    end
    local close_hover = imgui.IsItemHovered();
    local col = close_hover and u32(C.ivory) or u32(C.muted);
    dl:AddLine({ cx + 7, wy + 15 }, { cx + 17, wy + 25 }, col, 1.5);
    dl:AddLine({ cx + 17, wy + 15 }, { cx + 7, wy + 25 }, col, 1.5);

    -- Tabs, laid out right-to-left from the close button. The Review tab
    -- exists only while a review list (review.lua) is installed.
    local tabs = TABS;
    local catalog = ctx.catalog();
    if (catalog.review ~= nil and #catalog.review > 0) then
        tabs = { TABS[1], TABS[2], TABS[3], TABS[4], TABS[5], 'Review' };
    end
    local x = cx - 12;
    for i = #tabs, 1, -1 do
        local label = tabs[i];
        local tw = text_width(label) + 22;
        x = x - tw;
        imgui.SetCursorScreenPos({ x, wy + 6 });
        if (imgui.InvisibleButton('##zm_tab' .. i, { tw, HEADER_H - 8 })) then
            gs.ui_tab = i - 1;
        end
        local hovered = imgui.IsItemHovered();
        local active = (gs.ui_tab == i - 1);
        text_at(dl, x + 11, wy + 13,
            active and u32(C.ivory) or (hovered and u32(C.text) or u32(C.muted)), label);
        if (active) then
            dl:AddRectFilled({ x + 6, wy + HEADER_H - 3 }, { x + tw - 6, wy + HEADER_H - 1 }, u32(C.cyan));
        end
    end
end

------------------------------------------------------------
-- Zones tab
------------------------------------------------------------
local function zone_matches(zone, needle)
    if (needle == '') then return true; end
    if (string.find(string.lower(zone.name), needle, 1, true)) then return true; end
    if (zone.districts and string.find(string.lower(zone.districts), needle, 1, true)) then return true; end
    return string.find(tostring(zone.id), needle, 1, true) ~= nil;
end

-- A search shows matches from every expansion, collapsed or not;
-- otherwise a collapsed expansion hides its zones.
local function zone_visible(gs, zone, needle)
    if (needle ~= '') then return zone_matches(zone, needle); end
    return not gs.ui_collapsed[zone.expansion];
end

-- Every playable track of the zones currently listed, in list order, so
-- next/previous walk the list the way it reads. anchor_id is the zone being
-- played from; it is always included, even inside a collapsed section.
local function zone_cards(zone)
    -- Game-played zones (cover DATs) bring their own cards; every other zone
    -- shows the four standard slots, with a hint when a slot is empty.
    if (zone.custom ~= nil) then return zone.custom; end
    local cards = {};
    for _, kind in ipairs(TRACK_KINDS) do
        local missing = nil;
        if (kind.key == 'night' and zone.tracks.day ~= nil) then missing = 'Uses the Day track'; end
        if ((kind.key == 'solo' and zone.tracks.party ~= nil)
            or (kind.key == 'party' and zone.tracks.solo ~= nil)) then
            missing = 'Uses the other battle track';
        end
        table.insert(cards, { label = kind.label, file = zone.tracks[kind.key], missing = missing });
    end
    return cards;
end

local function zone_queue(ctx, catalog, anchor_id)
    local gs = ctx.gui_state;
    local needle = string.lower(gs.ui_search[1] or '');
    local queue = {};
    for _, zone in ipairs(catalog.zones) do
        if (zone.id == anchor_id or zone_visible(gs, zone, needle)) then
            for _, card in ipairs(zone_cards(zone)) do
                if (card.file ~= nil) then
                    table.insert(queue, { file = card.file, label = zone.name .. ' · ' .. card.label, zone = zone.id });
                end
            end
        end
    end
    return queue;
end

local function queue_index(queue, file)
    for i, item in ipairs(queue) do
        if (item.file == file) then return i; end
    end
    return 1;
end

-- Collapsible expansion header. Returns true when clicked (ignored while
-- searching, since a search always shows every expansion's matches).
local function expansion_header(gs, key, title, count, searching, w)
    local x, y = imgui.GetCursorScreenPos();
    local h = 30;
    local clicked = imgui.InvisibleButton('##zm_exp_' .. key, { w, h });
    local hovered = imgui.IsItemHovered();
    local dl = imgui.GetWindowDrawList();
    local open = searching or not gs.ui_collapsed[key];
    local glow = hovered and 0.22 or 0.12;
    dl:AddRectFilledMultiColor({ x, y + 2 }, { x + w, y + h - 2 },
        u32(C.gold, glow), u32(C.gold, 0.0), u32(C.gold, 0.0), u32(C.gold, glow));
    dl:AddLine({ x, y + h - 2 }, { x + w, y + h - 2 }, u32(C.gold, 0.35), 1);
    -- Disclosure triangle: pointing right = collapsed, down = open.
    local cx, cy = x + 10, y + h / 2;
    local col = u32(C.gold, searching and 0.4 or 1.0);
    if (open) then
        dl:AddTriangleFilled({ cx - 4, cy - 2 }, { cx + 4, cy - 2 }, { cx, cy + 3 }, col);
    else
        dl:AddTriangleFilled({ cx - 2, cy - 4 }, { cx - 2, cy + 4 }, { cx + 3, cy }, col);
    end
    local count_text = tostring(count);
    text_at(dl, x + w - 8 - text_width(count_text), y + 8, u32(C.muted), count_text);
    text_at(dl, x + 22, y + 7, u32(C.title), fit_text(title, w - 40 - text_width(count_text)));
    return clicked and not searching;
end

local function draw_zone_list(ctx, catalog, h)
    local gs = ctx.gui_state;
    begin_child('##zm_list', LIST_W, h, { 10, 10 });

    imgui.SetNextItemWidth(-1);
    if (imgui.InputTextWithHint ~= nil) then
        imgui.InputTextWithHint('##zm_search', 'Search zones', gs.ui_search, 64);
    else
        imgui.InputText('##zm_search', gs.ui_search, 64);
    end
    imgui.Spacing();

    local _, list_h = imgui.GetContentRegionAvail();
    begin_child('##zm_list_scroll', 0, math.max(40, list_h - BOTTOM_GAP), { 0, 0 });
    local needle = string.lower(gs.ui_search[1] or '');
    local here = ctx.canonical_zone(ctx.current_zone());
    local dl = imgui.GetWindowDrawList();

    -- Zone counts per expansion for the section headers.
    local counts = {};
    for _, zone in ipairs(catalog.zones) do
        if (needle == '' or zone_matches(zone, needle)) then
            counts[zone.expansion] = (counts[zone.expansion] or 0) + 1;
        end
    end

    local last_expansion, last_area = nil, nil;
    for _, zone in ipairs(catalog.zones) do
        local w = imgui.GetContentRegionAvail();
        if (zone.expansion ~= last_expansion and (counts[zone.expansion] or 0) > 0) then
            last_expansion, last_area = zone.expansion, nil;
            if (last_expansion ~= catalog.zones[1].expansion) then imgui.Dummy({ 0, 4 }); end
            if (expansion_header(gs, zone.expansion, zone.expansion_title, counts[zone.expansion], needle ~= '', w)) then
                gs.ui_collapsed[zone.expansion] = not gs.ui_collapsed[zone.expansion];
            end
        end
        if (zone_visible(gs, zone, needle)) then
            if (zone.area ~= last_area) then
                last_area = zone.area;
                local x, y = imgui.GetCursorScreenPos();
                imgui.Dummy({ w, 22 });
                section_rule(dl, x + 12, y + 8, w - 12, zone.category);
            end

            local x, y = imgui.GetCursorScreenPos();
            if (imgui.InvisibleButton('##zm_z' .. zone.id, { w, 24 })) then
                gs.ui_zone = zone.id;
            end
            local hovered = imgui.IsItemHovered();
            local selected = (gs.ui_zone == zone.id);
            if (selected) then
                dl:AddRectFilledMultiColor({ x, y }, { x + w, y + 24 },
                    u32(C.cyan, 0.25), u32(C.cyan, 0.0), u32(C.cyan, 0.0), u32(C.cyan, 0.25));
                dl:AddRectFilled({ x, y }, { x + 2, y + 24 }, u32(C.cyan));
            elseif (hovered) then
                dl:AddRectFilled({ x, y }, { x + w, y + 24 }, u32(C.cyan, 0.08));
            end

            -- Right side first (id, then OFF tag or here-dot), so the name
            -- gets whatever room is left and never runs into them.
            local id_text = tostring(zone.id);
            local right = x + w - 8;
            text_at(dl, right - text_width(id_text), y + 5, u32(C.faint), id_text);
            right = right - text_width(id_text) - 10;
            if (ctx.is_zone_disabled(zone.id)) then
                local tag_w = text_width('OFF', font_size() * 0.8);
                text_at(dl, right - tag_w, y + 7, u32(C.coral), 'OFF', font_size() * 0.8);
                right = right - tag_w - 8;
            elseif (zone.id == here) then
                dl:AddCircleFilled({ right - 3, y + 12 }, 3, u32(C.cyan), 12);
                right = right - 14;
            end
            local name_x = x + 18;
            local name_col = selected and u32({ 1, 1, 1, 1 }) or u32(C.text);
            text_at(dl, name_x, y + 5, name_col, fit_text(zone.name, right - name_x));
        end
    end
    imgui.Dummy({ 0, BOTTOM_GAP });
    end_child();
    end_child();
end

local function find_zone(catalog, id)
    for _, zone in ipairs(catalog.zones) do
        if (zone.id == id) then return zone; end
    end
    return nil;
end

local function draw_note(dl, text, w)
    local x, y = imgui.GetCursorScreenPos();
    imgui.PushTextWrapPos(x - imgui.GetWindowPos() + w - 12);
    imgui.SetCursorScreenPos({ x + 12, y + 7 });
    imgui.PushStyleColor(ImGuiCol_Text, C.muted);
    imgui.TextWrapped(text);
    imgui.PopStyleColor(1);
    imgui.PopTextWrapPos();
    local _, y2 = imgui.GetCursorScreenPos();
    dl:AddRectFilled({ x, y }, { x + w, y2 + 3 }, u32(C.gold, 0.06));
    dl:AddRectFilled({ x, y }, { x + 2, y2 + 3 }, u32(C.gold));
    imgui.SetCursorScreenPos({ x, y2 + 10 });
end

local function draw_zone_detail(ctx, catalog, w, h)
    local gs = ctx.gui_state;
    local jb = ctx.jukebox;
    begin_child('##zm_detail', w, h, { 22, 18 });
    local zone = find_zone(catalog, gs.ui_zone);
    local dl = imgui.GetWindowDrawList();
    local cw = imgui.GetContentRegionAvail();

    if (zone == nil) then
        imgui.TextColored(C.muted, 'Pick a zone on the left to hear its music.');
        end_child();
        return;
    end

    -- Title block. The switch on the right is laid out first so the title
    -- is shortened to the space that is actually left.
    local x, y = imgui.GetCursorScreenPos();
    local title_size = font_size() * 1.8;
    local on = not ctx.is_zone_disabled(zone.id);
    local master_on = ctx.live().enabled;
    local reserved;
    if (not master_on) then
        local label = 'ZONEMUSIC IS OFF';
        local lw = text_width(label, font_size() * 0.85);
        text_at(dl, x + cw - lw, y + 8, u32(C.coral), label, font_size() * 0.85);
        reserved = lw + 24;
    elseif (zone.game_played) then
        local label = 'PLAYED BY THE GAME';
        local lw = text_width(label, font_size() * 0.85);
        text_at(dl, x + cw - lw, y + 8, u32(C.cyan), label, font_size() * 0.85);
        reserved = lw + 24;
    elseif (zone.active_expansion) then
        local label = on and 'Addon music on' or 'Game music (addon off)';
        local lw = text_width(label);
        imgui.SetCursorScreenPos({ x + cw - 38, y + 4 });
        if (switch('##zm_zone_switch', on)) then
            ctx.set_zone_disabled(zone.id, on);
        end
        tooltip((zone.districts and 'Applies to every district of ' .. zone.name .. '. ' or '')
            .. 'Saved for this character.');
        text_at(dl, x + cw - 38 - 10 - lw, y + 7, u32(C.text), label);
        reserved = 38 + 10 + lw + 24;
    else
        local label = 'NOT ACTIVE YET';
        local lw = text_width(label, font_size() * 0.85);
        text_at(dl, x + cw - lw, y + 8, u32(C.coral), label, font_size() * 0.85);
        reserved = lw + 24;
    end

    local here = ctx.canonical_zone(ctx.current_zone());
    local tag = (zone.id == here) and 'YOU ARE HERE' or nil;
    local tag_w = tag and (text_width(tag, font_size() * 0.8) + 14) or 0;
    local title = fit_text(zone.name, cw - reserved - tag_w, title_size);
    text_at(dl, x, y, u32(C.title), title, title_size);
    if (tag ~= nil) then
        text_at(dl, x + text_width(title, title_size) + 14, y + title_size * 0.45, u32(C.cyan), tag, font_size() * 0.8);
    end

    local ids = {};
    for _, zid in ipairs(zone.members) do table.insert(ids, tostring(zid)); end
    local sub = zone.expansion_title .. '  ·  ' .. zone.category
        .. (zone.districts and ('  ·  ' .. zone.districts) or '')
        .. '  ·  Zone ' .. table.concat(ids, ', ');
    text_at(dl, x, y + title_size + 6, u32(C.muted), fit_text(sub, cw));

    imgui.SetCursorScreenPos({ x, y + title_size + font_size() + 22 });

    -- Track cards, two per row.
    local card_w = math.floor((cw - 10) / 2);
    local card_h = 58;
    local cards = zone_cards(zone);
    for i, card in ipairs(cards) do
        local file = card.file;
        local clicked, playing = track_card(ctx, '##zm_card' .. i, card_w, card_h,
            card.label, file, nil, file, card.missing);
        if (clicked) then
            if (playing) then
                jb.toggle_pause();
            else
                local queue = zone_queue(ctx, catalog, zone.id);
                jb.play_queue(queue, queue_index(queue, file));
            end
        end
        if (i % 2 == 1 and i < #cards) then imgui.SameLine(0, 10); else imgui.Dummy({ 0, 4 }); end
    end

    imgui.Dummy({ 0, 6 });
    if (zone.game_played) then
        draw_note(dl, zone.note or 'The game plays this zone\'s music from the cover DATs.', cw);
    elseif (not master_on) then
        draw_note(dl, 'ZoneMusic is switched off everywhere, so the game plays its own music. Use the switch at the top of the window to turn it back on. You can still preview the covers above.', cw);
    elseif (not zone.active_expansion) then
        draw_note(dl, 'The addon is not switched on for this area yet, so the game plays its own music here. You can still preview the covers above.', cw);
    elseif (not on) then
        draw_note(dl, string.format('The addon is off here. The game plays its own music in %s. You can still preview the covers above.', zone.name), cw);
    end
    imgui.Dummy({ 0, BOTTOM_GAP });
    end_child();
end

local function draw_zones_tab(ctx, catalog, body_w, body_h)
    local gs = ctx.gui_state;
    if (gs.ui_zone == nil) then
        local here = ctx.canonical_zone(ctx.current_zone());
        local here_zone = find_zone(catalog, here);
        gs.ui_zone = here_zone and here or (catalog.zones[1] and catalog.zones[1].id);
        -- First open: expand only the expansion you are standing in.
        local open_exp = here_zone and here_zone.expansion or (catalog.zones[1] and catalog.zones[1].expansion);
        for _, zone in ipairs(catalog.zones) do
            gs.ui_collapsed[zone.expansion] = (zone.expansion ~= open_exp);
        end
    end
    -- When the queue moves on to another zone, bring its detail pane along.
    local jb = ctx.jukebox;
    if (jb.active and jb.file ~= gs.ui_last_file) then
        gs.ui_last_file = jb.file;
        local item = jb.queue and jb.queue[jb.index];
        if (item ~= nil and item.zone ~= nil) then gs.ui_zone = item.zone; end
    end
    local x, y = imgui.GetCursorScreenPos();
    draw_zone_list(ctx, catalog, body_h);
    imgui.SetCursorScreenPos({ x + LIST_W, y });
    draw_zone_detail(ctx, catalog, body_w - LIST_W, body_h);
    imgui.GetWindowDrawList():AddLine({ x + LIST_W, y }, { x + LIST_W, y + body_h }, u32(C.gold, 0.25), 1);
end

------------------------------------------------------------
-- Bosses / Events / Cutscenes tabs (flat track grids)
------------------------------------------------------------
local TAB_COPY = {
    [1] = { 'Boss themes', 'Play when one of these monsters is engaged. Notorious monsters without their own theme share one.' },
    [2] = { 'Event music', 'Low HP, fishing bites, the Mog House and chocobo riding.' },
    [3] = { 'Cutscenes & menus', 'Scene, title screen and menu music. Tracks that are also a zone theme are listed under Zones instead.' },
};

local function draw_track_grid(ctx, list, extra, w, h, tab)
    local jb = ctx.jukebox;
    begin_child('##zm_grid' .. tab, w, h, { 22, 18 });
    local dl = imgui.GetWindowDrawList();
    local cw = imgui.GetContentRegionAvail();
    local copy = TAB_COPY[tab];
    local x, y = imgui.GetCursorScreenPos();
    text_at(dl, x, y, u32(C.title), copy[1], font_size() * 1.5);
    text_at(dl, x, y + font_size() * 1.5 + 6, u32(C.muted), copy[2]);
    imgui.SetCursorScreenPos({ x, y + font_size() * 2.5 + 20 });

    local function grid(items, prefix)
        local card_w = math.floor((cw - 10) / 2);
        local col = 0;
        local last_group = nil;
        for i, item in ipairs(items) do
            -- Grouped lists (cutscenes) get a section rule per group, and
            -- each group starts its own row pair.
            if (item.group_title ~= nil and item.group ~= last_group) then
                last_group = item.group;
                col = 0;
                local ex, ey = imgui.GetCursorScreenPos();
                imgui.Dummy({ cw, 28 });
                section_rule(dl, ex, ey + 12, cw, item.group_title);
            end
            local clicked, playing = track_card(ctx, '##' .. prefix .. i, card_w, 54,
                nil, item.label, item.sub, item.file);
            if (clicked) then
                if (playing) then
                    jb.toggle_pause();
                else
                    local queue = {};
                    for _, entry in ipairs(items) do
                        table.insert(queue, { file = entry.file, label = entry.label });
                    end
                    jb.play_queue(queue, i);
                end
            end
            col = col + 1;
            local nxt = items[i + 1];
            local same_row_next = (nxt ~= nil and nxt.group == item.group);
            if (col % 2 == 1 and same_row_next) then imgui.SameLine(0, 10); else imgui.Dummy({ 0, 4 }); end
        end
    end

    if (#list == 0) then
        imgui.TextColored(C.muted, 'No tracks of this kind in the sounds folder.');
    else
        grid(list, 'zm_g' .. tab .. '_');
    end
    if (extra ~= nil and #extra > 0) then
        imgui.Dummy({ 0, 8 });
        local ex, ey = imgui.GetCursorScreenPos();
        imgui.Dummy({ cw, 22 });
        section_rule(dl, ex, ey + 6, cw, 'Other files');
        grid(extra, 'zm_x' .. tab .. '_');
    end
    imgui.Dummy({ 0, BOTTOM_GAP });
    end_child();
end

------------------------------------------------------------
-- Settings tab (hosts the classic pages)
------------------------------------------------------------
local function nav_row(id, label, selected, w)
    local x, y = imgui.GetCursorScreenPos();
    local clicked = imgui.InvisibleButton(id, { w, 26 });
    local hovered = imgui.IsItemHovered();
    local dl = imgui.GetWindowDrawList();
    if (selected) then
        dl:AddRectFilledMultiColor({ x, y }, { x + w, y + 26 },
            u32(C.cyan, 0.25), u32(C.cyan, 0.0), u32(C.cyan, 0.0), u32(C.cyan, 0.25));
        dl:AddRectFilled({ x, y }, { x + 2, y + 26 }, u32(C.cyan));
    elseif (hovered) then
        dl:AddRectFilled({ x, y }, { x + w, y + 26 }, u32(C.cyan, 0.08));
    end
    text_at(dl, x + 12, y + 6, selected and u32({ 1, 1, 1, 1 }) or u32(C.text), label);
    return clicked;
end

local function flat_button(id, label, w, color)
    local x, y = imgui.GetCursorScreenPos();
    local clicked = imgui.InvisibleButton(id, { w, 26 });
    local hovered = imgui.IsItemHovered();
    local dl = imgui.GetWindowDrawList();
    dl:AddRectFilled({ x, y }, { x + w, y + 26 }, u32(color, hovered and 0.28 or 0.14), 2);
    dl:AddRect({ x, y }, { x + w, y + 26 }, u32(color, hovered and 0.9 or 0.5), 2);
    text_at(dl, x + (w - text_width(label)) / 2, y + 6, u32(C.ivory), label);
    return clicked;
end

-- "!!" caution shown to players running the zonemusicDATS pivot overlay.
-- Those covers are baked into the game's music files, so switching the
-- addon off cannot silence them; only removing the overlay can.
local function dat_caution(dl, w)
    local x, y = imgui.GetCursorScreenPos();
    local wx = imgui.GetWindowPos();
    dl:AddCircleFilled({ x + 11, y + 12 }, 10, u32(C.coral, 0.9), 20);
    text_at(dl, x + 11 - text_width('!!') / 2, y + 5, u32(INK), '!!');
    imgui.SetCursorScreenPos({ x + 26, y + 2 });
    imgui.PushTextWrapPos(x - wx + w);
    imgui.PushStyleColor(ImGuiCol_Text, C.coral);
    imgui.TextWrapped('Cover DATs installed');
    imgui.PopStyleColor(1);
    imgui.PopTextWrapPos();
    local _, ty = imgui.GetCursorScreenPos();
    imgui.SetCursorScreenPos({ x, ty + 2 });
    imgui.PushTextWrapPos(x - wx + w);
    imgui.PushStyleColor(ImGuiCol_Text, C.muted);
    imgui.TextWrapped('Cutscene, menu, death and chocobo covers live in the game\'s own music files (zonemusicDATS in /pivot), so they keep playing while ZoneMusic is off. For the original soundtrack everywhere, remove that overlay in /pivot and restart the game.');
    imgui.PopStyleColor(1);
    imgui.PopTextWrapPos();
    local _, y2 = imgui.GetCursorScreenPos();
    dl:AddRect({ x - 4, y - 4 }, { x + w + 2, y2 + 4 }, u32(C.coral, 0.45), 3);
    imgui.SetCursorScreenPos({ x, y2 + 12 });
end

-- Health page: the /zm doctor report, readable in the window. Runs the
-- check the first time the page opens; "Run check again" refreshes it.
local HEALTH_MARK = {
    ok   = { 'OK',   C.cyan },
    info = { 'i',    C.muted },
    warn = { '!!',   C.gold },
    fail = { 'X',    C.coral },
};

local function draw_health(ctx, w)
    local dl = imgui.GetWindowDrawList();
    local report = ctx.doctor_report and ctx.doctor_report() or nil;
    if (report == nil and ctx.run_doctor ~= nil) then
        report = ctx.run_doctor();
    end

    local x, y = imgui.GetCursorScreenPos();
    text_at(dl, x, y, u32(C.title), 'Health check', font_size() * 1.5);
    local summary;
    if (report == nil) then
        summary = 'The health check file (zm_doctor.lua) is missing. Reinstall the addon.';
    elseif (report.failures + report.warnings == 0) then
        summary = 'Everything looks good.';
    else
        summary = string.format('%d problem(s) and %d warning(s). Each one says how to fix it.',
            report.failures, report.warnings);
    end
    text_at(dl, x, y + font_size() * 1.5 + 6, u32(C.muted), summary);
    imgui.SetCursorScreenPos({ x + w - 150, y });
    if (flat_button('##zm_rerun', 'Run check again', 150, C.cyan)) then
        if (ctx.run_doctor ~= nil) then report = ctx.run_doctor(); end
    end
    imgui.SetCursorScreenPos({ x, y + font_size() * 2.5 + 22 });
    if (report == nil) then return; end

    -- Problems first, then warnings, info and passes.
    local order = { fail = 1, warn = 2, info = 3, ok = 4 };
    local items = {};
    for i, item in ipairs(report.items) do items[#items + 1] = { item = item, i = i }; end
    table.sort(items, function(a, b)
        local oa, ob = order[a.item.level] or 5, order[b.item.level] or 5;
        if (oa ~= ob) then return oa < ob; end
        return a.i < b.i;
    end);

    local wx = imgui.GetWindowPos();
    for _, entry in ipairs(items) do
        local item = entry.item;
        local mark = HEALTH_MARK[item.level] or HEALTH_MARK.info;
        local ix, iy = imgui.GetCursorScreenPos();
        dl:AddCircleFilled({ ix + 11, iy + 9 }, 10, u32(mark[2], item.level == 'ok' and 0.25 or 0.9), 20);
        text_at(dl, ix + 11 - text_width(mark[1], font_size() * 0.8) / 2, iy + 3,
            item.level == 'ok' and u32(C.cyan) or u32(INK), mark[1], font_size() * 0.8);
        imgui.SetCursorScreenPos({ ix + 30, iy + 1 });
        imgui.PushTextWrapPos(ix - wx + w);
        imgui.PushStyleColor(ImGuiCol_Text, item.level == 'ok' and C.text or C.ivory);
        imgui.TextWrapped(item.title);
        imgui.PopStyleColor(1);
        if (item.detail ~= nil and item.level ~= 'ok') then
            imgui.SetCursorScreenPos({ ix + 30, select(2, imgui.GetCursorScreenPos()) });
            imgui.PushStyleColor(ImGuiCol_Text, C.muted);
            imgui.TextWrapped(item.detail);
            imgui.PopStyleColor(1);
        end
        if (item.fix ~= nil and item.level ~= 'ok') then
            imgui.SetCursorScreenPos({ ix + 30, select(2, imgui.GetCursorScreenPos()) });
            imgui.PushStyleColor(ImGuiCol_Text, C.cyan);
            imgui.TextWrapped('Fix: ' .. item.fix);
            imgui.PopStyleColor(1);
        end
        imgui.PopTextWrapPos();
        local _, ny = imgui.GetCursorScreenPos();
        imgui.SetCursorScreenPos({ ix, ny + 8 });
    end
    local fx, fy = imgui.GetCursorScreenPos();
    imgui.Dummy({ w, 18 });
    text_at(dl, fx, fy + 2, u32(C.faint), 'Full report saved to logs\\zonemusic_report.txt. Send it along when asking for help.', font_size() * 0.85);
end

local function draw_settings_tab(ctx, w, h)
    local gs = ctx.gui_state;
    local x, y = imgui.GetCursorScreenPos();

    begin_child('##zm_nav', NAV_W, h, { 10, 12 });
    local nw = imgui.GetContentRegionAvail();
    local dl = imgui.GetWindowDrawList();
    local sx, sy = imgui.GetCursorScreenPos();
    imgui.Dummy({ nw, 22 });
    section_rule(dl, sx + 2, sy + 6, nw - 2, 'Settings');
    for i, label in ipairs(SETTINGS_PAGES) do
        if (nav_row('##zm_page' .. i, label, gs.ui_page == i - 1, nw)) then
            gs.ui_page = i - 1;
        end
    end
    imgui.Dummy({ 0, 12 });
    local lx, ly = imgui.GetCursorScreenPos();
    imgui.Dummy({ nw, 22 });
    section_rule(dl, lx + 2, ly + 6, nw - 2, 'ZoneMusic');
    local enabled = ctx.live().enabled;
    local rx, ry = imgui.GetCursorScreenPos();
    if (switch('##zm_master_nav', enabled)) then
        ctx.set_addon_enabled(not enabled);
    end
    tooltip(enabled and 'Turn ZoneMusic off: the game plays its own music everywhere'
        or 'Turn ZoneMusic back on');
    text_at(dl, rx + 48, ry + 3, enabled and u32(C.text) or u32(C.coral),
        enabled and 'On' or 'Off (game music)');
    imgui.Dummy({ 0, 2 });
    local cx, cy = imgui.GetCursorScreenPos();
    imgui.Dummy({ nw, 16 });
    text_at(dl, cx, cy, u32(C.faint), 'Saved for this character', font_size() * 0.8);
    imgui.Dummy({ 0, 4 });
    if (ctx.dat_overlay()) then
        dat_caution(dl, nw);
    end
    if (flat_button('##zm_save', 'Save settings', nw, C.gold)) then ctx.save_settings(); end
    end_child();

    imgui.SetCursorScreenPos({ x + NAV_W, y });
    begin_child('##zm_page_body', w - NAV_W, h, { 22, 16 });
    local cw = imgui.GetContentRegionAvail();
    if (gs.ui_page == HEALTH_PAGE) then
        draw_health(ctx, cw);
    else
        ctx.render_settings_page(gs.ui_page or 0, cw);
    end
    imgui.Dummy({ 0, BOTTOM_GAP });
    end_child();
    imgui.GetWindowDrawList():AddLine({ x + NAV_W, y }, { x + NAV_W, y + h }, u32(C.gold, 0.25), 1);
end

------------------------------------------------------------
-- Footer (now playing, transport, seek bar, volume)
------------------------------------------------------------
local MODE_TEXT = {
    once       = { 'ONCE', 'Play this track once, then go back to live music' },
    ['repeat'] = { 'LOOP', 'Repeat this track' },
    continue   = { 'AUTO', 'Keep playing through the list' },
};


-- Round transport button centered on (cx, cy). Returns true when clicked.
local function round_button(id, kind, cx, cy, r, enabled, primary, tip)
    imgui.SetCursorScreenPos({ cx - r, cy - r });
    local clicked = imgui.InvisibleButton(id, { r * 2, r * 2 });
    local hovered = enabled and imgui.IsItemHovered();
    local held = enabled and imgui.IsItemActive();
    local dl = imgui.GetWindowDrawList();
    local a = enabled and 1.0 or 0.35;
    if (primary) then
        dl:AddCircleFilled({ cx, cy }, r, u32(C.gold, held and 0.7 or (hovered and 1.0 or 0.85 * a)), 32);
        glyph(dl, kind, cx, cy, r, u32(INK));
    else
        if (hovered) then
            dl:AddCircleFilled({ cx, cy }, r, u32(C.cyan, held and 0.28 or 0.14), 24);
        end
        dl:AddCircle({ cx, cy }, r, u32(C.gold, 0.6 * a), 24, 1.0);
        glyph(dl, kind, cx, cy, r, u32(C.ivory, a));
    end
    if (enabled) then tooltip(tip); end
    return clicked and enabled;
end

-- Labelled "Back to live" pill: ends the preview and brings the zone
-- theme straight back. Spelled out because a bare stop square did not read
-- as "return to live music". Dimmed (and inert) when nothing is previewing.
local function live_button(x, cy, enabled)
    local size = font_size() * 0.8;
    local label = 'BACK TO LIVE';
    local w = text_width(label, size) + 32;
    local h = 24;
    imgui.SetCursorScreenPos({ x, cy - h / 2 });
    local clicked = imgui.InvisibleButton('##zm_live', { w, h });
    local hovered = enabled and imgui.IsItemHovered();
    local held = enabled and imgui.IsItemActive();
    local a = enabled and 1.0 or 0.35;
    local dl = imgui.GetWindowDrawList();
    dl:AddRectFilled({ x, cy - h / 2 }, { x + w, cy + h / 2 },
        u32(C.gold, held and 0.35 or (hovered and 0.22 or 0.08 * a)), h / 2);
    dl:AddRect({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(C.gold, (hovered and 1.0 or 0.6) * a), h / 2);
    glyph(dl, 'stop', x + 13, cy, 12, u32(C.ivory, a));
    text_at(dl, x + 23, cy - size / 2, u32(C.ivory, a), label, size);
    if (enabled) then tooltip('Stop the preview and play this zone\'s music again'); end
    return clicked and enabled;
end

-- ONCE / LOOP / AUTO pill; click cycles. Draws right-aligned to x_right.
local function mode_pill(jb, x_right, cy)
    local size = font_size() * 0.8;
    local w = text_width('AUTO', size) + 18;
    local h = 20;
    local x = x_right - w;
    imgui.SetCursorScreenPos({ x, cy - h / 2 });
    if (imgui.InvisibleButton('##zm_mode', { w, h })) then
        jb.cycle_mode();
    end
    local hovered = imgui.IsItemHovered();
    local m = MODE_TEXT[jb.mode] or MODE_TEXT.continue;
    tooltip(m[2] .. ' (click to change)');
    local dl = imgui.GetWindowDrawList();
    dl:AddRectFilled({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(C.cyan, hovered and 0.16 or 0.06), h / 2);
    dl:AddRect({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(C.cyan, hovered and 0.9 or 0.5), h / 2);
    text_at(dl, x + (w - text_width(m[1], size)) / 2, cy - size / 2, u32(C.cyan), m[1], size);
end

-- Click or drag anywhere on the bar to jump. The jump happens on release,
-- so dragging previews the time without hammering MCI with seeks.
local function seek_bar(ctx, x1, x2, y)
    local jb = ctx.jukebox;
    local gs = ctx.gui_state;
    local dl = imgui.GetWindowDrawList();
    local w = x2 - x1;
    if (w < 20) then return; end
    local length = jb.length_ms or 0;

    imgui.SetCursorScreenPos({ x1, y - 9 });
    imgui.InvisibleButton('##zm_seek', { w, 18 });
    local hovered = imgui.IsItemHovered();
    local active = imgui.IsItemActive();
    local mx = imgui.GetMousePos();
    local mouse_frac = math.max(0, math.min(1, (mx - x1) / w));
    if (active) then gs.ui_seek_frac = mouse_frac; end
    if (imgui.IsItemDeactivated() and gs.ui_seek_frac ~= nil) then
        jb.seek(gs.ui_seek_frac * length);
        gs.ui_seek_frac = nil;
    end

    local pos = jb.position_ms();
    local frac = gs.ui_seek_frac or ((length > 0) and math.min(1, pos / length) or 0);
    local th = (hovered or active) and 6 or 4;
    dl:AddRectFilled({ x1, y - th / 2 }, { x2, y + th / 2 }, u32(C.track), th / 2);
    local fill = x1 + w * frac;
    if (fill > x1 + 1) then
        dl:AddRectFilledMultiColor({ x1, y - th / 2 }, { fill, y + th / 2 },
            u32(C.gold), u32(C.cyan), u32(C.cyan), u32(C.gold));
    end
    if (hovered or active) then
        dl:AddCircleFilled({ fill, y }, 6, u32(C.title), 16);
        if (imgui.SetTooltip ~= nil) then
            imgui.SetTooltip(fmt_time((active and frac or mouse_frac) * length));
        end
    end
    return (gs.ui_seek_frac ~= nil) and (gs.ui_seek_frac * length) or pos;
end

-- Play with nothing queued: start the selected zone's tracks.
local function play_selected_zone(ctx)
    local catalog = ctx.catalog();
    local zone = find_zone(catalog, ctx.gui_state.ui_zone);
    if (zone == nil) then return; end
    local queue = zone_queue(ctx, catalog, zone.id);
    for i, item in ipairs(queue) do
        if (item.zone == zone.id) then
            ctx.jukebox.play_queue(queue, i);
            return;
        end
    end
end

local function draw_footer(ctx, wx, wy, ww, wh)
    local gs = ctx.gui_state;
    local jb = ctx.jukebox;
    local dl = imgui.GetWindowDrawList();
    local fy = wy + wh - FOOTER_H;
    dl:AddRectFilledMultiColor({ wx, fy }, { wx + ww, wy + wh },
        u32(C.gold, 0.0), u32(C.gold, 0.0), u32(C.gold, 0.12), u32(C.gold, 0.12));
    dl:AddLine({ wx, fy }, { wx + ww, fy }, u32(C.gold, 0.4), 1);

    -- Left: what's playing.
    local live = ctx.live();
    local kicker, name, sub, sub_warn;
    if (jb.active) then
        kicker = jb.paused and 'PREVIEW · PAUSED' or 'NOW PREVIEWING';
        name = jb.label;
        local pos = (jb.queue ~= nil and #jb.queue > 1)
            and string.format('Track %d of %d  ·  ', jb.index, #jb.queue) or '';
        if (not ctx.owns_zone(ctx.current_zone())) then
            sub, sub_warn = '!! Game music is playing underneath in this zone', true;
        else
            sub = pos .. 'Live music waits until you go back to live';
        end
    elseif (live.battle_playing and live.battle_track ~= '') then
        kicker, name = 'LIVE · BATTLE', jb.describe(live.battle_track) or live.battle_track;
    elseif ((live.zone_playing or live.zone_paused) and live.zone_track ~= '') then
        kicker = live.zone_paused and 'LIVE · PAUSED' or 'LIVE';
        name = jb.describe(live.zone_track) or live.zone_track;
    elseif (not live.enabled) then
        kicker, name = 'ZONEMUSIC OFF', 'Game music';
    else
        kicker, name = 'LIVE', live.state or '';
    end

    local pad = 18;
    local left_w = math.floor(math.min(300, ww * 0.28));
    local lx = wx + pad;
    dl:PushClipRect({ lx, fy }, { lx + left_w - 16, fy + FOOTER_H }, true);
    text_at(dl, lx, fy + 16, u32(C.gold), kicker, font_size() * 0.8);
    text_at(dl, lx, fy + 33, u32(C.title), name or '');
    if (sub ~= nil) then
        text_at(dl, lx, fy + 55, sub_warn and u32(C.coral) or u32(C.faint), sub, font_size() * 0.8);
    end
    dl:PopClipRect();

    -- Right: volume.
    local vol_w = 130;
    local vx = wx + ww - pad - vol_w;
    local vcy = fy + FOOTER_H / 2;
    text_at(dl, vx - 32, vcy - 6, u32(C.muted), 'VOL', font_size() * 0.85);
    imgui.SetCursorScreenPos({ vx, vcy - 11 });
    imgui.SetNextItemWidth(vol_w);
    if (imgui.SliderInt('##zm_vol', gs.volume, 0, 100, '%d%%')) then
        ctx.set_volume_percent(gs.volume[1]);
    end

    -- Center: transport row over the seek row.
    local cx1 = lx + left_w;
    local cx2 = vx - 32 - 24;
    local mid = math.floor((cx1 + cx2) / 2);
    local ty = fy + 30;
    local has_queue = (jb.queue ~= nil and #jb.queue > 0);
    local can_skip = has_queue and #jb.queue > 1;

    mode_pill(jb, mid - 96 - 16, ty);
    if (round_button('##zm_prev', 'prev', mid - 50, ty, 13, can_skip or jb.active, false, 'Previous (restarts the track after 3s)')) then
        jb.step(-1);
    end
    local play_kind = (jb.active and not jb.paused) and 'pause' or 'play';
    if (round_button('##zm_play', play_kind, mid, ty, 17, true, true, play_kind == 'pause' and 'Pause' or 'Play')) then
        if (jb.active or has_queue) then
            jb.toggle_pause();
        else
            play_selected_zone(ctx);
        end
    end
    if (round_button('##zm_next', 'next', mid + 50, ty, 13, can_skip, false, 'Next')) then
        jb.step(1);
    end
    if (live_button(mid + 72, ty, jb.active)) then
        jb.return_live();
    end

    local sy = fy + 64;
    if (jb.active) then
        local total = fmt_time(jb.length_ms);
        local tw = text_width(total);
        local shown = seek_bar(ctx, cx1 + tw + 12, cx2 - tw - 12, sy);
        local elapsed = fmt_time(shown or jb.position_ms());
        text_at(dl, cx1 + tw - text_width(elapsed), sy - 7, u32(C.muted), elapsed);
        text_at(dl, cx2 - tw, sy - 7, u32(C.muted), total);
    else
        gs.ui_seek_frac = nil;
        local hint = 'Pick a track above, or press play to hear the selected zone';
        text_at(dl, mid - text_width(hint, font_size() * 0.85) / 2, sy - 6, u32(C.faint), hint, font_size() * 0.85);
    end
end

------------------------------------------------------------
-- Theme push/pop
------------------------------------------------------------
local THEME_COLORS = {
    { 'ImGuiCol_WindowBg',        C.window },
    { 'ImGuiCol_ChildBg',         { 0, 0, 0, 0 } },
    { 'ImGuiCol_Border',          { 0.788, 0.643, 0.361, 0.55 } },
    { 'ImGuiCol_Text',            C.ivory },
    { 'ImGuiCol_TextDisabled',    C.muted },
    { 'ImGuiCol_FrameBg',         C.frame },
    { 'ImGuiCol_FrameBgHovered',  { 0.435, 0.765, 0.875, 0.12 } },
    { 'ImGuiCol_FrameBgActive',   { 0.435, 0.765, 0.875, 0.20 } },
    { 'ImGuiCol_Button',          { 0.435, 0.765, 0.875, 0.14 } },
    { 'ImGuiCol_ButtonHovered',   { 0.435, 0.765, 0.875, 0.28 } },
    { 'ImGuiCol_ButtonActive',    { 0.435, 0.765, 0.875, 0.40 } },
    { 'ImGuiCol_CheckMark',       C.cyan },
    { 'ImGuiCol_SliderGrab',      C.gold },
    { 'ImGuiCol_SliderGrabActive', C.title },
    { 'ImGuiCol_Header',          { 0.435, 0.765, 0.875, 0.18 } },
    { 'ImGuiCol_HeaderHovered',   { 0.435, 0.765, 0.875, 0.28 } },
    { 'ImGuiCol_Separator',       { 0.788, 0.643, 0.361, 0.30 } },
    { 'ImGuiCol_ScrollbarBg',     { 0, 0, 0, 0 } },
    { 'ImGuiCol_ScrollbarGrab',   { 0.788, 0.643, 0.361, 0.30 } },
};
local THEME_VARS = {
    { 'ImGuiStyleVar_WindowPadding',  { 0, 0 } },
    { 'ImGuiStyleVar_WindowRounding', 6 },
    { 'ImGuiStyleVar_ChildRounding',  0 },
    { 'ImGuiStyleVar_FrameRounding',  3 },
    { 'ImGuiStyleVar_FramePadding',   { 8, 5 } },
    { 'ImGuiStyleVar_ItemSpacing',    { 8, 6 } },
    { 'ImGuiStyleVar_ScrollbarSize',  8 },
};

local function push_theme()
    local colors, vars = 0, 0;
    for _, entry in ipairs(THEME_COLORS) do
        local idx = _G[entry[1]];
        if (idx ~= nil) then
            imgui.PushStyleColor(idx, entry[2]);
            colors = colors + 1;
        end
    end
    for _, entry in ipairs(THEME_VARS) do
        local idx = _G[entry[1]];
        if (idx ~= nil) then
            imgui.PushStyleVar(idx, entry[2]);
            vars = vars + 1;
        end
    end
    return colors, vars;
end

------------------------------------------------------------
-- Entry point
------------------------------------------------------------
local function draw_window(ctx)
    local gs = ctx.gui_state;
    local wx, wy = imgui.GetWindowPos();
    local ww, wh = imgui.GetWindowSize();

    draw_header(ctx, wx, wy, ww);

    local body_y = wy + HEADER_H + 1;
    local body_h = wh - HEADER_H - FOOTER_H - 2;
    imgui.SetCursorScreenPos({ wx, body_y });

    local tab = gs.ui_tab or 0;
    local catalog_now = ctx.catalog();
    if (tab == REVIEW_TAB and #(catalog_now.review or {}) == 0) then
        tab = 0;
        gs.ui_tab = 0;
    end
    if (tab == 4) then
        draw_settings_tab(ctx, ww, body_h);
    else
        local catalog = ctx.catalog();
        if (tab == 0) then
            draw_zones_tab(ctx, catalog, ww, body_h);
        elseif (tab == 1) then
            draw_track_grid(ctx, catalog.bosses, nil, ww, body_h, 1);
        elseif (tab == 2) then
            draw_track_grid(ctx, catalog.events, catalog.other, ww, body_h, 2);
        elseif (tab == REVIEW_TAB) then
            TAB_COPY[REVIEW_TAB] = { catalog.review_title or 'Review', catalog.review_desc or '' };
            draw_track_grid(ctx, catalog.review, nil, ww, body_h, REVIEW_TAB);
        else
            draw_track_grid(ctx, catalog.scenes, nil, ww, body_h, 3);
        end
    end

    draw_footer(ctx, wx, wy, ww, wh);
end

function zm_ui.render(ctx)
    local gs = ctx.gui_state;
    if (gs.ui_tab == nil) then gs.ui_tab = 0; end
    if (gs.ui_page == nil) then gs.ui_page = 0; end
    if (gs.ui_search == nil) then gs.ui_search = { '' }; end
    if (gs.ui_collapsed == nil) then gs.ui_collapsed = {}; end

    local colors, vars = push_theme();
    imgui.SetNextWindowSize({ 900, 560 }, ImGuiCond_FirstUseEver or ImGuiCond_Once);
    if (imgui.SetNextWindowSizeConstraints ~= nil) then
        imgui.SetNextWindowSizeConstraints({ 780, 460 }, { 4000, 4000 });
    end
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse or 0);

    open_children = 0;
    if (imgui.Begin('ZoneMusic##zm_crystal', gs.is_open, flags)) then
        local ok, err = pcall(draw_window, ctx);
        if (not ok) then
            -- Unwind anything the failed frame left open so ImGui stays sane.
            while (open_children > 0) do
                imgui.EndChild();
                open_children = open_children - 1;
            end
            -- The addon logs it and tells the player once; music is unaffected.
            if (ctx.report_error ~= nil) then
                ctx.report_error('window', err);
            elseif (not error_reported) then
                error_reported = true;
                print('[ZoneMusic] UI error: ' .. tostring(err));
            end
        end
    end
    imgui.End();
    imgui.PopStyleVar(vars);
    imgui.PopStyleColor(colors);
end

return zm_ui;
