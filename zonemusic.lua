addon.name      = 'ZoneMusic';
addon.author    = 'MoonRise (Eldorin)';
addon.version   = '2.0.1';
addon.desc      = 'Dynamic Zone Themes and Battle Themes /zm for gui';
addon.link      = '';

require('common');
local chat = require('chat');
local ffi = require('ffi');
local imgui = require('imgui');
local settings = require('settings');

-- The window lives in zm_ui.lua. A missing or broken copy must not take the
-- music down with it, so the require is protected and a bare fallback
-- window explains what happened instead.
local zm_ui = (function()
    local ok, mod = pcall(require, 'zm_ui');
    if (ok and type(mod) == 'table' and mod.render ~= nil) then return mod; end
    local reason = tostring(mod);
    return {
        load_error = reason,
        render = function(ctx)
            if (imgui.Begin('ZoneMusic##zm_fallback', ctx.gui_state.is_open)) then
                imgui.TextColored({ 1.0, 0.55, 0.45, 1.0 }, 'The ZoneMusic window could not load (zm_ui.lua).');
                imgui.TextWrapped('Music still works. Reinstall the addon so zm_ui.lua sits next to zonemusic.lua, then type /addon reload zonemusic.');
                imgui.TextWrapped('Details: ' .. reason);
            end
            imgui.End();
        end,
    };
end)();

-- Seed math.random ONCE at addon load. Lua 5.1's PRNG starts in a fixed
-- deterministic state per Lua state init; without an explicit seed, every
-- addon reload produces the identical sequence. The previous seed call
-- lived inside scan_battle_tracks() which is gated by the random-mode
-- feature flag, so users who never enabled random mode never seeded the
-- PRNG, and the zone coin flip's math.random() call returned the same
-- bias-laden initial sequence every reload (observed: 10 _party in a row).
--
-- Use os.time() XOR'd with the high bits of os.clock() in microseconds
-- to ensure two reloads within the same wall-clock second still get
-- distinct seeds. Then warm up the PRNG by discarding the first few
-- values, which on Lua 5.1 are notoriously poorly distributed.
math.randomseed(os.time() + math.floor((os.clock() * 1000000) % 2147483647));
for _ = 1, 10 do math.random(); end

-- Get Vana'diel time calculated from Earth time
local function get_vana_hour()
    -- Standard FFXI epoch: Jan 1, 2002 00:00:00 JST (UTC+9)
    -- This is 1009810800 in Unix time
    local FFXI_EPOCH = 1009810800;
    local earth_seconds = os.time();
    
    -- Vana'diel time runs 25x faster than Earth time
    local vana_elapsed = (earth_seconds - FFXI_EPOCH) * 25;
    local vana_day_seconds = vana_elapsed % 86400;
    local vana_hour = math.floor(vana_day_seconds / 3600);
    
    return vana_hour; -- 0-23
end

-- 1. Configuration
local default_settings = T{
    enabled = true,
    low_hp_threshold = 25,
    battle_delay = 3.0,  -- 3 seconds default for better mob chaining
    idle_replay_delay = 0, -- Seconds of silence between completed idle-theme replays.
    
    enable_battle = true,
    enable_zone = true,   -- Play the addon's idle/zone theme (off = no zone cover)
    enable_idle_replay = true,  -- After a zone theme finishes, wait then replay it (off = continuous loop)
    enable_nm = false,
    enable_lowhp = true,
    enable_fishing = true,  -- Play fishing music when "!" or "!!!" bite messages appear
    enable_moghouse = true, -- Play moghouse cover inside a Mog House (zone-in flag), native music126 silenced
    enable_chocobo = true,  -- Play chocobo music while mounted (Status == 5)
    battle_mode = 0,  -- 0 = Solo and Party (mixed), 1 = Force Solo, 2 = Force Party
    random_battle = false,  -- Random battle music from all available tracks
    
    show_debug = false,
    
    volume = 500,
    
    -- Fade settings
    enable_fade = true,
    fade_duration = 1.5,  -- seconds
    
    -- Ducking settings
    enable_duck = true,
    duck_percent = 35,     -- Duck to 35% of normal volume
    duck_fade_speed = 0.3, -- How fast to duck (seconds)
    duck_hold_time = 2.5,  -- How long to stay ducked after last voice
    
    -- Dynamic battle music (FFXIV-style: battle music runs silent between fights)
    battle_dynamic = false,
    battle_resume_window = 60,  -- seconds before silent battle track resets to beginning

    -- Per-zone resident BGM ids captured from 0x00A zone packets (persisted
    -- so addon reloads don't lose them). Keyed by tostring(zone_id).
    zone_bgm = {},

    -- User-flagged cinematic zones (see is_cinematic_zone). Keyed by
    -- tostring(zone_id) = true. Extended via /zm cinema.
    cinematic_zones = {},
    -- Zones where the player turned the addon off (native music plays).
    -- Keyed by tostring(canonical zone id) = true, so one flag covers a
    -- whole city group. Toggle with /zm zone or the jukebox switch.
    disabled_zones = {},
    -- Pause WAV for 0x034-opened events (cutscene openers) after a short
    -- debounce, everywhere. NPC talks (0x032) never trigger this.
    -- Toggle in-game with /zm eventpause.
    pause_on_event = true,
};

-- Load settings (returns live settings object)
local music_config = settings.load(default_settings);

-- Jukebox preview state, plus the addon's safety helpers. Kept in one table
-- (more functions are attached further down, once the playback helpers
-- exist) so the main chunk stays under the local-variable limit. While a
-- preview is active the DJ is on hold and live music waits until it ends.
local jukebox = {
    alias = 'zm_preview',
    active = false,
    file = '',          -- catalog filename being previewed
    label = '',         -- display name for the now-playing bar
    length_ms = 0,
    paused_zone = false, -- the preview paused live zone music and owes a resume
    last_vol = -1,      -- set_volume dedupe
    last_poll = 0,
    catalog = nil,      -- built lazily the first time the window opens
    ui = nil,           -- context table handed to zm_ui.render
    errors = {},        -- source -> { count, first, last }, see report_error
    quiet_until = os.clock() + 15,
    settings_repairs = {},
};

-- Repair settings a hand-edited, truncated or very old settings file can
-- break (a string where a number belongs, a volume of 5000, a table that
-- became a number). Returns a list of what was fixed, shown by /zm doctor.
function jukebox.sanitize_settings(cfg)
    local fixed = {};
    local function num(key, lo, hi, default)
        local v = tonumber(cfg[key]);
        if (v == nil) then
            cfg[key] = default;
            table.insert(fixed, string.format('%s was not a number; reset to %s', key, tostring(default)));
        elseif (v < lo or v > hi) then
            cfg[key] = math.max(lo, math.min(hi, v));
            table.insert(fixed, string.format('%s was %s (allowed %s-%s); set to %s', key, tostring(v), tostring(lo), tostring(hi), tostring(cfg[key])));
        else
            cfg[key] = v;
        end
    end
    local function flag(key, default)
        if (type(cfg[key]) ~= 'boolean') then
            cfg[key] = default;
            table.insert(fixed, string.format('%s was not on/off; reset to %s', key, tostring(default)));
        end
    end
    local function list(key)
        if (type(cfg[key]) ~= 'table') then
            cfg[key] = {};
            table.insert(fixed, key .. ' was damaged; cleared');
        end
    end
    num('volume', 0, 1000, 500);
    num('low_hp_threshold', 1, 99, 25);
    num('battle_delay', 0, 10, 3.0);
    num('idle_replay_delay', 0, 3600, 0);
    num('fade_duration', 0.1, 10, 1.5);
    num('duck_percent', 0, 100, 35);
    num('battle_resume_window', 10, 600, 60);
    num('battle_mode', 0, 2, 0);
    for _, key in ipairs({ 'enabled', 'enable_battle', 'enable_lowhp', 'enable_fade', 'enable_duck' }) do
        flag(key, true);
    end
    list('disabled_zones');
    list('zone_bgm');
    list('cinematic_zones');
    return fixed;
end
jukebox.settings_repairs = jukebox.sanitize_settings(music_config);

-- The sounds folder, found through addon.path so a renamed addon folder
-- (zonemusic-main, ZoneMusic (1), ...) keeps working. Falls back to the
-- standard location if the path is not available.
function jukebox.sounds_dir()
    if (jukebox.sounds_cache ~= nil) then return jukebox.sounds_cache; end
    local standard = AshitaCore:GetInstallPath() .. 'addons\\zonemusic\\sounds\\';
    local found = standard;
    if (addon ~= nil and type(addon.path) == 'string' and addon.path ~= '') then
        -- Accept either the folder or the script's own path.
        local base = addon.path:gsub('/', '\\'):gsub('[^\\]+%.lua$', ''):gsub('\\+$', '');
        -- addon.path can arrive as 'C:\Ashita\\addons\...'; collapse the
        -- doubled separator so reports and error messages read cleanly.
        local candidate = (base .. '\\sounds\\'):gsub('\\+', '\\');
        -- Trust it only if it actually holds music; otherwise keep the
        -- standard location.
        if (#jukebox.list_dir(candidate, '*.mp3') + #jukebox.list_dir(candidate, '*.wav') > 0) then
            found = candidate;
        end
    end
    jukebox.sounds_cache = found;
    return found;
end

-- Log an error the first time a part of the addon fails, and tell the player
-- once, instead of failing silently inside a pcall every frame.
function jukebox.report_error(source, err)
    local entry = jukebox.errors[source];
    if (entry == nil) then
        entry = { count = 0, first = tostring(err), announced = false };
        jukebox.errors[source] = entry;
        pcall(function()
            local f = io.open(AshitaCore:GetInstallPath() .. 'logs\\zonemusic_errors.log', 'a');
            if (f ~= nil) then
                f:write(string.format('[%s] ZoneMusic %s | %s | %s\n',
                    os.date('%Y-%m-%d %H:%M:%S'), tostring(addon.version), source, tostring(err)));
                f:close();
            end
        end);
    end
    -- The first seconds after load see half-built game state (no player,
    -- zoning); those land in the log only. Later failures are announced
    -- once per source.
    if (not entry.announced and os.clock() > jukebox.quiet_until) then
        entry.announced = true;
        print(chat.header('ZoneMusic'):append(chat.error(string.format(
            'Something went wrong (%s). Music may misbehave. Type /zm doctor for help.', source))));
    end
    entry.count = entry.count + 1;
    entry.last = tostring(err);
end

-- pcall that reports instead of swallowing.
function jukebox.guard(source, fn, ...)
    local ok, err = pcall(fn, ...);
    if (not ok) then jukebox.report_error(source, err); end
    return ok;
end

-- GUI state (initialized after settings load)
local gui_state = {
    is_open = { false },
    enabled = { music_config.enabled },
    low_hp  = { music_config.low_hp_threshold },
    delay   = { math.floor(music_config.battle_delay * 10) },
    idle_replay_delay_min = { (music_config.idle_replay_delay or 0) / 60 }, -- minutes (float); runtime keeps seconds
    
    use_zone = { music_config.enable_zone ~= false },
    use_idle_replay = { music_config.enable_idle_replay ~= false },
    use_battle = { music_config.enable_battle },
    use_nm     = { music_config.enable_nm },
    use_lowhp  = { music_config.enable_lowhp },
    use_fishing = { music_config.enable_fishing ~= false },  -- default true
    use_moghouse = { music_config.enable_moghouse ~= false }, -- default true
    use_chocobo = { music_config.enable_chocobo ~= false },  -- default true
    battle_mode = { music_config.battle_mode or 0 },  -- 0=Solo and Party, 1=Solo, 2=Party
    random_battle = { music_config.random_battle or false },  -- Random battle music
    
    volume  = { math.floor((music_config.volume or 500) / 10) },
    
    -- Fade settings
    use_fade = { music_config.enable_fade ~= false },  -- default true
    fade_dur = { math.floor((music_config.fade_duration or 1.5) * 10) },
    
    -- Ducking settings
    use_duck = { music_config.enable_duck ~= false },
    duck_pct = { music_config.duck_percent or 35 },
    
    -- Dynamic battle
    battle_dynamic = { music_config.battle_dynamic or false },
    battle_resume_window = { music_config.battle_resume_window or 60 },
};

-- Ducking state
local duck_signal_file = string.format('%saddons\\voice_duck_signal.txt', AshitaCore:GetInstallPath());
local duck_current_vol = 1.0;  -- Multiplier: 1.0 = full, 0.35 = ducked
local duck_target_vol = 1.0;
local last_duck_check = 0;
local last_voice_time = 0;
local last_duck_update = 0;  -- For real dt calculation in update_ducking

-- Register for settings updates (character change, etc.)
settings.register('settings', 'zonemusic_settings_update', function(new_settings)
    music_config = new_settings;
    jukebox.settings_repairs = jukebox.sanitize_settings(music_config);
    
    -- Update GUI state from loaded settings
    gui_state.enabled[1] = music_config.enabled;
    gui_state.low_hp[1] = music_config.low_hp_threshold;
    gui_state.delay[1] = math.floor(music_config.battle_delay * 10);
    gui_state.idle_replay_delay_min[1] = (music_config.idle_replay_delay or 0) / 60;
    gui_state.use_zone[1] = music_config.enable_zone ~= false;
    gui_state.use_idle_replay[1] = music_config.enable_idle_replay ~= false;
    gui_state.use_battle[1] = music_config.enable_battle;
    gui_state.use_nm[1] = music_config.enable_nm;
    gui_state.use_lowhp[1] = music_config.enable_lowhp;
    gui_state.battle_mode[1] = music_config.battle_mode or 0;
    gui_state.random_battle[1] = music_config.random_battle or false;
    gui_state.volume[1] = math.floor((music_config.volume or 500) / 10);
    gui_state.use_fade[1] = music_config.enable_fade ~= false;
    gui_state.fade_dur[1] = math.floor((music_config.fade_duration or 1.5) * 10);
    gui_state.use_duck[1] = music_config.enable_duck ~= false;
    gui_state.duck_pct[1] = music_config.duck_percent or 35;
    gui_state.battle_dynamic[1] = music_config.battle_dynamic or false;
    gui_state.battle_resume_window[1] = music_config.battle_resume_window or 60;
end);

-- 2. Audio Setup
ffi.cdef[[ 
    uint32_t mciSendStringA(const char* lpstrCommand, char* lpstrReturnString, uint32_t uReturnLength, void* hwndCallback);
]]
local winmm = ffi.load('winmm');

-- Each declaration is wrapped so a clash with another declaration cannot
-- stop the addon from loading; the callers fall back when one is missing.
pcall(ffi.cdef, [[
    uint32_t mciGetErrorStringA(uint32_t error, char* text, uint32_t length);
]]);
pcall(ffi.cdef, [[
    typedef struct { uint32_t lo; uint32_t hi; } ZM_FILETIME;
    typedef struct {
        uint32_t attributes;
        ZM_FILETIME created; ZM_FILETIME accessed; ZM_FILETIME written;
        uint32_t size_high; uint32_t size_low; uint32_t reserved0; uint32_t reserved1;
        char name[260]; char alt_name[14];
    } ZM_FIND_DATA;
    void* FindFirstFileA(const char* pattern, ZM_FIND_DATA* data);
    int FindNextFileA(void* handle, ZM_FIND_DATA* data);
    int FindClose(void* handle);
]]);

-- Audio handles are per process, so an addon that crashed without unloading
-- leaves them open and the next "open ... alias" fails. Close them first.
for _, alias in ipairs({ 'bard_zone', 'bard_battle', 'zm_preview', 'zm_probe' }) do
    winmm.mciSendStringA('close ' .. alias, nil, 0, nil);
end

-- Windows' own text for an MCI error code ("The specified file was not
-- found", ...), so error messages mean something to players.
function jukebox.mci_error(code)
    local ok, text = pcall(function()
        local buf = ffi.new('char[256]');
        if (winmm.mciGetErrorStringA(code, buf, 256) ~= 0) then return ffi.string(buf); end
        return nil;
    end);
    if (ok and text ~= nil and text ~= '') then
        return string.format('%s (MCI %s)', text, tostring(code));
    end
    return 'MCI error ' .. tostring(code);
end

-- Files (or, with want_dirs, sub-folders) in dir matching pattern, as
-- { name, size, mtime } with mtime a comparable number. Uses the Windows
-- file API, which is fast and never flashes a console window; falls back to
-- 'dir /b' (names only) if the FFI declarations are unavailable.
function jukebox.list_dir(dir, pattern, want_dirs)
    local out = {};
    local ok = pcall(function()
        local data = ffi.new('ZM_FIND_DATA[1]');
        local handle = ffi.C.FindFirstFileA(dir .. pattern, data);
        if (tonumber(ffi.cast('intptr_t', handle)) == -1) then return; end
        repeat
            local d = data[0];
            local is_dir = bit.band(d.attributes, 0x10) ~= 0;
            local name = ffi.string(d.name);
            if (is_dir == (want_dirs == true) and name ~= '.' and name ~= '..') then
                table.insert(out, {
                    name = name,
                    size = d.size_high * 4294967296 + d.size_low,
                    mtime = d.written.hi * 4294967296 + d.written.lo,
                });
            end
        until (ffi.C.FindNextFileA(handle, data) == 0);
        ffi.C.FindClose(handle);
    end);
    if (ok) then return out; end
    local handle = io.popen('dir /b ' .. (want_dirs and '/ad ' or '/a-d ') .. '"' .. dir .. pattern .. '" 2>nul');
    if (handle ~= nil) then
        for name in handle:lines() do table.insert(out, { name = name }); end
        handle:close();
    end
    return out;
end

local current_track = "";
local current_state = "Idle"; 
local battle_start_timer = 0;
local battle_end_timer = 0;
local previous_status = 0;
local in_crisis_mode = false;
local previous_zone_id = 0;
local previous_is_night = nil;  -- Track day/night state separately
local zoning_from_city = nil;   -- City group of the zone we left on 0x00B.
                                 -- Lets the logout-debounce path know an
                                 -- in-progress zone is a same-city district
                                 -- hop, so it holds the WAV instead of doing
                                 -- an instant stop (which closes the MCI file
                                 -- and forces a 0:00 restart on arrival).
local last_track_change = 0;
local TRACK_CHANGE_COOLDOWN = 3.0;

-- Fishing state — driven by chat-message detection (text_in handler below).
-- fishing_active flips true on any of the four bite messages, flips false
-- on any of the catch/break/lost messages OR after FISHING_TIMEOUT seconds
-- without a follow-up message (defensive timeout in case the resolution
-- message is missed for any reason — prevents fishing music getting stuck
-- on indefinitely).
--
-- fishing_bite_type is "small" or "large" depending on which bite message
-- matched. Used by get_desired_track to choose between fishing_small.wav
-- and fishing_large.wav.
local fishing_active = false;
local fishing_bite_type = nil;       -- "small" or "large" or nil
local fishing_last_message = 0;      -- os.clock() timestamp of last fishing message
local fishing_status_left = 0;       -- os.clock() when player Status first dropped out of fishing range
local FISHING_TIMEOUT = 60.0;        -- seconds before forcing exit if no resolution seen
-- Status-byte grace increased from 1.0s to 5.0s. The fishing minigame
-- can briefly transition the player's Status byte out of the 56-62 range
-- during the active reel-fight (animation states between arrow inputs).
-- A short grace was triggering false exits when wrong arrows kept the
-- player in a non-FishBite animation state for >1s. 5s comfortably
-- absorbs animation flicker while still catching real exits within
-- a reasonable window. Chat-based resolution is the primary fast path;
-- this is the defensive backup for missed messages.
local FISHING_STATUS_GRACE = 5.0;
local DEBUG_FISHING = false;         -- /zm fishingdebug to toggle

-- Mog House state. moghouse_active is set ONLY from the zone-in packet
-- flag (0x00A offset 0x80 == 1 inside a Mog House; LSB writes 2 elsewhere)
-- via jukebox.mh_enter, and cleared on the next zone-in without it. There
-- is no Moogle proximity scan: Moogles out in the world never trigger it.
local moghouse_active = false;
-- Mog House flag from the most recent zone-in packet: true = inside,
-- false = not, nil = no zone-in seen since load.
local moghouse_zone_flag = nil;
local init_timer = 0;
local init_complete = false; 

-- Logout debounce: distinguish a real logout from a transient zoning gap.
-- During normal zone changes the player entity / party data can briefly
-- look "not in game".
--
-- Two-tier strategy:
--   * If we recently saw an 0x00B (zone-out) packet, we KNOW we're zoning.
--     Hold music for LOGOUT_DEBOUNCE_ZONING (long) before treating it as
--     a true logout. Capital district transitions on slower systems can
--     exceed 10s for the player_ent gap; 30s is a comfortable ceiling.
--   * If no recent 0x00B, fall back to LOGOUT_DEBOUNCE_NORMAL. This catches
--     true logout/disconnect, /shutdown, character switch, etc.
--
-- is_zoning is set true on 0x00B (zone-out) and cleared on 0x00A (zone-in).
-- It does NOT auto-expire — if zone-in never arrives (true crash/disconnect
-- mid-zoning), the long timeout still fires eventually.
local last_seen_logged_in = 0;
local LOGOUT_DEBOUNCE_NORMAL = 3.0;
local LOGOUT_DEBOUNCE_ZONING = 30.0;
local is_zoning = false;

-- Same-city transit window. Opened on 0x00B when leaving a grouped zone,
-- confirmed on 0x00A when the incoming zone is in the same group (cleared
-- otherwise), and closed once the arrival settles. While open, an empty
-- desired track is a loading glitch (player entity, party zone or HP not yet
-- populated) and must not stop the WAV — stopping clears current_zone_track
-- and forces a 0:00 restart. Unlike is_zoning, 0x00A does not clear it.
local city_transit = {
    group = nil,    -- city group being crossed; nil = no transit
    dest = nil,     -- destination zone id from 0x00A (nil until it arrives)
    started = 0,    -- os.clock() of the 0x00B that opened the window
};

-- Death state
local is_dead = false;

-- Random battle music state
local random_battle_tracks_solo = {};   -- Available solo battle tracks
local random_battle_tracks_party = {};  -- Available party battle tracks
local random_tracks_scanned = false;    -- Have we scanned for tracks yet?
local current_random_track = "";        -- Currently selected random track (persists during battle)
local random_track_is_party = false;    -- Is current random track a party track?

-- Zone-specific coin flip state (persists per battle engagement)
local zone_coinflip_suffix = "";        -- "_solo" or "_party" chosen by coin flip
local zone_coinflip_zone = 0;           -- Which zone the flip was for
local zone_coinflip_active = false;     -- Is a flip locked in?

-- Dynamic battle state
local battle_is_silent = false;   -- Battle track playing at vol 0 between fights (dynamic mode)
local battle_silent_time = 0;     -- os.clock() when battle went silent

-- NM scan rate limiting (2303 entity scan is expensive, don't run every tick)
local nm_scan_timer = 0;
local nm_scan_interval = 1.0;  -- seconds between full entity scans
local nm_scan_result = nil;    -- cached filename from last scan, nil = no NM

-- Unique-NM scan (separate cache from generic nm_list scan so the two
-- features can coexist without one stomping the other's cached result).
local unique_nm_scan_timer = 0;
local unique_nm_scan_result = nil;

-- Scan sounds folder for battle tracks
local function scan_battle_tracks()
    if (random_tracks_scanned) then return; end
    
    random_battle_tracks_solo = {};
    random_battle_tracks_party = {};
    
    local sounds_path = jukebox.sounds_dir();
    
    -- Shipping assets are MP3. Keep WAV discovery as a fallback so the
    -- lossless master archive remains usable without a separate Lua build.
    local function scan_extension(extension)
        local handle = io.popen('dir /b "' .. sounds_path .. 'battle_*.' .. extension .. '" 2>nul');
        if (handle == nil) then return 0; end

        local count = 0;
        for filename in handle:lines() do
            if (string.find(filename, "_solo%." .. extension .. "$")) then
                table.insert(random_battle_tracks_solo, filename);
                count = count + 1;
            elseif (string.find(filename, "_party%." .. extension .. "$")) then
                table.insert(random_battle_tracks_party, filename);
                count = count + 1;
            end
        end
        handle:close();
        return count;
    end

    if (scan_extension('mp3') == 0) then
        scan_extension('wav');
    end
    
    random_tracks_scanned = true;
    
    -- Debug output
    if (music_config.show_debug) then
        print(chat.header('ZoneMusic'):append(chat.message(
            string.format('Found %d solo, %d party battle tracks', 
                #random_battle_tracks_solo, #random_battle_tracks_party))));
    end
end

-- Pick a random battle track
local function get_random_battle_track(is_party)
    scan_battle_tracks();
    
    local track_list = is_party and random_battle_tracks_party or random_battle_tracks_solo;
    
    -- If no tracks for this mode, try the other mode
    if (#track_list == 0) then
        track_list = is_party and random_battle_tracks_solo or random_battle_tracks_party;
    end
    
    -- If still no tracks, return nil
    if (#track_list == 0) then
        return nil;
    end
    
    -- Pick random
    local idx = math.random(1, #track_list);
    return track_list[idx];
end

-- Cutscene state tracking (using cleancs.lua approach)
-- StatusServer == 4 means event/cutscene/menu
-- Packet 0x034 = event start, 0x052 type>0 = event end
local was_in_cutscene = false; 
local in_cutscene_from_packet = false;  -- Set by packet 0x034
local cutscene_local_lock_seen = false;  -- Latched true when player Status==4
                                         -- (local event lock) is seen during a
                                         -- StatusServer==4 window. Real cutscenes
                                         -- flash Status==4 at start; NPC dialogue
                                         -- never does. The discriminator that
                                         -- separates the two.

local DEBUG_CUTSCENE = false;  -- /zonemusic cutscene to toggle

-- === CUTSCENE DEBUG FILE LOGGER ===
-- All cutscene-debug output goes to <Ashita>/logs/zonemusic_cutscene.log
-- instead of the chat box. Appends; delete the file to start fresh.
local zm_log_path = nil;
local function zm_debug(msg)
    if (zm_log_path == nil) then
        local ok, p = pcall(function()
            return AshitaCore:GetInstallPath() .. '\\logs\\zonemusic_cutscene.log';
        end);
        zm_log_path = (ok and p) and p or 'zonemusic_cutscene.log';
    end
    local f = io.open(zm_log_path, 'a');
    if (f == nil) then
        -- logs folder missing or path failed: fall back to the game's
        -- working directory so output is never silently lost.
        zm_log_path = 'zonemusic_cutscene.log';
        f = io.open(zm_log_path, 'a');
    end
    if (f ~= nil) then
        f:write(string.format('[%s | clk %.2f] %s\n', os.date('%H:%M:%S'), os.clock(), tostring(msg)));
        f:close();
    end
end


-- === ENGINE-HANDOFF STATE (event-music rebuild) ===
-- Verified by packet capture: FFXI events (NPC talks, cutscenes, doors,
-- menus) carry NO music of their own unless the server explicitly sends a
-- genuine 0x05F music change. Absent that packet, every event runs on the
-- zone's resident BGM — which the addon's WAV already covers. So the WAV
-- now plays through ALL events by default. The ONLY pause trigger is a
-- genuine (non-injected) 0x05F carrying a non-resident track, handled
-- instantly inside packet_in so the WAV is silent before the engine track
-- starts. Identical behavior on retail and LSB-derived servers: the packet
-- either arrives or it doesn't.
local handoff = {
    active = false,      -- true while the engine owns audio (genuine event music seen)
    started = 0,         -- os.clock() when the genuine 0x05F arrived
    saw_event = false,   -- an SS=4 window has been observed since handoff began
    end_grace = 0,       -- os.clock() when SS first left 4 during an active handoff
    pending034 = 0,      -- os.clock() of the last 0x034 event-start (cutscene opener)
};
local EVENT034_PAUSE_DEBOUNCE = 1.5; -- seconds of SS=4 after a 0x034 before pausing

-- === ZMHELPER ENGINE-MUSIC SIGNAL ===
-- The ZMHelper companion plugin hooks the FFXI client's music file layer
-- (fopen_s on .bgw files, the same layer XIPivot hooks) and rewrites a
-- one-line signal file on EVERY music start the engine performs —
-- including client-side cutscene scores that never appear on the wire.
-- Format: 'counter music_id tickcount'. A counter change = engine just
-- started a track. This is ground truth; when the helper is present it
-- supersedes the 0x034 debounce heuristic entirely (no more door dips).
local engine_signal = {
    present = false,     -- helper detected (signal file readable)
    last_counter = nil,  -- last seen counter (nil until baseline read)
    last_poll = 0,       -- os.clock() of last poll
    path = nil,          -- resolved on first poll
    last_resilence = -1e9, -- os.clock() of last covered-track re-silence
    resilence_interval = 2.0, -- min seconds between covered-track re-silences
};
local ENGINE_SIGNAL_POLL = 0.15; -- seconds between signal file reads
local HANDOFF_END_GRACE = 1.0;      -- SS must stay non-4 this long before the
                                    -- handoff ends (chained cutscenes blip SS
                                    -- to 0 for a single tick between scenes —
                                    -- observed in capture at the NPC->cutscene
                                    -- chain point).
local HANDOFF_ORPHAN_TIMEOUT = 4.0; -- genuine 0x05F but no SS=4 window ever
                                    -- opened: false alarm, undo the handoff.

-- === CINEMATIC ZONES ===
-- Mission/BC battleground zones whose cutscenes carry their own score played
-- by the CLIENT-SIDE EVENT SCRIPT — no 0x05F, no packet, nothing on the wire
-- (proven by capture in Sealion's Den: full scored cutscene, zero genuine
-- 0x05F, handoff never armed). Packet detection is structurally blind to
-- script music, so these zones get a hard policy instead: ANY event (0x034
-- or 0x032 arrival, or SS=4) pauses the WAV instantly and hands audio to the
-- engine. Battlegrounds have no casual NPC chatter, so the no-dip guarantee
-- for cities/field zones is untouched. Identical on retail and LSB — the
-- event script is client data.
-- Seed ids come from this addon's own battle config comments (Shrouded Maw,
-- Monarch Linn, Sealion's Den). Extend in-game with /zm cinema (persisted).
local cinematic_zone_seed = {
    [10] = true,  -- The Shrouded Maw (CoP 3-5, Diabolos / Waking Dreams)
    [31] = true,  -- Monarch Linn (CoP 4-2, The Savage / Storms of Fate)
    [32] = true,  -- Sealion's Den (CoP 6-4, One to be Feared / Tenzen)
};
local function is_cinematic_zone(zid)
    if (zid == nil) then return false; end
    if (cinematic_zone_seed[zid]) then return true; end
    local t = music_config.cinematic_zones;
    return (t ~= nil and t[tostring(zid)] == true) or false;
end

local DEBUG_CITY = false;  -- TEMP: city continuity tracing — prints play decision state
local last_debug_log = 0;  -- Throttle debug output
local status4_start_time = 0;  -- When StatusServer=4 started

-- DIAGNOSTIC opcode tracer (cutscene music-channel identification).
-- While DEBUG_CUTSCENE is on and an event is active OR within TRACER_PREROLL
-- seconds of the last event, log each distinct incoming opcode once per event
-- and hex-dump the candidate music/event packets. Purpose: diff a cutscene
-- that switches music against one that stays on resident BGM to find which
-- opcode (if any) carries the cutscene track. Set DEBUG_TRACER false to mute.
local DEBUG_TRACER = true;
local TRACER_PREROLL = 3.0;          -- log this many seconds before/around event
local tracer_seen = {};              -- opcode -> true, reset each event
local tracer_event_active = false;   -- becomes true while tracing one event
local tracer_last_activity = 0;      -- os.clock() of last event-related signal
local TRACER_DUMP_OPCODES = { [0x05F]=true, [0x032]=true, [0x034]=true, [0x033]=true };
local STATUS4_DELAY = 6.5;     -- Seconds in event state before pausing MCI.
                               -- Set high so ordinary NPC dialogue (including
                               -- multi-page click-throughs like Gilgamesh) ends
                               -- before the threshold and never fades the zone
                               -- WAV. Real cutscenes run longer and still pause.
                               -- Cost: up to ~6.5s of zone-WAV overlap at the
                               -- very start of a long cutscene before MCI pauses
                               -- (engine_restore/silence handle the handoff).

-- 0x05F CUTSCENE GATE (the "NPC talk resets the music" fix):
-- A matured StatusServer=4 only counts as a musical cutscene if the engine
-- issued a genuine (non-injected) 0x05F music change during this event
-- window. Real track cutscenes announce their music almost immediately;
-- NPC dialogue never does. Results:
--   * Field NPC talks of ANY length never pause the WAV — no more BGW-cover
--     restart at 0:00 when a click-through runs past the old 6.5s cliff.
--   * Resident-track cutscenes (no 0x05F of their own) keep the WAV playing.
--     The WAV is the cover of the same resident theme, so continuity is
--     preserved instead of restarting the cover from the top.
--   * Track cutscenes hand off at STATUS4_DELAY_WITH_MUSIC (1.5s) instead of
--     6.5s, because the 0x05F itself is the confirmation.
-- Set false to restore the pure-timer behavior.
local CUTSCENE_05F_GATE = false;
local STATUS4_DELAY_WITH_MUSIC = 1.5;
local engine_05f_seen_time = 0;  -- os.clock() of last genuine (non-injected)
                                 -- 0x05F. Compared against the current event's
                                 -- status4_start_time, so stale values from
                                 -- prior events never count.

-- Packet-path debounce: 0x034 (event start) is delayed before being treated
-- as a real cutscene. If 0x052 release arrives within PACKET_EVENT_DELAY,
-- the event is transient (gathering: logging/harvesting/mining/digging/
-- fishing/excavating, brief NPC interactions, item pickups) and music
-- continues uninterrupted. Real cutscenes always exceed this window.
local PACKET_EVENT_DELAY = 1.5;
local packet_event_pending_start = 0;  -- Timestamp of pending 0x034, 0 = none

-- EAGER PAUSE (cutscene .bgw fix):
-- The retail engine plays event/cutscene music via its own runtime 0x05F
-- music-change packet, which this addon never touches. That .bgw is only
-- audible if our MCI WAV is already silent. The old debounced behavior kept
-- the WAV playing for PACKET_EVENT_DELAY+ seconds after the cutscene began,
-- so the WAV masked (or appeared to replace) the engine's cutscene track.
--
-- When eager pause is on, 0x034 (event start) pauses MCI immediately. If a
-- 0x052 release arrives within PACKET_EVENT_DELAY the event was transient
-- (quick NPC menu/dialog) and we resume. Trade-off: a brief MCI dip on quick
-- menu opens. Set false to restore the old debounce-then-pause behavior.
-- DISABLED: eager pause fired on every 0x034 (including short NPC menus that
-- have no engine music), silencing the cover WAV for the dialog duration with
-- no engine track to replace it -> dead silence on normal NPC talk. The trace
-- showed real track cutscenes detect via StatusServer=4 (pkt=false) and never
-- relied on 0x034 anyway, so eager pause only ever fired where it did harm.
-- StatusServer=4 + STATUS4_DELAY now handles cutscene detection exclusively.
local CUTSCENE_EAGER_PAUSE = false;
local eager_pause_start = 0;  -- os.clock() of last eager pause, 0 = none

-- NPC-TALK RESIDENT-BGW GATE (SUPERSEDED — kept disabled):
-- Earlier approach that compared the 0x05F song to the zone's resident BGW.
-- Replaced by the cleaner cutscene_local_lock_seen discriminator (player
-- Status==4 flashes at real cutscene start, never during NPC dialogue), which
-- works even when the engine fires no distinguishing 0x05F and when
-- saved_bgm_ids are nil. Left here (disabled) for reference only.
local NPC_TALK_RESIDENT_GATE = false;
local npc_talk_resident_until = 0;   -- os.clock() deadline; while now < this,
                                     -- the active event is an NPC talk on
                                     -- resident BGM and the WAV is NOT paused.
local NPC_TALK_RESIDENT_HOLD = 1.5;  -- Refreshed on each matching 0x05F.

-- RESIDENT-EVENT PASSTHROUGH (NPC-talk day-stab fix — the working approach):
-- When true, a matured StatusServer=4 event that did NOT announce its own
-- engine track via a real (non-injected) 0x05F is treated as an NPC talk /
-- menu, NOT a cutscene: the WAV keeps playing and the engine is never
-- restored, so the resident day BGW is never exposed (no day stab at night,
-- no 0:00 cover restart). Only genuine packet cutscenes (in_cutscene_from_packet,
-- which carry a track we have no WAV for) pause + engine_restore. This works
-- regardless of whether saved_bgm_ids populated, which is why it fixes both
-- the first-talk-after-zone case and every subsequent talk. Set false to
-- revert to "pause for any matured event."
local RESIDENT_EVENT_PASSTHROUGH = false;

-- CUTSCENE TIMER FALLBACK (seconds): if StatusServer=4 persists this long with
-- no engine 0x05F, treat it as a cutscene and pause. 10s clears virtually all
-- NPC dialogue (nobody sits on an NPC box for 10s) while still catching
-- resident-music cutscenes that announce no track. The deliberate tradeoff:
-- an NPC talk held past 10s in a covered zone gets the resident BGW stab.
local CUTSCENE_TIMER_FALLBACK = 10.0;

-- Fade state
local zone_current_vol = 0;
local zone_target_vol = 0;
local battle_current_vol = 0;
local battle_target_vol = 0;
local zone_fading = false;
local battle_fading = false;
local pending_zone_stop = false;   -- Stop zone after fade out
local pending_battle_stop = false; -- Stop battle after fade out
local battle_fade_override = 0;   -- When > 0, battle fade uses this duration
                                   -- (seconds) instead of music_config.fade_duration.
                                   -- Used for the quick fade on boss-kill cutscenes.
local last_unique_nm_track = "";  -- Filename of the unique-NM theme currently
                                   -- driving battle music ("" = none). Used to
                                   -- detect the boss-kill handoff: NM theme was
                                   -- playing, scan no longer matches → the boss
                                   -- died, not a normal track change.
local battle_kill_grace_until = 0; -- After a boss-kill quick fade, suppress
                                   -- battle-track restarts until this time so
                                   -- lingering engaged-status frames don't slam
                                   -- the generic zone battle theme in.
local BATTLE_KILL_GRACE = 3.0;
local last_fade_time = 0; 

-- Per-alias dedupe for set_volume (see set_volume comment above).
-- Initialize to -1 so the first send always goes through regardless of
-- the actual starting volume value.
local last_sent_zone_vol = -1;
local last_sent_battle_vol = -1;

-- 3. NM Database
-- Source: horizonffxi.wiki/Notorious_Monsters:_Level_Guide
-- Excluded: Dragon's Aery (Fafnir, Nidhogg), Behemoth's Dominion (Behemoth, King Behemoth)
-- Excluded: Sky gods (Kirin, Genbu, Suzaku, Byakko, Seiryu) and their instanced zones
-- Excluded: Al'Taieu Jailers and all instanced Sea/CoP battlefield NMs
-- Those zones use dedicated zone/battle music instead of NM_battle.wav

-- Per-NM unique battle music override map.
-- These NMs live in "silence" zones (no zone BGM) where the player already
-- gets a custom day_*.wav ambient from this addon. When the NM is engaged,
-- we want to swap to that NM's signature track instead of the generic
-- NM_battle.wav OR the zone's battle_*.wav.
--
-- Lookup is by ent.Name (exact string match, same as nm_list). Resolved
-- filename must exist on disk; if missing, we fall through to the rest of
-- the battle-music selection chain (NM_battle.wav -> zone-specific ->
-- default_battle).
--
-- Per-NM custom battle music overrides.
--
-- Each entry can take one of two forms:
--
--   1) SIMPLE (string)  -- single battle track plays whenever NM is engaged
--      ["Mob Name"] = "filename.wav"
--
--   2) PHASED (table)   -- different tracks for different fight phases,
--                          detected by checking which companion entities
--                          are alive alongside the boss.
--      ["Mob Name"] = {
--          phase_companions = { "CompanionName1", "CompanionName2", ... },
--          phase1 = "phase1_track.wav",  -- plays while ANY companion alive
--          phase2 = "phase2_track.wav",  -- plays when NO companions exist
--      }
--
-- Phase detection uses entity presence (not HP%) because some bosses
-- transition via cutscene and entity respawn rather than a continuous
-- HP threshold. See Eald'narche entry for the canonical example.
--
-- Companion-disappear debounce: phase2 is only selected after the
-- "no companions" state persists for PHASE_COMPANION_DEBOUNCE seconds.
-- This avoids a brief Belief flicker between "last companion dies in
-- phase 1" and "phase transition cutscene starts pausing music."
local unique_nm_list = {
    -- Behemoth's Dominion (zone 127) — silence zone, custom ambient day_127
    ["Behemoth"]      = "behemoth_battle.wav",
    ["King Behemoth"] = "king_behemoth_battle.wav",

    -- Dragon's Aery (zone 154) — silence zone, custom ambient day_154
    ["Fafnir"]  = "fafnir_battle.wav",
    ["Nidhogg"] = "nidhogg_battle.wav",

    -- Valley of Sorrows (zone 128) — silence zone, custom ambient day_128
    ["Adamantoise"]   = "adamantoise_battle.wav",
    ["Aspidochelone"] = "aspidochelone_battle.wav",

    -- The Shrouded Maw (zone 10) — CoP mission 3-5 + Waking Dreams quest.
    -- Zone has other fights (ENMs etc); battle_10 handles those as fallback.
    -- Diabolos detection fires uniquely for his fight only.
    ["Diabolos"] = "diabolos_battle.wav",

    -- Sealion's Den (zone 32) — CoP mission 6-4 "One to be Feared".
    -- Gauntlet: Mammet-22 Zeta x5 → Omega → Ultima. Omega and Ultima each
    -- carry their own theme (separate FFXIV leitmotifs); detection switches
    -- when Ultima spawns. Tenzen fight (PM 7-5) shares the zone; battle_32
    -- handles that as fallback.
    ["Omega"] = "omega_battle.wav",
    ["Ultima"] = "ultima_battle.wav",
    -- Tenzen (PM 7-5) — his own theme instead of the battle_32 fallback.
    -- Simple string entry: fires when the "Tenzen" entity is engaged,
    -- identical mechanism to Omega/Ultima above. Requires
    -- tenzen_battle.wav in the sounds folder.
    ["Tenzen"] = "tenzen_battle.wav",

    -- Monarch Linn (zone 31) — CoP mission 4-2 "The Savage" + Storms of Fate
    -- + Wyrmking Descends. All three fights use the Bahamut entity. One theme
    -- covers all encounters. BCNM zone so battle_31 would normally always play;
    -- NM detection here gives an explicit override hook for future phase logic.
    ["Bahamut"] = "bahamut_battle.wav",

    -- Celestial Nexus (zone 181) — Eald'narche is NOT handled here. His phase 1
    -- (BGM 198) and phase 2 (BGM 195) themes play ONLY during this final boss
    -- fight and nowhere else, so the covers are DAT-swapped directly over those
    -- .bgw files and the engine plays them natively with correct phase timing.
    -- Addon detection is intentionally omitted to avoid double-driving the
    -- engine track (which caused the battlefield overlap). Do not re-add.
};

-- Debounce window for phase2 promotion (seconds).
-- Phase2 only fires after companions have been absent this long.
-- Covers the brief gap between "Exoplates die" and "phase transition CS"
-- so we don't flicker to phase2 audio for ~2 seconds before the CS
-- pauses everything anyway.
local PHASE_COMPANION_DEBOUNCE = 3.0;

-- Per-boss state tracking for phased entries.
-- Key: boss name (e.g. "Eald'narche"). Value: timestamp of last frame
-- where any phase_companion was seen alive. 0 = never seen, or reset.
local phase_companion_last_seen = {};

local nm_list = {

    -- === LEVELS 1-9 ===
    ["Bigmouth Billy"]              = true,
    ["Jaggedy-Eared Jack"]          = true,
    ["Stinging Sophie"]             = true,
    ["Bubbly Bernie"]               = true,
    ["Spiny Spipi"]                 = true,
    ["Tom Tit Tat"]                 = true,

    -- === LEVELS 10-19 ===
    ["Leaping Lizzy"]               = true,
    ["Fungus Beetle"]               = true,
    ["Maighdean Uaine"]             = true,
    ["Carnero"]                     = true,
    ["Sharp-Eared Ropipi"]          = true,
    ["Thousandarm Deshglesh"]       = true,
    ["Hundredscar Hajwaj"]          = true,
    ["Bu'Ghi Howlblade"]            = true,
    ["Nunyenunc"]                   = true,
    ["Swamfisk"]                    = true,
    ["Juu Duzu the Whirlwind"]      = true,
    ["Bloody Vrukwuk"]              = true,
    ["Fogweaver Mozzfuzz"]          = true,
    ["Haty"]                        = true,
    ["Bendigeit Vran"]              = true,
    ["Nihniknoovi"]                 = true,
    ["Yara Ma Yha Who"]             = true,
    ["Orcish Wallbreacher"]         = true,
    ["Zi'Ghi Boneeater"]            = true,
    ["Eyy Mon the Ironbreaker"]     = true,
    ["Zhuu Buxu the Silent"]        = true,
    ["Hoo Mjuu the Torrent"]        = true,
    ["Bomb King"]                   = true,
    ["Ashmaker Gotblut"]            = true,
    ["Tumbling Truffle"]            = true,
    ["Stray Mary"]                  = true,
    ["Serpopard Ishtar"]            = true,

    -- === LEVELS 20-29 ===
    ["Crypt Ghost"]                 = true,
    ["Orcish Panzer"]               = true,
    ["Vuu Puqu the Beguiler"]       = true,
    ["No'Mho Crimsonarmor"]         = true,
    ["Maltha"]                      = true,
    ["Doppelganger Dio"]            = true,
    ["Doppelganger Gog"]            = true,
    ["Bloodpool Vorax"]             = true,
    ["Chocoboleech"]                = true,
    ["Panzer Percival"]             = true,
    ["Bi'Gho Headtaker"]            = true,
    ["Golden Bat"]                  = true,
    ["Hawkeyed Dnatbat"]            = true,
    ["Black Triple Stars"]          = true,
    ["Lumbering Lambert"]           = true,
    ["Rampaging Ram"]               = true,
    ["Tottering Toby"]              = true,
    ["Jolly Green"]                 = true,
    ["Daggerclaw Dracos"]           = true,
    ["Geyser Lizard"]               = true,
    ["Epialtes"]                    = true,
    ["Hippolytos"]                  = true,
    ["Valkurm Emperor"]             = true,
    ["Helldiver"]                   = true,

    -- === LEVELS 30-39 ===
    ["Goblin Archaeologist"]        = true,
    ["Morion Worm"]                 = true,
    ["Buburimboo"]                  = true,
    ["Moo Ouzi the Swiftblade"]     = true,
    ["Ge'Dha Evileye"]              = true,
    ["Da'Dha Hundredmask"]          = true,
    ["Eurymedon"]                   = true,
    ["Tigerbane Bakdak"]            = true,
    ["Eurytos"]                     = true,
    ["Steelbiter Gudrud"]           = true,
    ["Fraelissa"]                   = true,
    ["Hercules Beetle"]             = true,
    ["Cargo Crab Colin"]            = true,
    ["Leech King"]                  = true,
    ["Mee Deggi the Punisher"]      = true,
    ["Quu Domi the Gallant"]        = true,
    ["Trickster Kinetix"]           = true,
    ["Mycophile"]                   = true,
    ["Meteormauler Zhagtegg"]       = true,
    ["Burned Bergmann"]             = true,
    ["Asphyxiated Amsel"]           = true,
    ["Crushed Krause"]              = true,
    ["Pulverized Pfeffer"]          = true,
    ["Smothered Schmidt"]           = true,
    ["Wounded Wurfel"]              = true,
    ["Argus"]                       = true,
    ["Mimas"]                       = true,
    ["Porphyrion"]                  = true,
    ["Zo'Khu Blackcloud"]           = true,
    ["Orctrap"]                     = true,
    ["Stubborn Dredvodd"]           = true,
    ["Coo Keja the Unseen"]         = true,
    ["Aroma Leech"]                 = true,
    ["Poisonhand Gnadgad"]          = true,
    ["Drooling Daisy"]              = true,
    ["Deadly Dodo"]                 = true,
    ["Masan"]                       = true,

    -- === LEVELS 40-49 ===
    ["Namtar"]                      = true,
    ["Aroma Fly"]                   = true,
    ["Aroma Crawler"]               = true,
    ["Go'Bhu Gascon"]               = true,
    ["Nue"]                         = true,
    ["Kirata"]                      = true,
    ["Morbolger"]                   = true,
    ["Yaa Haqa the Profane"]        = true,
    ["Bat Eye"]                     = true,
    ["Foul Meat"]                   = true,
    ["Weeping Willow"]              = true,
    ["Blubbery Bulge"]              = true,
    ["Guardian Crawler"]            = true,
    ["De'Vyu Headhunter"]           = true,
    ["Dune Widow"]                  = true,
    ["Vodyanoi"]                    = true,
    ["Padfoot"]                     = true,
    ["Juggler Hecatomb"]            = true,
    ["Intulo"]                      = true,
    ["Gargantua"]                   = true,
    ["Ga'Bhu Unvanquished"]         = true,
    ["Celphie"]                     = true,
    ["Meww The Turtlerider"]        = true,
    ["Shadow Eye"]                  = true,
    ["Wuur the Sandcomber"]         = true,
    ["Seww the Squidlimbed"]        = true,
    ["Fyuu the Seabellow"]          = true,
    ["Eba"]                         = true,
    ["Qull the Shellbuster"]        = true,

    -- === LEVELS 50-59 ===
    ["Drone Crawler"]               = true,
    ["Mysticmaker Profblix"]        = true,
    ["Odqan"]                       = true,
    ["Bugbear Strongman"]           = true,
    ["Goblin Wolfman"]              = true,
    ["Noble Mold"]                  = true,
    ["Ahtu"]                        = true,
    ["Old Two-Wings"]               = true,
    ["Mischievous Micholas"]        = true,
    ["Skewer Sam"]                  = true,
    ["Bloodtear Baldurf"]           = true,
    ["Steelfleece Baldarich"]       = true,
    ["King Arthro"]                 = true,
    ["Lumber Jack"]                 = true,
    ["Waraxe Beak"]                 = true,
    ["Roc"]                         = true,
    ["Goblinsavior Heronox"]        = true,
    ["Bright-handed Kunberry"]      = true,
    ["Edacious Opo-opo"]            = true,
    ["Ziphius"]                     = true,
    ["Cactuar Cantautor"]           = true,
    ["Centurio X-I"]                = true,
    ["Keeper of Halidom"]           = true,
    ["Centurio XII-I"]              = true,
    ["Colorful Leshy"]              = true,
    ["Unstable Cluster"]            = true,
    ["Sagittarius X-XIII"]          = true,
    ["Pahh the Gullcaller"]         = true,
    ["Habetrot"]                    = true,
    ["Lich C Magnus"]               = true,
    ["Simurgh"]                     = true,
    ["Bisque-heeled Sunberry"]      = true,
    ["Fradubio"]                    = true,
    ["Flauros"]                     = true,
    ["Balor"]                       = true,
    ["Luaith"]                      = true,
    ["Lobais"]                      = true,
    ["Caithleann"]                  = true,
    ["Indich"]                      = true,

    -- === LEVELS 60-69 ===
    ["Skull of Envy"]               = true,
    ["Skull of Gluttony"]           = true,
    ["Skull of Greed"]              = true,
    ["Skull of Lust"]               = true,
    ["Skull of Pride"]              = true,
    ["Skull of Sloth"]              = true,
    ["Skull of Wrath"]              = true,
    ["Nussknacker"]                 = true,
    ["Tribunus VII-I"]              = true,
    ["Woodland Sage"]               = true,
    ["Sea Horror"]                  = true,
    ["Taisaijin"]                   = true,
    ["Demonic Tiphia"]              = true,
    ["Peg Powler"]                  = true,
    ["Worr the Clawfisted"]         = true,
    ["Goliath"]                     = true,
    ["Sea Hog"]                     = true,
    ["Death from Above"]            = true,
    ["Zoredonite"]                  = true,
    ["Northern Shadow"]             = true,
    ["Eastern Shadow"]              = true,
    ["Western Shadow"]              = true,
    ["Southern Shadow"]             = true,
    ["Sewer Syrup"]                 = true,
    ["Queen Crawler"]               = true,
    ["Matron Crawler"]              = true,
    ["Voll the Sharkfinned"]        = true,
    ["Mouu the Waverider"]          = true,
    ["Antican Praefectus"]          = true,
    ["Antican Proconsul"]           = true,
    ["Hastatus XI-XII"]             = true,
    ["Cancer"]                      = true,
    ["Sozu Rogberry"]               = true,
    ["Sozu Bliberry"]               = true,
    ["Sozu Terberry"]               = true,
    ["Tonberry Kinq"]               = true,

    -- === LEVELS 70-79 ===
    ["Shii"]                        = true,
    ["Serket"]                      = true,
    ["Capricious Cassie"]           = true,
    ["Diamond Daig"]                = true,
    ["Phantom Worm"]                = true,
    ["Wyvernpoacher Drachlox"]      = true,
    ["Zuug the Shoreleaper"]        = true,
    ["Crimson-toothed Pawberry"]    = true,
    ["Friar Rush"]                  = true,
    ["Biast"]                       = true,
    ["Silverhook"]                  = true,
    ["White Coney"]                 = true,
    ["Black Coney"]                 = true,
    ["Bloodsucker"]                 = true,
    ["Dirtyhanded Gochakzuk"]       = true,
    ["Ixtab"]                       = true,
    ["Foreseer Oramix"]             = true,
    ["Snow Maiden"]                 = true,
    ["Phanduron the Condemned"]     = true,
    ["Drexerion the Condemned"]     = true,
    ["Cemetery Cherry"]             = true,
    ["Orcish Warlord"]              = true,
    ["Orcish Hexspinner"]           = true,
    ["Pallas"]                      = true,
    ["Antican Legatus"]             = true,
    ["Proconsul XII"]               = true,
    ["Antican Tribunus"]            = true,
    ["Triarius X-XV"]               = true,
    ["Adamantoise"]                 = true,
    ["Tonberry Decapitator"]        = true,
    ["Tonberry Tracker"]            = true,
    ["Unut"]                        = true,
    ["Tarasque"]                    = true,
    ["Tyrannic Tunnok"]             = true,
    ["Mountain Worm"]               = true,
    ["Lord of Onzozo"]              = true,
    ["Ose"]                         = true,
    ["Lindwurm"]                    = true,
    ["Father Frost"]                = true,
    ["Orcish Overlord"]             = true,
    ["Diamond Quadav"]              = true,
    ["Narasimha"]                   = true,
    ["Yagudo Avatar"]               = true,
    ["Alkyoneus"]                   = true,
    ["Antican Consul"]              = true,
    ["Ocean Sahagin"]               = true,
    ["Grand Duke Batym"]            = true,
    ["Duke Haborym"]                = true,
    ["Marquis Allocen"]             = true,
    ["Marquis Amon"]                = true,
    ["Nightmare Vase"]              = true,
    ["Baobhan Sith"]                = true,
    ["Taxim"]                       = true,
    ["Ancient Goobbue"]             = true,
    ["Shikigami Weapon"]            = true,
    ["Vouivre"]                     = true,
    ["Leshonki"]                    = true,
    ["Kreutzet"]                    = true,
    ["Gration"]                     = true,

    -- === LEVELS 80-89 ===
    ["Amikiri"]                     = true,
    ["Bune"]                        = true,
    ["Frostmane"]                   = true,
    ["Cactrot Rapido"]              = true,
    ["Pelican"]                     = true,
    ["Charybdis"]                   = true,
    ["Xolotl"]                      = true,
    ["Bomb Queen"]                  = true,
    ["Sabotender Bailarina"]        = true,
    ["Ungur"]                       = true,
    ["Guivre"]                      = true,
    ["Zipacna"]                     = true,
    ["Ullikummi"]                   = true,
    ["Olla Grande"]                 = true,
    ["Hakutaku"]                    = true,
    ["Overlord Bakgodek"]           = true,
    ["Za'Dha Adamantking"]          = true,
    ["Tzee Xicu the Manifest"]      = true,
    ["Aspidochelone"]               = true,
    ["Voluptuous Vivian"]           = true,
    ["Shen"]                        = true,
    ["Kurrea"]                      = true,
    ["Ash Dragon"]                  = true,
    ["Golden-Tongued Culberry"]     = true,

    -- === LEVELS 90-99 ===
    ["Vrtra"]                       = true,
    ["Tiamat"]                      = true,
    ["Jormungand"]                  = true,

    -- === CHAINS OF PROMATHIA ===
    ["Diabolos"]                    = true,  -- The Shrouded Maw (zone 10)
    ["Omega"]                       = true,  -- Sealion's Den (zone 32)
    ["Ultima"]                      = true,  -- Sealion's Den (zone 32)
    ["Bahamut"]                     = true,  -- Monarch Linn (zone 31)

    -- === CUSTOM ===
    ["Highwind"]                    = true,
};

-- 3.5. City Groups
local city_groups = {
    -- San d'Oria districts (Chateau d'Oraguille [233] is intentionally
    -- EXCLUDED — it has its own dedicated music track and should NOT
    -- inherit San d'Oria continuity).
    [230] = "sandoria", [231] = "sandoria", [232] = "sandoria",
    -- Bastok districts (Metalworks [237] is intentionally EXCLUDED — own
    -- dedicated music track).
    [234] = "bastok",   [235] = "bastok",   [236] = "bastok",
    -- Windurst districts (Heavens Tower [242] is intentionally EXCLUDED —
    -- own dedicated music track).
    [238] = "windurst", [239] = "windurst", [240] = "windurst", [241] = "windurst",
    -- Jeuno districts: Upper [244], Lower [245], Port [246] share continuity.
    -- Ru'Lude Gardens [243] is EXCLUDED — it's the inner garden zone with its
    -- own dedicated track (like Heavens Tower / Metalworks / Chateau), not a
    -- walkable city district.
    [244] = "jeuno",    [245] = "jeuno",    [246] = "jeuno",

    -- Starting outdoor zones — both halves of each region share the same
    -- SE BGW track per canonical lists (music109 Ronfaure, music116
    -- Gustaberg, music113 Sarutabaruta). Crossing between halves should
    -- preserve music continuity exactly like city districts do.
    [100] = "ronfaure", [101] = "ronfaure",        -- West, East Ronfaure
    [106] = "gustaberg", [107] = "gustaberg",      -- North, South Gustaberg
    [115] = "sarutabaruta", [116] = "sarutabaruta",-- West, East Sarutabaruta
};

local function get_city_group(zone_id)
    return city_groups[zone_id] or nil;
end

-- Canonical representative zone ID for each city group: the LOWEST member
-- zone ID by default. All districts in a group resolve their idle track
-- through this single ID, so day_{canonical}.wav is the one filename the
-- continuity check compares against. Without this, each district returned its
-- own day_{zone_id}.wav, the track name changed on every district hop, and the
-- music restarted from 0:00 even though staying_in_city was true.
--
-- A group can override the default lowest-ID pick via city_group_canonical_override
-- when the intended source file lives on a non-lowest district (e.g. Jeuno's
-- music110 cover was authored as day_246 / Port Jeuno).
local city_group_canonical_override = {
    jeuno = 246,   -- Port Jeuno (day_246.wav) — music110 Grand Duchy cover
};
local city_group_canonical = {};
do
    for zid, gname in pairs(city_groups) do
        local cur = city_group_canonical[gname];
        if (cur == nil or zid < cur) then
            city_group_canonical[gname] = zid;
        end
    end
    -- Apply explicit overrides last so they win regardless of ID ordering.
    for gname, zid in pairs(city_group_canonical_override) do
        city_group_canonical[gname] = zid;
    end
end

-- Returns the canonical zone ID to use for track resolution. For grouped
-- city/region zones this is the group representative; for everything else
-- it's the zone itself.
local function get_canonical_zone(zone_id)
    local gname = city_groups[zone_id];
    if (gname ~= nil) then
        return city_group_canonical[gname] or zone_id;
    end
    return zone_id;
end

-- 4. Helpers
local function save_settings()
    music_config.enabled = gui_state.enabled[1];
    music_config.low_hp_threshold = gui_state.low_hp[1];
    music_config.battle_delay = gui_state.delay[1] / 10;
    music_config.idle_replay_delay = math.floor(gui_state.idle_replay_delay_min[1] * 60 + 0.5); -- minutes -> seconds
    
    music_config.enable_zone = gui_state.use_zone[1];
    music_config.enable_idle_replay = gui_state.use_idle_replay[1];
    music_config.enable_battle = gui_state.use_battle[1];
    music_config.enable_nm = gui_state.use_nm[1];
    music_config.enable_lowhp = gui_state.use_lowhp[1];
    music_config.enable_fishing = gui_state.use_fishing[1];
    music_config.enable_moghouse = gui_state.use_moghouse[1];
    music_config.enable_chocobo = gui_state.use_chocobo[1];
    music_config.battle_mode = gui_state.battle_mode[1];
    music_config.random_battle = gui_state.random_battle[1];
    
    music_config.volume = gui_state.volume[1] * 10;
    
    -- Fade settings
    music_config.enable_fade = gui_state.use_fade[1];
    music_config.fade_duration = gui_state.fade_dur[1] / 10;
    
    -- Ducking settings
    music_config.enable_duck = gui_state.use_duck[1];
    music_config.duck_percent = gui_state.duck_pct[1];
    
    -- Dynamic battle
    music_config.battle_dynamic = gui_state.battle_dynamic[1];
    music_config.battle_resume_window = gui_state.battle_resume_window[1];

    settings.save();
    print(chat.header('ZoneMusic'):append(chat.message('Settings saved.')));
end

local function resolve_audio_filename(filename)
    local base, extension = filename:match('^(.*)%.([^.]+)$');
    local candidates = { filename };

    -- Track selection tables retain their established WAV names. Resolve those
    -- names to the release MP3 first, then fall back to the untouched master.
    if (base ~= nil and string.lower(extension) == 'wav') then
        candidates = { base .. '.mp3', filename };
    end

    for _, candidate in ipairs(candidates) do
        local path = jukebox.sounds_dir() .. candidate;
        local f = io.open(path, 'rb');
        if (f ~= nil) then
            io.close(f);
            return candidate;
        end
    end

    return nil;
end

local function file_exists(filename)
    return resolve_audio_filename(filename) ~= nil;
end

-- MCI device type for a resolved audio filename. MP3 ships via the
-- MPEGVideo device; the WAV fallback (lossless master archive) needs the
-- waveaudio device or MCI will refuse/mis-handle the open.
local function get_mci_type(filename)
    if (filename ~= nil and string.lower(filename):match('%.wav$')) then
        return 'waveaudio';
    end
    return 'mpegvideo';
end

------------------------------------------------------------
-- Engine BGM suppression (0x0A zone-in packet rewrite)
--
-- The retail FFXI engine plays zone music from the 0x0A "Zone In" packet.
-- The packet contains 5 uint16 song-ID slots: day (0x56), night (0x58),
-- solo combat (0x5A), party combat (0x5C), and mount (0x5E). Zeroing these
-- before the engine reads them produces a silent zone — the engine has
-- nothing to play. ZoneMusic's MCI audio then owns the soundscape.
--
-- AUTO-DISABLE: suppression only fires for zones where ZoneMusic has at
-- least one audio file present (this zone OR any sibling in the same
-- city group). In zones with no ZoneMusic assets, the packet passes
-- through unchanged and the original engine music plays.
--
-- CUTSCENE MUSIC: retail cutscene music arrives later via 0x05F (runtime
-- music change), which we never touch. Cover .bgw files in pivot/DAT
-- continue to play in their cutscenes uninterrupted.
--
-- struct is provided as a global by require('common'); do NOT
-- require('struct') directly — it's not a standalone Ashita module
-- and the require silently fails.
------------------------------------------------------------

local ENGINE_BGM_OFFSETS = {
    day   = 0x56,
    night = 0x58,
    solo  = 0x5A,
    party = 0x5C,
    mount = 0x5E,
};

-- Original resident music IDs captured from the most recent 0x0A zone-in
-- packet BEFORE they were zeroed. Retained so a future build can restore the
-- engine's zone theme for cutscenes that rely on resident BGM (no runtime
-- 0x05F music change). Capture only; nothing reads this yet.
local saved_bgm_ids = {};

-- === PER-ZONE RESIDENT-ID PERSISTENCE (the nil-restore / amnesia fix) ===
-- saved_bgm_ids is captured from the 0x00A zone packet, which only arrives
-- on a real zone-in. An addon reload mid-zone left it empty, so event
-- handling had nothing to compare against and engine_restore injected nil.
-- Fix: every capture is stored in the settings file keyed by zone id, and
-- loaded back on addon init / zone-in as a fallback. Fresh packet capture
-- always wins over the stored copy.
local function store_zone_bgm(zid)
    if (zid == nil) then return; end
    if (music_config.zone_bgm == nil) then music_config.zone_bgm = {}; end
    music_config.zone_bgm[tostring(zid)] = {
        day   = saved_bgm_ids.day,
        night = saved_bgm_ids.night,
        solo  = saved_bgm_ids.solo,
        party = saved_bgm_ids.party,
        mount = saved_bgm_ids.mount,
    };
    pcall(settings.save);
end

local function load_zone_bgm(zid)
    if (zid == nil or music_config.zone_bgm == nil) then return false; end
    local t = music_config.zone_bgm[tostring(zid)];
    if (t == nil) then return false; end
    saved_bgm_ids.day   = t.day;
    saved_bgm_ids.night = t.night;
    saved_bgm_ids.solo  = t.solo;
    saved_bgm_ids.party = t.party;
    saved_bgm_ids.mount = t.mount;
    return true;
end

-- Returns the resident BGW song ID for the current zone given Vana'diel time
-- (night uses the night slot when present, else falls back to day), or nil if
-- not yet known. Sourced from saved_bgm_ids captured on the 0x0A zone packet.
-- Used by the NPC-talk resident gate to tell an NPC talk (engine replays the
-- zone's own resident BGW) apart from a real cutscene (engine plays a
-- different track).
local function get_zone_resident_bgm_song()
    if (saved_bgm_ids == nil) then return nil; end
    local is_night_now = false;
    pcall(function()
        local h = get_vana_hour();
        is_night_now = (h >= 18) or (h < 6);
    end);
    if (is_night_now and saved_bgm_ids.night ~= nil and saved_bgm_ids.night ~= 0) then
        return saved_bgm_ids.night;
    end
    return saved_bgm_ids.day;
end

-- Mog House detection: the 0x0A packet has a "mog house" flag byte at
-- offset 0x80 (uint8). When set to 1, the player is zoning INTO a Mog
-- House (the residential area overlay). The zone_id field at 0x30 stays
-- the home/parent zone in this case — Mog House is not its own zone ID
-- for music-slot purposes.
--
-- Reference: onimitch's ffxi-zonename addon checks this exact byte to
-- distinguish real zone changes from Mog House entries.
--
-- When the flag is set and the user has moghouse.wav, suppress engine
-- BGM so the proximity-based Moogle detection in get_desired_track can
-- play moghouse.wav cleanly without the retail Mog House theme leaking
-- through.

------------------------------------------------------------
-- EXPANSION COVERAGE GATE (Option B)
-- Master boundary: the addon only controls audio in zones whose
-- expansion is enabled. New-world zones (ToAU/WotG/SoA/Abyssea/Walk
-- of Echoes, including all Crystal War [S] zones) play native engine
-- audio until their covers ship and the flag is flipped on.
------------------------------------------------------------
-- Auto-generated zone->expansion map from LSB zone_settings.sql
-- Tags: base (vanilla/RoZ/CoP, old world), toau, wotg, soa, abyssea, walkofechoes
-- Old-world = base. New-world = everything else (engine-controlled until conquered).
local zone_expansion = {
    [15] = "abyssea",   -- Abyssea-Konschtat
    [45] = "abyssea",   -- Abyssea-Tahrongi
    [46] = "toau",   -- Open_sea_route_to_Al_Zahbi
    [48] = "toau",   -- Al_Zahbi
    [50] = "toau",   -- Aht_Urhgan_Whitegate
    [51] = "toau",   -- Wajaom_Woodlands
    [52] = "toau",   -- Bhaflau_Thickets
    [53] = "toau",   -- Nashmau
    [54] = "toau",   -- Arrapago_Reef
    [55] = "toau",   -- Ilrusi_Atoll
    [56] = "toau",   -- Periqia
    [57] = "toau",   -- Talacca_Cove
    [58] = "toau",   -- Silver_Sea_route_to_Nashmau
    [59] = "toau",   -- Silver_Sea_route_to_Al_Zahbi
    [60] = "toau",   -- The_Ashu_Talif
    [61] = "toau",   -- Mount_Zhayolm
    [62] = "toau",   -- Halvung
    [63] = "toau",   -- Lebros_Cavern
    [64] = "toau",   -- Navukgo_Execution_Chamber
    [65] = "toau",   -- Mamook
    [66] = "toau",   -- Mamool_Ja_Training_Grounds
    [67] = "toau",   -- Jade_Sepulcher
    [68] = "toau",   -- Aydeewa_Subterrane
    [69] = "toau",   -- Leujaoam_Sanctum
    [70] = "toau",   -- Chocobo_Circuit
    [79] = "toau",   -- Caedarva_Mire
    [80] = "wotg",   -- Southern_San_dOria_[S]
    [81] = "wotg",   -- East_Ronfaure_[S]
    [82] = "wotg",   -- Jugner_Forest_[S]
    [83] = "wotg",   -- Vunkerl_Inlet_[S]
    [84] = "wotg",   -- Batallia_Downs_[S]
    [85] = "wotg",   -- La_Vaule_[S]
    [87] = "wotg",   -- Bastok_Markets_[S]
    [88] = "wotg",   -- North_Gustaberg_[S]
    [89] = "wotg",   -- Grauberg_[S]
    [90] = "wotg",   -- Pashhow_Marshlands_[S]
    [91] = "wotg",   -- Rolanberry_Fields_[S]
    [92] = "wotg",   -- Beadeaux_[S]
    [94] = "wotg",   -- Windurst_Waters_[S]
    [95] = "wotg",   -- West_Sarutabaruta_[S]
    [96] = "wotg",   -- Fort_Karugo-Narugo_[S]
    [97] = "wotg",   -- Meriphataud_Mountains_[S]
    [98] = "wotg",   -- Sauromugue_Champaign_[S]
    [99] = "wotg",   -- Castle_Oztroja_[S]
    [132] = "abyssea",   -- Abyssea-La_Theine
    [133] = "soa",   -- Outer_RaKaznar_[U2]
    [136] = "wotg",   -- Beaucedine_Glacier_[S]
    [137] = "wotg",   -- Xarcabard_[S]
    [138] = "wotg",   -- Castle_Zvahl_Baileys_[S]
    [155] = "wotg",   -- Castle_Zvahl_Keep_[S]
    [156] = "wotg",   -- Throne_Room_[S]
    [164] = "wotg",   -- Garlaige_Citadel_[S]
    [171] = "wotg",   -- Crawlers_Nest_[S]
    [175] = "wotg",   -- The_Eldieme_Necropolis_[S]
    [182] = "walkofechoes",   -- Walk_of_Echoes
    [189] = "soa",   -- Outer_RaKaznar_[U3]
    [215] = "abyssea",   -- Abyssea-Attohwa
    [216] = "abyssea",   -- Abyssea-Misareaux
    [217] = "abyssea",   -- Abyssea-Vunkerl
    [218] = "abyssea",   -- Abyssea-Altepa
    [253] = "abyssea",   -- Abyssea-Uleguerand
    [254] = "abyssea",   -- Abyssea-Grauberg
    [255] = "abyssea",   -- Abyssea-Empyreal_Paradox
    [256] = "soa",   -- Western_Adoulin
    [257] = "soa",   -- Eastern_Adoulin
    [258] = "soa",   -- Rala_Waterways
    [259] = "soa",   -- Rala_Waterways_U
    [260] = "soa",   -- Yahse_Hunting_Grounds
    [261] = "soa",   -- Ceizak_Battlegrounds
    [262] = "soa",   -- Foret_de_Hennetiel
    [263] = "soa",   -- Yorcia_Weald
    [264] = "soa",   -- Yorcia_Weald_U
    [265] = "soa",   -- Morimar_Basalt_Fields
    [266] = "soa",   -- Marjami_Ravine
    [267] = "soa",   -- Kamihr_Drifts
    [268] = "soa",   -- Sih_Gates
    [270] = "soa",   -- Cirdas_Caverns
    [271] = "soa",   -- Cirdas_Caverns_U
    [272] = "soa",   -- Dho_Gates
    [273] = "soa",   -- Woh_Gates
    [274] = "soa",   -- Outer_RaKaznar
    [275] = "soa",   -- Outer_RaKaznar_[U1]
    [279] = "walkofechoes",   -- Walk_of_Echoes_[P2]
    [280] = "soa",   -- Mog_Garden
    [281] = "soa",   -- Leafallia
    [282] = "soa",   -- Mount_Kamihr
    [284] = "soa",   -- Celennia_Memorial_Library
    [288] = "soa",   -- Escha_ZiTah
    [289] = "soa",   -- Escha_RuAun
    [291] = "soa",   -- Reisenjima
    [292] = "soa",   -- Reisenjima_Henge
    [293] = "soa",   -- Reisenjima_Sanctorium
    [298] = "walkofechoes",   -- Walk_of_Echoes_[P1]
};

-- Per-expansion enable flags. Flip to true as covers ship for that expansion.
local expansion_enabled = {
    base         = true,    -- vanilla + RoZ + CoP (conquered)
    toau         = false,   -- Treasures of Aht Urhgan
    wotg         = false,   -- Wings of the Goddess ([S] zones)
    soa          = false,   -- Seekers of Adoulin
    abyssea      = false,   -- Abyssea
    walkofechoes = false,   -- Walk of Echoes
};

-- Per-zone opt-out. Flags live on the canonical id so every district of a
-- city group shares one switch; splitting them would fight the district
-- continuity logic, which assumes the whole group plays one track.
local function is_zone_disabled(zone_id)
    if (zone_id == nil) then return false; end
    local t = music_config.disabled_zones;
    return (t ~= nil and t[tostring(get_canonical_zone(zone_id))] == true) or false;
end

-- Master coverage gate. Returns true if the addon should control
-- audio in this zone; false = stay hands-off, engine plays.
local function zone_is_covered_expansion(zone_id)
    -- With the addon switched off it controls nothing, so zone-in leaves
    -- the engine's music slots alone and event handling stays hands-off.
    if (music_config.enabled == false) then return false; end
    local tag = zone_expansion[zone_id] or "base";
    return expansion_enabled[tag] == true and not is_zone_disabled(zone_id);
end

-- Decide whether to suppress engine BGM for the given zone.
local function has_zonemusic_assets(zone_id)
    local candidates = {
        string.format("day_%d.wav",          zone_id),
        string.format("night_%d.wav",        zone_id),
        string.format("battle_%d_solo.wav",  zone_id),
        string.format("battle_%d_party.wav", zone_id),
    };
    for _, fn in ipairs(candidates) do
        if (file_exists(fn)) then return true; end
    end

    -- City group inheritance: city_groups[zone_id] returns a group NAME
    -- string (e.g. "sandoria"), not a member array. Find all sibling
    -- zones that share the same group name. Mirrors the inheritance
    -- behavior in get_desired_track().
    local group_name = get_city_group(zone_id);
    if (group_name ~= nil) then
        for other_id, other_group in pairs(city_groups) do
            if (other_group == group_name and other_id ~= zone_id) then
                local sibs = {
                    string.format("day_%d.wav",          other_id),
                    string.format("night_%d.wav",        other_id),
                    string.format("battle_%d_solo.wav",  other_id),
                    string.format("battle_%d_party.wav", other_id),
                };
                for _, fn in ipairs(sibs) do
                    if (file_exists(fn)) then return true; end
                end
            end
        end
    end

    return false;
end

------------------------------------------------------------
-- Binary cutscene gate
--
-- When the player is in any event (cutscene, mission scene, long NPC
-- interaction), ZoneMusic fades its MCI audio out and lets the engine
-- play whatever BGW it wants. Whether that's the user's cover .bgw
-- from pivot or the retail track is the engine's concern, not ours.
--
-- When the player is NOT in an event, the engine is suppressed via
-- 0x0A slot zeroing (already implemented above) and ZoneMusic MCI
-- owns the soundscape.
--
-- Cutscene detection reuses the existing addon flags:
--   * StatusServer == 4 sustained for STATUS4_DELAY seconds
--   * Incoming 0x034 (Event Start) packet matured past PACKET_EVENT_DELAY
--
-- No pivot folder scan, no BGW ID classification, no 0x05F gating —
-- the engine's behavior is trusted as the source of truth during events.

-- Canonical FFXI music ID -> name map. Source: BG Wiki Music page,
-- combined Vanilla / RotZ / CoP / ToAU / Add-Ons / WotG / SoA /
-- Rhapsodies / The Voracious Resurgence / Other tables.
--
-- Used purely for friendly-name display in /zm covers and DEBUG_CUTSCENE
-- logging. The cutscene-mute logic now runs on a binary gate (in event =
-- engine plays everything, not in event = engine plays nothing) and does
-- not consult this table for decisions.
local BGW_NAMES = {
    -- === Vanilla / Base ===
    [101] = "Battle Theme",
    [102] = "Battle in the Dungeon #2",
    [103] = "Battle Theme #2",
    [104] = "Ghelsba / A Road Once Traveled",
    [105] = "Mhaura",
    [106] = "Voyager",
    [107] = "The Kingdom of San d'Oria",
    [108] = "Vana'diel March",
    [109] = "Ronfaure",
    [110] = "The Grand Duchy of Jeuno",
    [111] = "Blackout",
    [112] = "Selbina",
    [113] = "Sarutabaruta",
    [114] = "Batallia Downs",
    [115] = "Battle in the Dungeon",
    [116] = "Gustaberg",
    [117] = "Ru'Lude Gardens",
    [118] = "Rolanberry Fields",
    [119] = "Awakening",
    [120] = "Vana'diel March #2",
    [121] = "Shadow Lord",
    [122] = "One Last Time / Just Once More",
    [123] = "Hopelessness",
    [124] = "Recollection",
    [125] = "Tough Battle",
    [126] = "Mog House",
    [127] = "Anxiety",
    [128] = "Airship",
    [129] = "Hook, Line, and Sinker (Fishing Small)",
    [130] = "Tarutaru Female",
    [131] = "Elvaan Female",
    [132] = "Elvaan Male",
    [133] = "Hume Male",
    [136] = "The Big One (Fishing Large)",
    [137] = "A Realm of Emptiness (CoP final phase 2 / Apocalyse Nigh)",
    [151] = "The Federation of Windurst",
    [152] = "The Republic of Bastok",
    [153] = "Prelude",
    [154] = "Metalworks",
    [155] = "Castle Zvahl",
    [156] = "Chateau d'Oraguille",
    [157] = "Fury",
    [158] = "Sauromugue Champaign",
    [159] = "Sorrow",
    [160] = "Repression (Memoro de la S^tono)",
    [161] = "Despair (Memoro de la S^tono)",
    [162] = "Heavens Tower",
    [163] = "Sometime, Somewhere",
    [164] = "Xarcabard",
    [165] = "Galka",
    [166] = "Mithra",
    [167] = "Tarutaru Male",
    [168] = "Hume Female",
    [169] = "Regeneracy (Job Change Land)",
    [170] = "Buccaneers (Pirate Attack)",
    [214] = "Eternal Oath / Wedding March",

    -- === Rise of the Zilart ===
    [134] = "Yuhtunga Jungle",
    [135] = "Kazham",
    [171] = "Altepa Desert (Kuzotz)",
    [190] = "The Sanctuary of Zi'Tah",
    [191] = "Battle Theme #3 (Zilart Field)",
    [192] = "Battle In the Dungeon #3 (Zilart)",
    [193] = "Tough Battle #2 (Zilart BF)",
    [194] = "Bloody Promises (Raogrimm's theme)",
    [195] = "Belief (Zilart final boss P2)",
    [196] = "Fighters of the Crystal (Ark Angels)",
    [197] = "To The Heavens / Kamlanaut #2",
    [198] = "Eald'narche (Zilart final boss P1)",
    [199] = "Grav'iton",
    [200] = "Hidden Truths / Kamlanaut #1",
    [201] = "End Theme (Zilart ending)",
    [202] = "Moongate (Memoro De La S^tono)",
    [206] = "Revenant Maiden / The Zilart (Yve'noile)",
    [207] = "Ve'Lugannon Palace",
    [208] = "Rabao",
    [209] = "Norg",
    [210] = "Tu'Lia",
    [211] = "Ro'Maeve",
    [212] = "Dash de Chocobo",
    [213] = "Hall of the Gods",
    [227] = "Sunbreeze Shuffle",

    -- === Chains of Promathia ===
    [218] = "Depths Of The Soul (Promathia Dungeon Battle)",
    [219] = "Onslaught (Promathia Field Battle)",
    [220] = "Turmoil (Promathia Mission BF)",
    [221] = "Moblin Menagerie - Movalpolos",
    [222] = "Faded Memories - Promyvion",
    [223] = "Conflict: March of the Hero",
    [224] = "Dusk and Dawn",
    [225] = "Words Unspoken - Pso'Xja",
    [226] = "Conflict: You Want To Live Forever?",
    [228] = "Gates Of Paradise - The Garden of Ru'Hmet",
    [229] = "The Currents of Time",
    [230] = "A New Horizon - Tavnazian Archipelago",
    [231] = "Celestial Thunder / Trembling Sky (Nag'molada)",
    [232] = "Ruler of the Skies",
    [233] = "The Celestial Capital - Al'Taieu",
    [234] = "Happily Ever After",
    [235] = "First Ode: Nocturne Of The Gods",
    [240] = "Second Ode: Distant Promises",
    [237] = "Third Ode: Memoria de la S^tono",
    [236] = "Fourth Ode: Clouded Dawn",
    [241] = "Fifth Ode: A Time for Prayer",
    [238] = "A New Morning",
    [242] = "Unity (Title screen)",
    [243] = "Grav'iton (CoP duplicate)",
    [244] = "Revenant Maiden (CoP duplicate)",
    [245] = "The Forgotten City - Tavnazian Safehold",
    [900] = "Distant Worlds (Promathia ending)",
    [239] = "Jeuno ~Starlight Celebration~",

    -- === Treasures of Aht Urhgan ===
    [138] = "Mercenaries' Delight (Aht Urhgan Field)",
    [139] = "Delve (Aht Urhgan Dungeon)",
    [142] = "Fated Strife -Besieged-",
    [143] = "Hellriders (Aht Urhgan Mission BF)",
    [144] = "Rapid Onslaught -Assault-",
    [146] = "The Colosseum (Pankration)",
    [147] = "Eastward Bound...",
    [148] = "Forbidden Seal (Nyzul Isle)",
    [149] = "Jeweled Boughs (Bhaflau/Wajaom)",
    [150] = "Ululations from Beyond (Arrapago Reef)",
    [172] = "Black Coffin (Ashu Talif)",
    [173] = "Illusions in the Mist (Caedarva Mire)",
    [174] = "Whispers of the Gods (Aydeewa)",
    [175] = "Bandits' Market (Nashmau)",
    [176] = "Circuit de Chocobo (Chocobo Circuit)",
    [177] = "Run Chocobo Run!",
    [178] = "The Bustle of the Capital (Whitegate / Al Zahbi)",
    [179] = "Vana'diel March #4",
    [183] = "A Puppet's Slumber",
    [184] = "Eternal Gravestone (Beseiged defeated)",
    [185] = "Ever-Turning Wheels",
    [186] = "Iron Colossus (Einherjar)",
    [187] = "Ragnarok (Aht Urhgan final boss)",
    [188] = "Choc-A-Bye-Baby (Chocobo Raising)",
    [189] = "An Invisible Crown (Aht Urhgan ending)",

    -- === Add-on Scenarios ===
    [047] = "Echoes of Creation (ACP Final Boss)",
    [048] = "Main Theme -FINAL FANTASY XI Version-",
    [049] = "Luck of the Mog (MKD Final Boss)",
    [050] = "Feast of the Ladies (ASA Final Boss)",
    [051] = "Abyssea - Scarlet Skies, Shadowed Plains",
    [052] = "Melodies Errant (Abyssea Battle)",
    [053] = "Shinryu (Abyssea Final Boss)",
    [055] = "Provenance Watcher (Voidwatch Final Boss)",
    [056] = "Where it All Begins (Provenance)",

    -- === Wings of the Goddess ===
    [040] = "Cloister of Time and Souls",
    [041] = "Royal Wanderlust (WotG Missions / Cait Sith)",
    [042] = "Snowdrift Waltz (Xarcabard S)",
    [043] = "Troubled Shadows (Castle Zvahl S)",
    [044] = "Where Lords Rule Not (La Vaule/Beadeaux/Oztroja S)",
    [045] = "Summers Lost (Lilisette's theme)",
    [046] = "Goddess Divine (WotG Final Boss)",
    [054] = "Everlasting Bonds (WotG ending)",
    [140] = "Wings of the Goddess (Title)",
    [141] = "The Cosmic Wheel (West Sarutabaruta S)",
    [145] = "Encampment Dreams (WotG Missions)",
    [180] = "Thunder of the March (Bastok Markets S)",
    [182] = "Stargazing (Windurst Waters S)",
    [215] = "Clash of Standards (WotG Field Battle)",
    [216] = "On this Blade (WotG Dungeon Battle)",
    [217] = "Kindred Cry (WotG Mission BF / Odyssey)",
    [246] = "March of the Allied Forces",
    [247] = "Roar of the Battle Drums (Campaign Battle)",
    [248] = "Young Griffons in Flight",
    [249] = "Run Maggot, Run! (Moblin Maze Mongers)",
    [250] = "Under a Clouded Moon (WotG quest BF)",
    [251] = "Autumn Footfalls (East Ronfaure S)",
    [252] = "Flowers on the Battlefield",
    [253] = "Echoes of a Zephyr (North Gustaberg S)",
    [254] = "Griffons Never Die (Southern San d'Oria S)",

    -- === Seekers of Adoulin ===
    [057] = "Steel Sings, Blades Dance (SoA Battle)",
    [058] = "A New Direction (SoA Title)",
    [059] = "The Pioneers (Western Adoulin)",
    [060] = "Into Lands Primeval - Ulbuka",
    [061] = "Water's Umbral Knell (Rala Waterways)",
    [062] = "Keepers of the Wild (Wildskeeper Reive)",
    [063] = "The Sacred City of Adoulin (Eastern Adoulin)",
    [064] = "Breaking Ground (Reive Battle)",
    [065] = "Hades (SoA Final Boss P1)",
    [066] = "Arciela (SoA Missions)",
    [067] = "Mog Resort (Mog Garden)",
    [068] = "Worlds Away (SoA Missions)",
    [072] = "The Serpentine Labyrinth (Outer Ra'Kaznar)",
    [073] = "The Divine (Mount Kamihr)",
    [074] = "Clouds Over Ulbuka (SoA BF)",
    [075] = "The Price (SoA Final Boss P2)",
    [076] = "Forever Today (SoA ending)",
    [078] = "Forever Today (instrumental)",

    -- === Rhapsodies of Vana'diel ===
    [079] = "Iroha (Reisenjima/RoV Missions)",
    [080] = "The Boundless Black (Escha)",
    [081] = "Isle of the Gods (RoV Missions)",
    [082] = "Wail of the Void (RoV Final Boss)",
    [083] = "Rhapsodies of Vana'diel (RoV ending)",

    -- === The Voracious Resurgence ===
    [025] = "The Voracious Resurgence (TVR Missions)",
    [026] = "The Devoured (TVR Battle)",
    [027] = "Encroaching Perils (TVR Missions)",
    [028] = "The Destiny Destroyers",
    [031] = "Black Stars Rise (TVR Missions)",
    [032] = "All Smiles (TVR Missions)",
    [033] = "Valhalla (TVR Final Boss P1)",
    [034] = "We Are Vana'diel (TVR Title)",
    [037] = "All-Consuming Chaos (TVR Final Boss P2)",
    [038] = "Your Choice (TVR ending)",

    -- === Other ===
    [035] = "Goddesspeed (Sortie - Ground Level)",
    [036] = "Good Fortune (Sortie - Basement)",
    [028] = "Devils' Delight (Harvest Festival)",
    [030] = "Sojourner (Odyssey/Bumba)",
    [070] = "Monstrosity",
    [084] = "Full Speed Ahead! (Mounts)",
    [085] = "Times Grow Tense (Ambuscade)",
    [087] = "For a Friend (Omen)",
    [088] = "Between Dreams and Reality (Dynamis-D W1/W2)",
    [089] = "Disjoined One (Dynamis-D W3)",
    [090] = "Winds of Change (Heroines' Combat II)",
};

local function suppress_engine_bgm_in_zone_packet(e)
    -- Zone id sits at offset 0x30 (uint16). Read directly from the
    -- packet so we don't depend on the memory manager being updated yet.
    local incoming_zone_id = struct.unpack('H', e.data, 0x30 + 1);

    -- Mog House flag at offset 0x80: nonzero when entering Mog House
    -- overlay. The actual Mog House music is NOT in 0x0A's music slots
    -- though — it gets sent as a runtime 0x05F packet referencing
    -- music126.bgw. That's handled by the 0x05F blocker below.
    local moghouse_flag = struct.unpack('b', e.data, 0x80 + 1);
    local entering_moghouse = (moghouse_flag ~= 0);

    -- Always record the engine's resident music IDs, even in zones the addon
    -- leaves alone. A zone the player disabled needs them later if it gets
    -- re-enabled mid-zone (and vice versa, to hand the engine its music back).
    pcall(function()
        saved_bgm_ids.day   = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.day   + 1);
        saved_bgm_ids.night = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.night + 1);
        saved_bgm_ids.solo  = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.solo  + 1);
        saved_bgm_ids.party = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.party + 1);
        saved_bgm_ids.mount = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.mount + 1);
    end);

    -- Persist the fresh capture (see store_zone_bgm comment).
    pcall(store_zone_bgm, incoming_zone_id);

    -- EXPANSION / PER-ZONE GATE: if this zone's expansion is not enabled, or
    -- the player switched the addon off here, stay fully hands-off — never
    -- suppress the engine, so native BGM plays.
    if (not zone_is_covered_expansion(incoming_zone_id)) then
        return;
    end

    local should_suppress = has_zonemusic_assets(incoming_zone_id)
                         or (entering_moghouse and file_exists("moghouse.wav"));

    if (not should_suppress) then
        return;
    end

    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.day,   0, 16);
    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.night, 0, 16);
    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.solo,  0, 16);
    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.party, 0, 16);
    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.mount, 0, 16);
end

-- 5. The DJ Logic
-- Keep boss state on the existing helper table to respect the runtime's
-- per-function upvalue limit in update_music.
jukebox.shadow = require('zm_shadow').new();
function jukebox.shadow_track()
    local party = AshitaCore:GetMemoryManager():GetParty();
    local zone = party:GetMemberZone(0);
    local player = GetPlayerEntity();
    if (zone ~= 165) then
        jukebox.shadow:reset();
        jukebox.shadow_reset_intro();
        return nil;
    end
    if (not music_config.enabled or not music_config.enable_battle
        or not zone_is_covered_expansion(zone) or player == nil
        or player.Status == 2 or party:GetMemberHPPercent(0) == 0
        or (player.StatusServer or 0) == 4) then return nil; end
    local now = os.clock();
    if (now >= (jukebox.shadow_poll or 0)) then
        jukebox.shadow_poll = now + 0.25;
        local boss = nil;
        for i = 0, 2303 do
            local ent = GetEntity(i);
            if (ent ~= nil and (ent.Name == 'Shadow Lord' or ent.Name == 'The Shadow Lord')
                and ent.Status == 1 and (ent.HPPercent == nil or ent.HPPercent > 0)) then
                boss = ent.ServerId or i;
                break;
            end
        end
        jukebox.shadow:observe(boss, now);
    end
    return jukebox.shadow:track(now, file_exists);
end

local function get_desired_track()
    local player_ent = GetPlayerEntity();
    if (player_ent == nil) then 
        current_state = "Loading...";
        return ""; 
    end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local status = player_ent.Status; 
    local zone_id = party:GetMemberZone(0);
    local hp_per  = party:GetMemberHPPercent(0);

    -- EXPANSION GATE: in a zone whose expansion isn't enabled, the addon plays
    -- nothing — the engine owns audio. Returning "" keeps MCI silent here.
    if (not zone_is_covered_expansion(zone_id)) then
        current_state = is_zone_disabled(zone_id)
            and "Idle (Game Music - addon off in this zone)"
            or "Idle (Game Music)";
        return "";
    end

    -- === PARTY BATTLE DETECTION ===
    local party_size = 0;
    local party_server_ids = {};
    local my_zone = party:GetMemberZone(0);
    
    for i = 0, 5 do
        local member_zone = party:GetMemberZone(i);
        if (member_zone ~= nil and member_zone > 0 and member_zone == my_zone) then
            party_size = party_size + 1;
            local sid = party:GetMemberServerId(i);
            if (sid ~= nil and sid > 0) then
                party_server_ids[sid] = true;
            end
        end
    end
    
    if (party_size >= 2) then
        local party_in_battle = false;
        
        for j = 0, 2303 do
            local ent = GetEntity(j);
            if (ent ~= nil and ent.ServerId ~= nil) then
                if (party_server_ids[ent.ServerId]) then
                    if (ent.Status == 1) then
                        party_in_battle = true;
                        break;
                    end
                end
            end
        end
        
        if (party_in_battle) then
            status = 1;
        end
    end
    
    -- === GET VANA'DIEL TIME ===
    local vana_hour = get_vana_hour();
    local is_night = (vana_hour >= 18) or (vana_hour < 6);
    
    -- === CALCULATE IDLE TRACK ===
    local idle_track = "";
    local prefix = is_night and "night" or "day";

    -- For grouped city/region zones, resolve through the canonical (lowest-ID)
    -- member so every district maps to the SAME filename. This is what makes
    -- the continuity check see "no track change" across district hops. The
    -- canonical day_/night_ file is the single source for the whole group;
    -- per-district files (day_244, day_245, ...) are intentionally ignored
    -- for grouped zones so they can't diverge mid-city.
    local resolve_id = get_canonical_zone(zone_id);

    local zone_time_track = string.format("%s_%d.wav", prefix, resolve_id);
    local zone_fallback = string.format("day_%d.wav", resolve_id);

    if file_exists(zone_time_track) then 
        idle_track = zone_time_track;
    elseif file_exists(zone_fallback) then
        -- Fall back to the canonical day_ file when no night_ variant exists,
        -- or when the time-specific file is missing. (Covers both the night-
        -- without-variant case and any group whose canonical only has a day_.)
        idle_track = zone_fallback;
    else
        -- Last-resort sibling scan (handles groups where the canonical ID
        -- itself has no file but another member does — shouldn't happen with
        -- correct assets, kept for safety).
        local current_city = get_city_group(zone_id);
        if (current_city ~= nil) then
            for other_zone_id, city_name in pairs(city_groups) do
                if (city_name == current_city and other_zone_id ~= resolve_id) then
                    local other_zone_track = string.format("%s_%d.wav", prefix, other_zone_id);
                    local other_day = string.format("day_%d.wav", other_zone_id);
                    if file_exists(other_zone_track) then
                        idle_track = other_zone_track;
                        break;
                    elseif file_exists(other_day) then
                        idle_track = other_day;
                        break;
                    end
                end
            end
        end
    end
    
    if (idle_track == "") then
        if file_exists(prefix .. "_default.wav") then
            idle_track = prefix .. "_default.wav";
        elseif file_exists("idle_default.wav") then
            idle_track = "idle_default.wav";
        end
    end

    -- Boss engagement bypasses generic entry/exit delays. The encounter keeps
    -- its theme through the short entity gap between phases.
    if (zone_id == 165 and music_config.enable_battle) then
        local shadow_track = jukebox.shadow_track();
        if (shadow_track ~= nil) then
            battle_start_timer = 0;
            battle_end_timer = 0;
            previous_status = status;
            unique_nm_scan_result = shadow_track;
            last_unique_nm_track = shadow_track;
            current_state = 'Shadow Lord (Phase ' .. jukebox.shadow.phase .. ')';
            return shadow_track;
        elseif (jukebox.shadow.finished and status ~= 2 and hp_per > 0) then
            battle_start_timer = 0;
            battle_end_timer = 0;
            previous_status = status;
            unique_nm_scan_result = nil;
            return idle_track;
        end
    end

    -- === HANDLE BATTLE ENTRY/EXIT DELAYS ===
    -- Entering battle (going from idle to combat)
    if (status == 1 and previous_status == 0) then
        -- Check if we're re-engaging while exit delay is still active (CHAINING)
        if (battle_end_timer > 0) then
            -- CHAINING: Re-engaged before exit delay expired
            -- Clear both timers - no delays, continue battle music seamlessly
            battle_end_timer = 0;
            battle_start_timer = 0;
        else
            -- FRESH ENGAGEMENT: Coming from true idle state
            -- Apply entry delay
            battle_start_timer = os.clock();
        end
    end
    
    -- Exiting battle (going from combat to idle)
    if (status == 0 and previous_status == 1) then
        battle_end_timer = os.clock();
        battle_start_timer = 0;
    end
    
    -- ENTRY DELAY: In battle but delay hasn't passed yet (only for fresh engagements)
    if (status == 1 and battle_start_timer > 0) then
        local time_in_battle = os.clock() - battle_start_timer;
        if (time_in_battle < music_config.battle_delay) then
            current_state = string.format("Battle (Entry Delay: %.1fs)", music_config.battle_delay - time_in_battle);
            previous_status = status;
            return idle_track; -- Keep playing zone music during entry delay
        else
            -- Entry delay finished, clear timer
            battle_start_timer = 0;
        end
    end
    
    -- EXIT DELAY: Left battle but delay hasn't passed yet
    if (status == 0 and battle_end_timer > 0) then
        local time_since_battle = os.clock() - battle_end_timer;
        if (time_since_battle < music_config.battle_delay) then
            current_state = string.format("Battle (Exit Delay: %.1fs)", music_config.battle_delay - time_since_battle);
            previous_status = status;
            return current_track; -- Keep playing battle music during exit delay
        else
            -- Exit delay finished, clear timer
            battle_end_timer = 0;
            -- Clear NM scan cache so it doesn't linger into next engagement
            nm_scan_result = nil;
            unique_nm_scan_result = nil;
            -- Clear phase tracking so the next fight starts with a clean
            -- "have we seen a companion yet" state. Without this, walking
            -- back into a fresh fight after a previous one would skip the
            -- debounce check because last_seen would still hold the old
            -- timestamp.
            phase_companion_last_seen = {};
            -- Standard mode: clear random track and coin flip for fresh start next fight
            -- Dynamic mode: keep these alive until the resume window expires
            if not (music_config.battle_dynamic) then
                current_random_track = "";
                zone_coinflip_active = false;
                zone_coinflip_suffix = "";
            end
        end
    end
    
    previous_status = status;

    -- === DEATH STATE: yield to FFXI native music ===
    -- Strategy: when the player enters the death state, this function
    -- returns "" (empty desired_track). update_music sees the empty
    -- value and stops any addon playback so FFXI's native death.bgw
    -- becomes the only audio. The user's setup keeps the native
    -- death.bgw intact while everything else is replaced with
    -- 1-second silence stubs, so the handoff is seamless.
    --
    -- We don't call stop_all_music_instant() here because that function
    -- is defined later in the file; calling it from this earlier scope
    -- would resolve to a nil global at parse time. The update_music
    -- function (which IS later) handles the actual stop.
    local player_dead = (status == 2) or (hp_per == 0);

    if (player_dead and not is_dead) then
        is_dead = true;
    elseif (not player_dead and is_dead) then
        is_dead = false;
    end

    if (is_dead) then
        current_state = "Death (FFXI native)";
        return "";  -- empty desired_track = addon yields, update_music stops playback
    end

    -- === PRIORITY 1: LOW HP (FIXED: use <= instead of <) ===
    if (music_config.enable_lowhp and status == 1 and hp_per > 0) then
        local threshold = music_config.low_hp_threshold;
        local exit_threshold = threshold + 5;
        
        -- FIX: Use <= for threshold check
        if (not in_crisis_mode and hp_per <= threshold) then
            in_crisis_mode = true;
        end
        
        if (in_crisis_mode and hp_per > exit_threshold) then
            in_crisis_mode = false;
        end
        
        if (in_crisis_mode and file_exists("lowhp.wav")) then
            current_state = string.format("Crisis (Low HP: %d%% - Exit at %d%%)", hp_per, exit_threshold);
            return "lowhp.wav";
        end
    else
        in_crisis_mode = false;
    end

    -- === PRIORITY 1.5: FISHING ===
    -- Detected via chat message interception (text_in event handler below).
    -- The text_in handler sets fishing_active=true on bite messages and
    -- clears it on catch/break/loss messages. We just check the flag here.
    --
    -- Track selection (small vs large) is also set by text_in based on
    -- which bite message was matched:
    --   "Something caught the hook!"           -> fishing_small.wav (music129)
    --   "You feel something pulling at your line." -> fishing_small.wav (music129)
    --   "Something caught the hook!!!"          -> fishing_large.wav (music136)
    --   "Something clamps onto your line ferociously!" -> fishing_large.wav (music136)
    --
    -- Files are gated on existence: missing variants fall through to the
    -- generic fishing.wav fallback, then to zone music if that's also
    -- missing. Toggleable via music_config.enable_fishing.
    if (music_config.enable_fishing and fishing_active) then
        local track = nil;
        if (fishing_bite_type == "large" and file_exists("fishing_large.wav")) then
            track = "fishing_large.wav";
        elseif (fishing_bite_type == "small" and file_exists("fishing_small.wav")) then
            track = "fishing_small.wav";
        elseif (file_exists("fishing.wav")) then
            track = "fishing.wav";
        end
        if (track) then
            current_state = string.format("Fishing (%s bite)", fishing_bite_type or "unknown");
            return track;
        end
    end

    -- === PRIORITY 1.7: MOG HOUSE ===
    -- Inside a Mog House ONLY. moghouse_active is driven solely by the
    -- zone-in packet flag (0x00A offset 0x80 == 1, see jukebox.mh_enter):
    -- the Mog House has no zone id of its own, and NPCs named "Moogle"
    -- (Nomad Moogles, city Moogles) never trigger it. The city theme stays
    -- paused underneath and resumes from its position on exit.
    if (music_config.enable_moghouse and moghouse_active and file_exists("moghouse.wav")) then
        current_state = "Mog House";
        return "moghouse.wav";
    end

    -- === PRIORITY 1.8: CHOCOBO MOUNT ===
    -- FFXI Status == 5 (Chocobo) is the canonical "player is mounted" signal,
    -- verified against the EasyFarm Status enum used as the project's source
    -- of truth for player state values.
    --
    -- Behavior:
    --   - Mount up: status transitions 0 -> 5, music fades to chocobo.wav
    --   - Dismount (manual /dismount, timer expiry, or attack-forced):
    --     status transitions 5 -> 0, music fades back to zone music
    --   - Zone change while mounted is allowed for chocobos (unlike Trainer's
    --     Whistle mounts) — the new zone's day/night track will pause
    --     chocobo.wav momentarily during the zone gap, then chocobo.wav
    --     resumes once player_ent loads with Status == 5 still active.
    --
    -- No scan or chat parsing needed — single-byte equality check on the
    -- player's own Status that's already being read every tick.
    if (music_config.enable_chocobo and status == 5 and file_exists("chocobo.wav")) then
        current_state = "Chocobo Mount";
        return "chocobo.wav";
    end

    -- === PRIORITY 2: BATTLE ===
    if (music_config.enable_battle and status == 1) then
        -- === PRIORITY 2.0: UNIQUE-NM BATTLE OVERRIDE ===
        -- Runs unconditionally (no toggle): players who don't have the unique
        -- WAV on disk fall through to the rest of the battle chain naturally
        -- via the file_exists() guard below.
        --
        -- Identical scan pattern to the enable_nm block: rate-limited 2303
        -- entity sweep, name-based match, Status == 1 confirms the NM is
        -- engaged. Difference: lookup yields a per-NM filename instead of a
        -- shared NM_battle.wav, and this block returns first so it takes
        -- priority over both the generic NM track and the regular battle
        -- selection chain.
        do
            local now = os.clock();
            if (now - unique_nm_scan_timer >= nm_scan_interval) then
                unique_nm_scan_timer = now;
                local success, scan_result = pcall(function()
                    -- First pass: locate the boss entity. For a SIMPLE (string)
                    -- entry, require the boss itself engaged (Status==1). For a
                    -- PHASED entry, the boss may be present-but-invulnerable
                    -- while you fight its companions (e.g. Eald'narche stands
                    -- unengaged during the Exoplates phase), so we match the
                    -- boss on PRESENCE here and decide engagement below using
                    -- the boss OR any companion.
                    local matched_boss_name = nil;
                    local matched_entry = nil;
                    for j = 0, 2303 do
                        local ent = GetEntity(j);
                        if (ent ~= nil and ent.Name ~= nil) then
                            local entry = unique_nm_list[ent.Name];
                            if (entry ~= nil) then
                                if (type(entry) == "table" and entry.phase_companions) then
                                    -- Phased boss: match on presence (engaged
                                    -- check happens in the phased block below).
                                    if (ent.HPPercent == nil or ent.HPPercent > 0) then
                                        matched_boss_name = ent.Name;
                                        matched_entry = entry;
                                        break;
                                    end
                                elseif (ent.Status == 1) then
                                    -- Simple boss: require engaged.
                                    matched_boss_name = ent.Name;
                                    matched_entry = entry;
                                    break;
                                end
                            end
                        end
                    end

                    if (matched_entry == nil) then
                        return nil;
                    end

                    -- Simple string entry: single track, no phase logic.
                    if (type(matched_entry) == "string") then
                        if (file_exists(matched_entry)) then
                            current_state = "NM Battle: " .. matched_boss_name;
                            return matched_entry;
                        end
                        return nil;
                    end

                    -- Phased entry: scan for companion presence.
                    -- Phase 1 = any phase_companion alive within the same zone.
                    -- Phase 2 = no companions exist (after debounce).
                    if (type(matched_entry) == "table" and matched_entry.phase_companions) then
                        local companions = matched_entry.phase_companions;

                        -- Substring companion match: table has "Exoplate" but the
                        -- in-game entity may be "Exoplate", "The Exoplates", etc.
                        -- Also require the fight to actually be live: the boss is
                        -- engaged OR any companion is engaged. Without this, the
                        -- boss's mere presence in the zone (e.g. during the entry
                        -- cutscene, pre-engage) would start battle music early.
                        local any_companion_alive = false;
                        local fight_is_live = false;

                        -- Boss engaged?
                        for j = 0, 2303 do
                            local ent = GetEntity(j);
                            if (ent ~= nil and ent.Name == matched_boss_name
                                and ent.Status == 1) then
                                fight_is_live = true;
                                break;
                            end
                        end

                        for j = 0, 2303 do
                            local ent = GetEntity(j);
                            if (ent ~= nil and ent.Name ~= nil) then
                                -- substring match against each companion token
                                local is_companion = false;
                                for _, n in ipairs(companions) do
                                    if (string.find(ent.Name, n, 1, true) ~= nil) then
                                        is_companion = true;
                                        break;
                                    end
                                end
                                if (is_companion) then
                                    if (ent.HPPercent == nil or ent.HPPercent > 0) then
                                        any_companion_alive = true;
                                        if (ent.Status == 1) then
                                            fight_is_live = true;
                                        end
                                    end
                                end
                            end
                        end

                        -- Not engaged yet (cutscene / pre-fight): don't start
                        -- battle music. Let the normal cutscene/zone logic run.
                        if (not fight_is_live) then
                            return nil;
                        end

                        local now_local = os.clock();
                        if (any_companion_alive) then
                            phase_companion_last_seen[matched_boss_name] = now_local;
                        end

                        -- Promote to phase2 only if companions have been absent
                        -- long enough to clear the debounce window. If we've
                        -- never seen a companion this fight, no debounce needed.
                        local last_seen = phase_companion_last_seen[matched_boss_name];
                        local in_phase1;
                        if (any_companion_alive) then
                            in_phase1 = true;
                        elseif (last_seen == nil) then
                            -- Never saw a companion (e.g. fight started in phase 2,
                            -- or GM-spawned boss without companions). Phase 2.
                            in_phase1 = false;
                        else
                            in_phase1 = (now_local - last_seen) < PHASE_COMPANION_DEBOUNCE;
                        end

                        local picked = in_phase1 and matched_entry.phase1 or matched_entry.phase2;
                        if (picked and file_exists(picked)) then
                            current_state = string.format("NM Battle: %s (Phase %d)",
                                matched_boss_name, in_phase1 and 1 or 2);
                            return picked;
                        end
                        return nil;
                    end

                    return nil;
                end);
                unique_nm_scan_result = (success and scan_result) or nil;
            end
            if (unique_nm_scan_result ~= nil) then
                last_unique_nm_track = unique_nm_scan_result;
                return unique_nm_scan_result;
            end
        end

        if (music_config.enable_nm) then
            -- Rate-limit the entity scan: only run every nm_scan_interval seconds
            local now = os.clock();
            if (now - nm_scan_timer >= nm_scan_interval) then
                nm_scan_timer = now;
                local success, scan_result = pcall(function()
                    local player_ent = GetPlayerEntity();
                    if (player_ent == nil) then return nil; end

                    -- Player engagement gate is already enforced by the
                    -- outer "status == 1" check before this scan ran. Inside
                    -- the scan, we only need to confirm the NM is engaged.
                    -- We do NOT check claim because claim values flicker
                    -- during fights (transferred between party members,
                    -- briefly cleared when no one is hitting the NM, etc.).
                    -- Caching nil during a flicker locked the addon into
                    -- regular battle music for the rate-limit window even
                    -- though the player was clearly fighting the NM.
                    --
                    -- The outer player-engagement gate plus NM-name match
                    -- against a curated list is sufficient: if a tracked NM
                    -- is engaged in your zone while you're also engaged,
                    -- it's overwhelmingly likely you're the one fighting it.
                    for j = 0, 2303 do
                        local ent = GetEntity(j);
                        if (ent ~= nil and ent.Name ~= nil and nm_list[ent.Name]) then
                            if (ent.Status == 1) then
                                if file_exists("NM_battle.wav") then
                                    current_state = "NM Battle: " .. ent.Name;
                                    return "NM_battle.wav";
                                end
                            end
                        end
                    end
                    return nil;
                end);
                nm_scan_result = (success and scan_result) or nil;
            end

            if (nm_scan_result ~= nil) then
                return nm_scan_result;
            end
        end

        -- Determine party suffix based on battle_mode setting
        local party_suffix = "";
        local mode = music_config.battle_mode or 0;
        local mode_str = "Mixed";
        local is_party_mode = false;
        
        if (mode == 1) then
            -- Force Solo
            party_suffix = "_solo";
            mode_str = "Solo";
            is_party_mode = false;
        elseif (mode == 2) then
            -- Force Party
            party_suffix = "_party";
            mode_str = "Party";
            is_party_mode = true;
        else
            -- Solo and Party mode: auto-detect by party size for default/random
            -- battle music. (Zone-specific battle WAVs with both _solo and
            -- _party variants use a 50/50 coin flip instead — see line 945.)
            local party_count = 0;
            local my_zone = party:GetMemberZone(0);
            
            for i = 0, 5 do
                local member_zone = party:GetMemberZone(i);
                if (member_zone ~= nil and member_zone > 0 and member_zone == my_zone) then
                    party_count = party_count + 1;
                end
            end
            
            if (party_count >= 2) then
                party_suffix = "_party";
                mode_str = string.format("Mixed/%d", party_count);
                is_party_mode = true;
            else
                party_suffix = "_solo";
                mode_str = "Mixed/Solo";
                is_party_mode = false;
            end
        end
        
        -- === RANDOM BATTLE MUSIC ===
        if (music_config.random_battle) then
            -- If party mode changed, pick new random track
            if (current_random_track ~= "" and random_track_is_party ~= is_party_mode) then
                current_random_track = "";  -- Force new selection
            end
            
            -- Pick random track if we don't have one
            if (current_random_track == "" or not file_exists(current_random_track)) then
                local random_track = get_random_battle_track(is_party_mode);
                if (random_track) then
                    current_random_track = random_track;
                    random_track_is_party = is_party_mode;
                end
            end
            
            -- Use random track if we have one
            if (current_random_track ~= "" and file_exists(current_random_track)) then
                current_state = string.format("Battle (Random, %s)", mode_str);
                return current_random_track;
            end
            -- Fall through to normal selection if random failed
        end

        -- === ZONE-SPECIFIC BATTLE ===
        -- Selection respects the user's mode setting:
        --   mode 0 (Solo and Party / Mixed): coin flip if both variants exist,
        --     else play whichever single variant is available.
        --   mode 1 (Force Solo): play _solo if it exists; if missing, fall
        --     back to _party with a labeled note rather than going silent.
        --   mode 2 (Force Party): mirror of mode 1.
        --
        -- Previously this block ALWAYS coin-flipped when both files existed,
        -- ignoring the user's explicit Solo/Party choice — that was the bug
        -- where Solo mode kept playing _party tracks.
        local zone_solo = string.format("battle_%d_solo.wav", zone_id);
        local zone_party = string.format("battle_%d_party.wav", zone_id);
        local has_zone_solo = file_exists(zone_solo);
        local has_zone_party = file_exists(zone_party);
        
        if (has_zone_solo or has_zone_party) then
            local chosen_track = nil;
            local chosen_label = nil;
            
            if (mode == 1) then
                -- Force Solo
                if (has_zone_solo) then
                    chosen_track = zone_solo;
                    chosen_label = "Solo";
                else
                    -- Solo requested but unavailable - play party as fallback
                    chosen_track = zone_party;
                    chosen_label = "Party (Solo missing)";
                end
            elseif (mode == 2) then
                -- Force Party
                if (has_zone_party) then
                    chosen_track = zone_party;
                    chosen_label = "Party";
                else
                    -- Party requested but unavailable - play solo as fallback
                    chosen_track = zone_solo;
                    chosen_label = "Solo (Party missing)";
                end
            else
                -- Mode 0: Solo and Party (mixed)
                if (has_zone_solo and has_zone_party) then
                    -- Both variants exist: 50/50 coin flip, locked per engagement
                    if (not zone_coinflip_active or zone_coinflip_zone ~= zone_id) then
                        zone_coinflip_zone = zone_id;
                        zone_coinflip_active = true;
                        if (math.random() < 0.5) then
                            zone_coinflip_suffix = "_solo";
                        else
                            zone_coinflip_suffix = "_party";
                        end
                        if (music_config.show_debug) then
                            print(chat.header('ZoneMusic'):append(chat.message(
                                string.format('Zone %d coin flip: %s', zone_id, zone_coinflip_suffix))));
                        end
                    end
                    chosen_track = string.format("battle_%d%s.wav", zone_id, zone_coinflip_suffix);
                    chosen_label = "Flip: " .. ((zone_coinflip_suffix == "_party") and "Party" or "Solo");
                elseif (has_zone_solo) then
                    chosen_track = zone_solo;
                    chosen_label = "Solo only";
                else
                    chosen_track = zone_party;
                    chosen_label = "Party only";
                end
            end
            
            if (chosen_track) then
                current_state = string.format("Battle (Zone %d, %s)", zone_id, chosen_label);
                return chosen_track;
            end
        end
        
        -- Zone-specific plain (no solo/party suffix)
        local zone_battle = string.format("battle_%d.wav", zone_id);
        if file_exists(zone_battle) then 
            current_state = string.format("Battle (Zone %d, %s)", zone_id, mode_str);
            return zone_battle; 
        end
        
        local default_party_battle = string.format("battle_default%s.wav", party_suffix);
        if file_exists(default_party_battle) then 
            current_state = string.format("Battle (Default, %s)", mode_str);
            return default_party_battle; 
        end
        
        if file_exists("battle_default.wav") then 
            current_state = string.format("Battle (Default, %s)", mode_str);
            return "battle_default.wav"; 
        end
    end

    -- === PRIORITY 3: IDLE ===
    if (music_config.enable_zone == false) then
        -- Zone theme turned off: the addon yields (the engine is still
        -- suppressed in covered zones, so this is silent idle). To hear the
        -- native engine theme, turn the whole addon off.
        current_state = "Idle (Game Music)";
        return "";
    end
    if (idle_track ~= "") then
        current_state = string.format("Idle (%s / Zone %d / %02d:00)", (is_night and "Night" or "Day"), zone_id, vana_hour);
    else
        current_state = "Idle (Game Music)";
    end
    return idle_track;
end

-- 6. Playback Engine
local zone_alias = "bard_zone";
local battle_alias = "bard_battle";

local current_zone_track = "";
local current_battle_track = "";
local current_zone_track_display = "";   -- resolved (MP3) filename shown in UI
local current_battle_track_display = ""; -- resolved (MP3) filename shown in UI
local zone_is_playing = false;
local zone_is_paused = false;
local battle_is_playing = false;
local idle_replay = {
    pending = false,
    track = "",
    due = 0,
    continuous = true,
};
-- True if the addon was playing its own audio (zone or battle) when the
-- current event began. Read by engine_silence() at event end to decide whether
-- to silence the engine .bgw. Set at event start, covers both zone (paused) and
-- battle (stopped) cases.
local mci_owned_before_event = false;


-- Set volume directly on an alias
local function set_volume(alias, vol)
    -- Clamp to valid MCI range. CRITICAL: MCI's `setaudio volume` accepts
    -- values from 0 (silence) to 1000 (full volume), NOT 0-100. A previous
    -- revision incorrectly clamped at 100, silently capping all output at
    -- 10% of MCI's actual maximum and producing music that played far
    -- quieter than file loudness suggested. music_config.volume is stored
    -- on the 0-1000 scale internally (GUI slider 0-100 multiplied by 10
    -- on save), so the upper bound here MUST be 1000.
    local int_vol = math.floor(vol);
    if (int_vol < 0) then int_vol = 0; end
    if (int_vol > 1000) then int_vol = 1000; end

    -- Dedupe: skip the MCI call if the integer volume hasn't changed since
    -- the last send for this alias. At 60-144 FPS, fade math produces many
    -- frames where the floored volume is identical. Sending the same
    -- 'setaudio volume' command repeatedly causes MCI thrash and audible
    -- stutter, especially when stacked with ducking which sets the same
    -- alias on the same frame.
    if (alias == zone_alias) then
        if (int_vol == last_sent_zone_vol) then return; end
        last_sent_zone_vol = int_vol;
    elseif (alias == battle_alias) then
        if (int_vol == last_sent_battle_vol) then return; end
        last_sent_battle_vol = int_vol;
    elseif (alias == jukebox.alias) then
        if (int_vol == jukebox.last_vol) then return; end
        jukebox.last_vol = int_vol;
    end

    local volume_cmd = string.format('setaudio %s volume to %d', alias, int_vol);
    winmm.mciSendStringA(volume_cmd, nil, 0, nil);
end

-- Apply final per-alias volume = base_volume * duck_multiplier.
-- Called once per frame from the tick loop AFTER update_fades and
-- update_ducking have updated their internal state. This is the single
-- source of truth for sending MCI volume commands. Dedupe in set_volume
-- ensures only actual changes hit MCI.
local function apply_volumes()
    if (zone_is_playing or zone_is_paused) then
        set_volume(zone_alias, zone_current_vol * duck_current_vol);
    end
    if (battle_is_playing) then
        set_volume(battle_alias, battle_current_vol * duck_current_vol);
    end
    if (jukebox.active) then
        set_volume(jukebox.alias, music_config.volume * duck_current_vol);
    end
end

local function clear_idle_replay()
    idle_replay.pending = false;
    idle_replay.track = "";
    idle_replay.due = 0;
end

local function get_mci_mode(alias)
    local result_buffer = ffi.new('char[32]');
    local result = winmm.mciSendStringA(
        string.format('status %s mode', alias),
        result_buffer,
        32,
        nil);
    if (result ~= 0) then return nil; end
    return string.lower(ffi.string(result_buffer));
end

-- Instant stop (no fade) - internal use
local function stop_zone_music_instant()
    if (zone_is_playing or zone_is_paused or idle_replay.pending) then
        winmm.mciSendStringA("stop " .. zone_alias, nil, 0, nil);
        winmm.mciSendStringA("close " .. zone_alias, nil, 0, nil);
        clear_idle_replay();
        zone_is_playing = false;
        zone_is_paused = false;
        zone_current_vol = 0;
        zone_target_vol = 0;
        zone_fading = false;
        pending_zone_stop = false;
        -- Clear stale track name for state-display consistency. The main
        -- loop's track-change check has a fallback elseif (`not zone_is_playing
        -- and desired_track ~= ""`) that would still restart music even
        -- without this clear, but the state header / debug page would
        -- otherwise show a misleading current track during the silent gap.
        current_zone_track = "";
        current_zone_track_display = "";
    end
end

local function stop_battle_music_instant()
    if (battle_is_playing) then
        winmm.mciSendStringA("stop " .. battle_alias, nil, 0, nil);
        winmm.mciSendStringA("close " .. battle_alias, nil, 0, nil);
        battle_is_playing = false;
        battle_current_vol = 0;
        battle_target_vol = 0;
        battle_fading = false;
        pending_battle_stop = false;
        battle_fade_override = 0;
        last_unique_nm_track = "";
        battle_is_silent = false;
        battle_silent_time = 0;
        -- FIX: Clear stale track name. Without this, after a fade-out
        -- completes (player disengaged), the next engagement on the same
        -- track sees desired_track == current_battle_track in the BATTLE
        -- MODE branch and takes no action, leaving battle music silent
        -- until zone change resets state. silence_battle_music() does
        -- NOT call this function, so dynamic mode's silent-resume is
        -- unaffected.
        current_battle_track = "";
        current_battle_track_display = "";
    end
end

-- Fade-aware stop functions
local function stop_zone_music()
    if (idle_replay.pending) then
        stop_zone_music_instant();
        return;
    end
    if (not zone_is_playing and not zone_is_paused) then return; end
    
    if (music_config.enable_fade and zone_current_vol > 0) then
        -- Start fade out
        zone_target_vol = 0;
        zone_fading = true;
        pending_zone_stop = true;
    else
        stop_zone_music_instant();
    end
end

local function stop_battle_music()
    if (not battle_is_playing) then return; end
    
    if (music_config.enable_fade and battle_current_vol > 0) then
        -- Start fade out
        battle_target_vol = 0;
        battle_fading = true;
        pending_battle_stop = true;
    else
        stop_battle_music_instant();
    end
end

-- Quick-fade stop for boss-kill / cutscene handoff. The victory event fires
-- 0x034 the moment a BCNM boss dies; a hard cut there is jarring on NM and
-- boss themes. A ~0.4s fade is short enough that the engine's event BGM is
-- not muddied, but long enough to avoid the click of an instant MCI close.
-- Falls back to instant when fades are disabled or volume is already 0.
local BATTLE_QUICK_FADE_DURATION = 0.4;
local function stop_battle_music_quick()
    if (not battle_is_playing) then return; end

    if (music_config.enable_fade and battle_current_vol > 0) then
        battle_target_vol = 0;
        battle_fading = true;
        pending_battle_stop = true;
        battle_fade_override = BATTLE_QUICK_FADE_DURATION;
    else
        stop_battle_music_instant();
    end
end

local function pause_zone_music()
    if (zone_is_playing) then
        if (music_config.enable_fade and zone_current_vol > 0) then
            -- Fade out then pause
            zone_target_vol = 0;
            zone_fading = true;
            -- We'll pause when fade completes (handled in update_fades)
        else
            winmm.mciSendStringA("pause " .. zone_alias, nil, 0, nil);
            zone_is_playing = false;
            zone_is_paused = true;
        end
    end
end

-- Instant pause with no fade. Used for cutscene/event handoff so the engine's
-- event BGM is audible immediately instead of overlapping a 1.5s fade-out.
-- Resume still fades back in via resume_zone_music().
local function pause_zone_music_fast()
    if (zone_is_playing) then
        winmm.mciSendStringA("pause " .. zone_alias, nil, 0, nil);
        zone_is_playing = false;
        zone_is_paused = true;
        zone_fading = false;
    end
end

-- ============================================================================
-- Engine music control via injected 0x05F (GP_SERV_COMMAND_MUSIC)
-- ----------------------------------------------------------------------------
-- The retail engine plays event/cutscene .bgw and, after a cutscene that
-- started an engine track, can keep that track playing (the "lingering BGM"
-- overlap) until the next real zone-in re-applies our 0x00A slot zeroing.
-- There is no per-event stop signal on the wire to intercept. The fix is to
-- COMMAND the engine directly: inject an incoming 0x05F music-change, exactly
-- as the engine's own runtime music changes arrive.
--
-- Payload layout confirmed from the SetBGM addon (Seth VanHeulen) and the LSB
-- GP_SERV_COMMAND_MUSIC binding (player:changeMusic(slot, track)):
--   byte  opcode = 0x5F
--   byte  size   = 0x01   (size in 4-byte words; 0x05F is an 8-byte packet)
--   byte  pad    = 0x00
--   byte  pad    = 0x00
--   u16   slot   (0=Day 1=Night 2=BattleSolo 3=BattleParty 4=Chocobo
--                 5=Death 6=MogHouse 7=Fishing)
--   u16   track  (client reads track as 8-bit; values >255 wrap)
-- Injected via Ashita v4: PacketManager:AddIncomingPacket(id, byte_table).
--
-- ENGINE_SILENCE_ID: the track value used to silence the engine. Track 0 is
-- NOT guaranteed silent on every build, so this is configurable and testable
-- live via /zm enginesilence <id>. Default 0; adjust after the live test.
local ENGINE_SILENCE_ID = 0;

local function inject_engine_music(slot, track)
    local ok = pcall(function()
        -- struct from common; build the 8-byte 0x05F payload as a byte table.
        local pkt = struct.pack('bbbbHH', 0x5F, 0x01, 0x00, 0x00, slot, track):totable();
        AshitaCore:GetPacketManager():AddIncomingPacket(0x5F, pkt);
    end);
    if (DEBUG_CUTSCENE) then
        if (ok) then
            zm_debug(
                string.format('Injected 0x05F slot=%d track=%d', slot, track));
        else
            zm_debug(
                'inject_engine_music failed (check Ashita v4 packet API)');
        end
    end
    return ok;
end

-- Silence the engine's resident day/night music immediately, without a
-- zone-in. Used on event end to kill a lingering cutscene .bgw.
--
-- GATED to covered zones only. In a zone WITH a cover (day_N/night_N.wav), the
-- engine was suppressed at zone-in and MCI owns audio, so silencing the engine
-- on event end is correct. In an UNCOVERED zone (no WAV), the engine is the
-- only audio source and is supposed to keep playing its own .bgw (e.g. Aht
-- Urhgan Whitegate -> music178) after a cutscene, so we must NOT silence it.
local function engine_silence()
    -- Gate on whether the addon owned its own audio (zone OR battle) going into
    -- this event. mci_owned_before_event is set at event start. If true, MCI is
    -- about to resume its track (zone or NM-named battle cover like
    -- eald_narche_battle.wav), so the engine's lingering cutscene .bgw must be
    -- silenced to avoid overlap. If false, the addon had nothing playing (a
    -- truly engine-only zone, e.g. Aht Urhgan Whitegate) -> leave the engine.
    --
    -- Replaces the earlier zone_is_paused check, which missed events entered
    -- mid-fight: battle music is STOPPED (not paused) at event start, so
    -- zone_is_paused stayed false and the engine overlapped the resuming battle
    -- WAV (The Celestial Nexus / Eald'narche phase transition, zone 181).
    if (not mci_owned_before_event) then
        if (DEBUG_CUTSCENE) then
            zm_debug(
                'Event end, addon owned no audio (engine-only zone) - engine left alone');
        end
        return;
    end
    inject_engine_music(0, ENGINE_SILENCE_ID);  -- Idle Day
    inject_engine_music(1, ENGINE_SILENCE_ID);  -- Idle Night
end

-- Restore the engine's REAL resident day/night music (captured at zone-in)
-- on cutscene start, so cutscenes that draw their music from the resident
-- zone slot (no runtime 0x05F of their own) have the correct track available.
-- Without this, a prior cutscene's engine_silence() leaves the slot at the
-- silence id, and the next resident-BGM cutscene plays silence instead of its
-- intended track (e.g. Chateau d'Oraguille for the 5-2 Trion scene).
-- Paired with engine_silence() on event end: slot holds real music DURING a
-- cutscene, silence during normal play. Covered zones only.
local function engine_restore()
    local covered = false;
    pcall(function()
        local zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
        -- Require BOTH: expansion enabled (engine is ours to drive here) AND
        -- the zone actually had its slots suppressed at zone-in. In a new-world
        -- (uncovered-expansion) zone we never touched the engine, so don't start.
        covered = zone_is_covered_expansion(zid) and has_zonemusic_assets(zid);
    end);
    if (not covered) then return; end
    if (saved_bgm_ids.day ~= nil) then
        inject_engine_music(0, saved_bgm_ids.day);
    end
    if (saved_bgm_ids.night ~= nil) then
        inject_engine_music(1, saved_bgm_ids.night);
    end
    if (DEBUG_CUTSCENE) then
        zm_debug(string.format(
            'Engine resident music restored for cutscene (day=%s night=%s)',
            tostring(saved_bgm_ids.day), tostring(saved_bgm_ids.night)));
    end
end

local function resume_zone_music()
    if (zone_is_paused) then
        -- Don't resume if we're pending stop
        if (pending_zone_stop) then return; end
        
        winmm.mciSendStringA("resume " .. zone_alias, nil, 0, nil);
        zone_is_paused = false;
        zone_is_playing = true;
        
        if (music_config.enable_fade) then
            -- Start at 0 and fade in
            zone_current_vol = 0;
            set_volume(zone_alias, 0);
            zone_target_vol = music_config.volume;
            zone_fading = true;
        else
            zone_current_vol = music_config.volume;
        end
    end
end

-- Instant resume at full volume, no fade-in. Used at event-music end so the
-- zone WAV is audible the moment the engine goes silent — no dead-air gap.
local function resume_zone_music_fast()
    if (zone_is_paused) then
        if (pending_zone_stop) then return; end
        winmm.mciSendStringA("resume " .. zone_alias, nil, 0, nil);
        zone_is_paused = false;
        zone_is_playing = true;
        zone_current_vol = music_config.volume;
        zone_target_vol = music_config.volume;
        zone_fading = false;
    end
end

-- True while the Mog House cover owns audio. The city track is paused under
-- moghouse.wav (battle channel) for the whole stay; nothing may resume it.
function jukebox.moghouse_owns_audio()
    return (music_config.enable_moghouse ~= false) and moghouse_active
        and file_exists("moghouse.wav");
end

-- A track the engine starts that the addon already covers in a zone it owns:
-- the zone's resident day/night theme, or Mog House track 126 when the
-- moghouse.wav cover is in use. Mirrors the 0x05F handler's resident/covered
-- block so the ZMHelper signal poll classifies engine starts the same way.
-- Only battle-slot packets and known battle ids are covered here. Actual
-- event windows always retain native music ownership.
jukebox.shadow_intro = {};

-- A reload inside the battlefield may precede any fresh zone packet.
-- Recover missing fields only; fresh packet values always win.
function jukebox.shadow_recover_bgm()
    if (AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) ~= 165) then return; end
    local saved = music_config.zone_bgm and music_config.zone_bgm['165'];
    if (saved == nil) then return; end
    for _, key in ipairs({'day', 'night', 'solo', 'party', 'mount'}) do
        if (saved_bgm_ids[key] == nil) then saved_bgm_ids[key] = saved[key]; end
    end
end

function jukebox.shadow_reset_intro()
    jukebox.shadow_intro = {};
end

-- Remember only the battlefield's own battle score heard inside an event.
-- The lock applies outside event windows so later actual scenes retain music.
function jukebox.shadow_note_intro(song)
    local player = GetPlayerEntity();
    if (not music_config.enabled or not music_config.enable_battle or player == nil
        or (player.StatusServer or 0) ~= 4
        or AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) ~= 165
        or not zone_is_covered_expansion(165)) then return; end
    jukebox.shadow_recover_bgm();
    if (song ~= nil and song > 0 and not jukebox.shadow_intro.locked
        and (song == saved_bgm_ids.solo or song == saved_bgm_ids.party)
        and (file_exists('shadow_battle.wav') or file_exists('shadow_battle_2.wav'))) then
        jukebox.shadow_intro.song = song;
    end
end

function jukebox.shadow_lock_intro()
    local player = GetPlayerEntity();
    if (player == nil or (player.StatusServer or 0) == 4) then return; end
    if (jukebox.shadow_intro.song ~= nil and not jukebox.shadow_intro.locked) then
        jukebox.shadow_intro.locked = true;
        if (DEBUG_CUTSCENE) then
            zm_debug('Shadow intro completed; repeat native music ' .. jukebox.shadow_intro.song
                .. ' locked outside events until next zone entry/logout');
        end
    end
end

function jukebox.shadow_covers(song, slot)
    if (jukebox.shadow_track() == nil) then return false; end
    jukebox.shadow_recover_bgm();
    if (slot ~= nil and slot ~= 2 and slot ~= 3) then return false; end
    return (song ~= nil and song > 0) and
        (song == 121 or song == saved_bgm_ids.solo or song == saved_bgm_ids.party);
end

-- The native battle stream can arrive before the boss becomes engaged.
-- During that gap the installed room theme owns audio, not an event handoff.
function jukebox.shadow_native_covers(song, slot)
    local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    local player = GetPlayerEntity();
    if (zone ~= 165 or not music_config.enabled or is_zoning or player == nil
        or player.Status == 2 or (player.StatusServer or 0) == 4
        or AshitaCore:GetMemoryManager():GetParty():GetMemberHPPercent(0) == 0
        or not zone_is_covered_expansion(zone)) then return false; end
    jukebox.shadow_recover_bgm();
    if (song == nil or song <= 0) then return false; end
    if (slot == nil or slot == 0 or slot == 1) then
        if (music_config.enable_zone ~= false
            and (song == saved_bgm_ids.day or song == saved_bgm_ids.night)
            and (file_exists('day_165.wav') or file_exists('night_165.wav'))) then
            return true;
        end
    end
    if (slot == nil or slot == 2 or slot == 3) then
        if (music_config.enable_battle and
            (song == saved_bgm_ids.solo or song == saved_bgm_ids.party
                or (jukebox.shadow_intro.locked and song == jukebox.shadow_intro.song))) then
            if (jukebox.shadow_covers(song, slot)) then return true; end
            return music_config.enable_zone ~= false
                and (file_exists('day_165.wav') or file_exists('night_165.wav'))
                and (file_exists('shadow_battle.wav') or file_exists('shadow_battle_2.wav'));
        end
    end
    return false;
end

function jukebox.shadow_prime_engine(reason)
    jukebox.shadow_recover_bgm();
    local changed = false;
    local ids = {saved_bgm_ids.day, saved_bgm_ids.night, saved_bgm_ids.solo, saved_bgm_ids.party};
    for slot = 0, 3 do
        if (jukebox.shadow_native_covers(ids[slot + 1], slot)) then
            inject_engine_music(slot, ENGINE_SILENCE_ID);
            changed = true;
        end
    end
    if (changed and DEBUG_CUTSCENE) then
        zm_debug('Shadow native slots primed: ' .. tostring(reason));
    end
    return changed;
end

-- Sample event exit each frame, before the helper poll and the 0.5s DJ tick.
-- Active scored events retain their normal end grace; this handles the
-- teleport/menu path which never opened a music handoff.
function jukebox.shadow_event_exit()
    local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    local player = GetPlayerEntity();
    if (zone ~= 165 or is_zoning or player == nil) then
        jukebox.shadow_was_event = false;
        return false;
    end
    local in_event = (player.StatusServer or 0) == 4;
    local leaving = jukebox.shadow_was_event and not in_event;
    jukebox.shadow_was_event = in_event;
    if (leaving and not handoff.active and not jukebox.active) then
        return jukebox.shadow_prime_engine('event exit');
    end
    return false;
end

function jukebox.is_covered_engine_track(song)
    if (song == nil or song <= 0) then return false; end
    local addon_owns_zone = false;
    pcall(function()
        addon_owns_zone = zone_is_covered_expansion(
            AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0));
    end);
    if (not addon_owns_zone) then return false; end
    if (jukebox.shadow_covers(song) or jukebox.shadow_native_covers(song)) then return true; end
    local rd, rn = saved_bgm_ids.day, saved_bgm_ids.night;
    if (((rd ~= nil) and (song == rd)) or ((rn ~= nil) and (song == rn))) then
        return true;
    end
    if (moghouse_zone_flag == true and song == jukebox.mh_native_song) then
        return (music_config.enable_moghouse ~= false) and file_exists("moghouse.wav");
    end
    return (song == 126) and (music_config.enable_moghouse ~= false)
        and file_exists("moghouse.wav");
end

-- End of an engine handoff: resume the WAV first (instant, full volume),
-- then re-silence the engine's slots so its lingering event track does not
-- ride under the WAV. Resume-before-silence closes the dead-air gap that the
-- old order (silence, then 1.5s fade-in from zero) produced at cutscene end.
-- engine_silence() is still gated on mci_owned_before_event, so engine-only
-- zones (no WAV cover) are left untouched.
local function end_handoff(resume_wav)
    -- Inside a Mog House the city track is parked under moghouse.wav; the
    -- next update_music tick restarts moghouse.wav instead.
    if (resume_wav and zone_is_paused and not jukebox.moghouse_owns_audio()
        and jukebox.shadow_track() == nil) then
        resume_zone_music_fast();
    end
    engine_silence();
    jukebox.shadow_lock_intro();
    jukebox.shadow_prime_engine('handoff end');
    handoff.active = false;
    handoff.saw_event = false;
    handoff.end_grace = 0;
    handoff.started = 0;
    handoff.pending034 = 0;
    current_state = "Playing";
    if (DEBUG_CUTSCENE) then
        zm_debug('Event music ended — MCI resumed, engine re-silenced');
    end
end

-- Begin an engine handoff: instant WAV pause, engine owns audio until the
-- SS=4 window closes (see update_music). Called from the 0x05F handler
-- (genuine event music) and from cinematic-zone event starts (script music
-- that never touches the wire).
local function begin_handoff(reason)
    if (handoff.active) then return; end
    handoff.shadow_song = nil;
    -- Event music wins over a jukebox preview. Stop it without resuming live
    -- music; the handoff below decides what happens to the zone track.
    if (jukebox.active) then jukebox.stop(false); end
    handoff.active = true;
    handoff.started = os.clock();
    handoff.saw_event = false;
    handoff.end_grace = 0;
    mci_owned_before_event =
        (zone_is_playing or zone_is_paused or battle_is_playing);
    -- The idle-replay timer is NOT cleared here: it keeps counting through the
    -- event and only fires when normal zone music returns.
    if (zone_is_playing and not zone_is_paused) then
        pause_zone_music_fast();
    end
    if (battle_is_playing) then
        stop_battle_music_instant();
        current_battle_track = "";
    end
    current_state = "Event Music (engine owns audio)";
    if (DEBUG_CUTSCENE) then
        zm_debug('HANDOFF begin — ' .. tostring(reason));
    end
end

-- Poll the ZMHelper signal file. Called every frame from the d3d tick;
-- rate-limited internally. Counter changes mean the engine started a
-- track: if the WAV owns audio here, hand off instantly.
local function poll_engine_signal()
    local now = os.clock();
    if ((now - engine_signal.last_poll) < ENGINE_SIGNAL_POLL) then return; end
    engine_signal.last_poll = now;

    if (engine_signal.path == nil) then
        local ok, p = pcall(function()
            return AshitaCore:GetInstallPath() .. '\\addons\\zonemusic\\engine_music.signal';
        end);
        if (not ok or p == nil) then return; end
        engine_signal.path = p;
    end

    local f = io.open(engine_signal.path, 'r');
    if (f == nil) then return; end
    local line = f:read('*l');
    f:close();
    if (line == nil) then return; end

    local counter, music_id = line:match('^(%d+)%s+(%-?%d+)');
    if (counter == nil) then return; end
    counter = tonumber(counter);
    music_id = tonumber(music_id) or -1;

    engine_signal.present = true;

    if (engine_signal.last_counter == nil) then
        -- First read after load: baseline only. The file may hold a stale
        -- entry from before the reload; reacting to it would false-pause.
        engine_signal.last_counter = counter;
        return;
    end

    if (counter ~= engine_signal.last_counter) then
        engine_signal.last_counter = counter;
        -- The game re-opens a playing track every fraction of a second, so
        -- this doubles as "the game is streaming music right now".
        engine_signal.last_change = now;
        engine_signal.last_music = music_id;
        -- Logged in every zone (not only ones the addon controls) so a
        -- silent fight can be traced to the exact track the game started.
        if (DEBUG_CUTSCENE) then
            local zid = 0;
            pcall(function() zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) or 0; end);
            zm_debug(string.format('Engine started music %d (zone %d)', music_id, zid));
        end
        jukebox.shadow_note_intro(music_id);
        -- Track 0 is the engine's silence slot; ignore.
        if (music_id == 0) then return; end
        -- Only react when the WAV actually owns audio here; engine-native
        -- zones (no cover / DAT-swapped boss fights) are the engine's turf.
        if (handoff.active) then return; end
        if (zone_is_playing or zone_is_paused or battle_is_playing) then
            -- A track the WAV already covers is not event music: the 0x05F
            -- handler blocks the same ids. Handing off for one paused the
            -- WAV, orphan-timed out 4s later, resumed the CITY track (even
            -- inside a Mog House), and the next counter change repeated it.
            -- Mog House 126 is exempt always; the resident theme only
            -- outside an event window, so scored cutscenes (SS=4) and
            -- cinematic zones keep handing off exactly as before.
            if (jukebox.is_covered_engine_track(music_id)) then
                local in_event = false;
                pcall(function()
                    local pe = GetPlayerEntity();
                    in_event = (pe ~= nil and (pe.StatusServer or 0) == 4)
                        or is_cinematic_zone(AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0));
                end);
                local mh_track = (music_id == 126)
                    or (moghouse_zone_flag == true and music_id == jukebox.mh_native_song);
                if (mh_track or jukebox.shadow_covers(music_id) or jukebox.shadow_native_covers(music_id) or not in_event) then
                    -- Keep the WAV; re-silence the engine's day/night slots
                    -- (what end_handoff did after the 4s detour), at most
                    -- once per engine_signal.resilence_interval.
                    if ((now - engine_signal.last_resilence) >= engine_signal.resilence_interval) then
                        engine_signal.last_resilence = now;
                        if (mh_track) then
                            -- Native Mog House theme: it lives in block 6
                            -- (also catches a reload inside a Mog House,
                            -- where no zone-in flag has been seen yet).
                            jukebox.mh_silence_slot();
                        else
                            inject_engine_music(0, ENGINE_SILENCE_ID);
                            inject_engine_music(1, ENGINE_SILENCE_ID);
                            if (jukebox.shadow_covers(music_id) or jukebox.shadow_native_covers(music_id, 2)
                                or jukebox.shadow_native_covers(music_id, 3)) then
                                inject_engine_music(2, ENGINE_SILENCE_ID);
                                inject_engine_music(3, ENGINE_SILENCE_ID);
                            end
                        end
                    end
                    if (DEBUG_CUTSCENE) then
                        zm_debug(string.format('Engine music %d is covered by the WAV - no handoff', music_id));
                    end
                    return;
                end
            end
            begin_handoff(string.format('engine opened music %d (ZMHelper)', music_id));
        end
    end
end

-- Effective idle-replay delay in seconds. Returns 0 (continuous looping) when
-- the "Idle Theme Replay" feature is toggled off, regardless of the stored value.
local function get_idle_replay_delay()
    if (music_config.enable_idle_replay ~= false) then
        return music_config.idle_replay_delay or 0;
    end
    return 0;
end

local function play_zone_music(track)
    if (track == "") then return; end
    clear_idle_replay();
    idle_replay.continuous = get_idle_replay_delay() <= 0;
    
    -- Don't start new track if we're fading out (wait for fade to complete)
    if (pending_zone_stop or (zone_fading and zone_target_vol == 0)) then
        return;
    end
    
    -- Close any existing zone music first
    if (zone_is_playing or zone_is_paused) then
        winmm.mciSendStringA("stop " .. zone_alias, nil, 0, nil);
        winmm.mciSendStringA("close " .. zone_alias, nil, 0, nil);
        zone_is_playing = false;
        zone_is_paused = false;
        zone_fading = false;
    end
    
    -- Reset dedupe cache after MCI close/reopen — see same comment in
    -- play_battle_music. Without this reset, the initial set_volume(0)
    -- below can be dedupe-skipped, leaving MCI at its default volume
    -- for the first frame of playback and producing a static blip on
    -- WAVs whose first samples have non-trivial amplitude.
    last_sent_zone_vol = -1;
    
    local resolved_track = resolve_audio_filename(track);
    if (resolved_track == nil) then
        print(chat.header('ZoneMusic'):append(chat.error('Zone music asset missing: ' .. track)));
        return;
    end
    local path = jukebox.sounds_dir() .. resolved_track;
    local mci_type = get_mci_type(resolved_track);
    
    local open_cmd = string.format('open "%s" type %s alias %s', path, mci_type, zone_alias);
    local result = winmm.mciSendStringA(open_cmd, nil, 0, nil);
    
    if (result ~= 0) then
        print(chat.header('ZoneMusic'):append(chat.error('Zone music could not open ' .. resolved_track .. ': ' .. jukebox.mci_error(result))));
        return;
    end
    
    -- Set initial volume (0 if fading, full if not)
    local start_vol = music_config.enable_fade and 0 or music_config.volume;
    set_volume(zone_alias, start_vol);
    zone_current_vol = start_vol;
    
    local play_cmd = string.format(
        (get_idle_replay_delay() > 0) and 'play %s' or 'play %s repeat',
        zone_alias);
    result = winmm.mciSendStringA(play_cmd, nil, 0, nil);
    
    if (result ~= 0) then
        print(chat.header('ZoneMusic'):append(chat.error('Zone music could not play ' .. resolved_track .. ': ' .. jukebox.mci_error(result))));
        winmm.mciSendStringA("close " .. zone_alias, nil, 0, nil);
        return;
    end
    
    zone_is_playing = true;
    zone_is_paused = false;
    current_zone_track = track;
    current_zone_track_display = resolved_track;
    if (DEBUG_CUTSCENE) then zm_debug('Zone track started: ' .. resolved_track); end
    
    -- Start fade in if enabled
    if (music_config.enable_fade) then
        zone_target_vol = music_config.volume;
        zone_fading = true;
    else
        zone_current_vol = music_config.volume;
    end
end

local function update_idle_replay()
    local replay_delay = get_idle_replay_delay();
    if (replay_delay <= 0 or not zone_is_playing or zone_is_paused or zone_fading) then
        return;
    end

    if (get_mci_mode(zone_alias) == 'stopped') then
        zone_is_playing = false;
        idle_replay.pending = true;
        idle_replay.track = current_zone_track;
        idle_replay.due = os.clock() + replay_delay;
    end
end

local function restart_idle_music()
    if (not idle_replay.pending) then return false; end

    local result = winmm.mciSendStringA('seek ' .. zone_alias .. ' to start', nil, 0, nil);
    if (result == 0) then
        result = winmm.mciSendStringA('play ' .. zone_alias, nil, 0, nil);
    end
    if (result ~= 0) then
        print(chat.header('ZoneMusic'):append(chat.error('Idle replay failed! Error: ' .. result)));
        stop_zone_music_instant();
        return false;
    end

    zone_is_playing = true;
    zone_is_paused = false;
    zone_current_vol = music_config.volume;
    zone_target_vol = music_config.volume;
    clear_idle_replay();
    return true;
end

local function play_battle_music(track)
    if (track == "") then return; end
    
    -- Don't start new track if we're fading out (wait for fade to complete)
    if (pending_battle_stop or (battle_fading and battle_target_vol == 0)) then
        return;
    end
    
    -- Close any existing battle music first
    if (battle_is_playing) then
        winmm.mciSendStringA("stop " .. battle_alias, nil, 0, nil);
        winmm.mciSendStringA("close " .. battle_alias, nil, 0, nil);
        battle_is_playing = false;
        battle_fading = false;
    end
    
    -- CRITICAL: Reset the dedupe cache. When MCI's alias is closed and
    -- reopened, the new MCI session has its own default volume (typically
    -- max). The dedupe in set_volume tracks the LAST SENT integer, not
    -- MCI's actual current value. If the cached value happens to match
    -- the value we're about to send (e.g., both 0 because we just stopped),
    -- the dedupe skips the MCI call and MCI plays the new file at its
    -- default max volume for the brief moment before fade math catches up.
    -- That manifests as a static blip on tracks whose first samples have
    -- significant amplitude. Resetting to -1 forces the next set_volume
    -- to actually transmit, locking MCI to 0 before `play` starts.
    last_sent_battle_vol = -1;
    
    local resolved_track = resolve_audio_filename(track);
    if (resolved_track == nil) then
        print(chat.header('ZoneMusic'):append(chat.error('Battle music asset missing: ' .. track)));
        return;
    end
    local path = jukebox.sounds_dir() .. resolved_track;
    local mci_type = get_mci_type(resolved_track);
    
    local open_cmd = string.format('open "%s" type %s alias %s', path, mci_type, battle_alias);
    local result = winmm.mciSendStringA(open_cmd, nil, 0, nil);
    
    if (result ~= 0) then
        print(chat.header('ZoneMusic'):append(chat.error('Battle music open failed! Error: ' .. result)));
        return;
    end
    
    -- Set initial volume (0 if fading, full if not)
    local start_vol = music_config.enable_fade and 0 or music_config.volume;
    set_volume(battle_alias, start_vol);
    battle_current_vol = start_vol;
    
    local play_cmd = string.format('play %s repeat', battle_alias);
    result = winmm.mciSendStringA(play_cmd, nil, 0, nil);
    
    if (result ~= 0) then
        print(chat.header('ZoneMusic'):append(chat.error('Battle music play failed! Error: ' .. result)));
        winmm.mciSendStringA("close " .. battle_alias, nil, 0, nil);
        return;
    end
    
    battle_is_playing = true;
    current_battle_track = track;
    current_battle_track_display = resolved_track;
    if (DEBUG_CUTSCENE) then zm_debug('Battle track started: ' .. resolved_track); end

    -- The addon is now playing its own battle cover (e.g. eald_narche_battle.wav
    -- or battle_163_party.wav). The engine may still be playing a .bgw on one of
    -- its music slots. BCNM/boss themes in particular play on the BATTLE slots
    -- (2 = solo, 3 = party), not day/night — e.g. Sacrificial Chamber (zone 163)
    -- starts its boss .bgw on the party battle slot at BCNM entry, which then
    -- overlaps our battle WAV on engage. Silence ALL FOUR engine slots (day,
    -- night, battle-solo, battle-party) so nothing the engine holds can bleed
    -- through under our cover, regardless of which slot the boss theme used.
    inject_engine_music(0, ENGINE_SILENCE_ID);  -- Idle Day
    inject_engine_music(1, ENGINE_SILENCE_ID);  -- Idle Night
    inject_engine_music(2, ENGINE_SILENCE_ID);  -- Battle Solo
    inject_engine_music(3, ENGINE_SILENCE_ID);  -- Battle Party
    if (DEBUG_CUTSCENE) then
        zm_debug(
            'Battle WAV started - engine silenced (slots 0-3) to clear overlap');
    end
    -- Start fade in if enabled
    if (music_config.enable_fade) then
        battle_target_vol = music_config.volume;
        battle_fading = true;
    else
        battle_current_vol = music_config.volume;
    end
end

-- Fade battle music to silent (vol 0) but keep the track alive for dynamic resume
local function silence_battle_music()
    if (not battle_is_playing or battle_is_silent) then return; end
    if (music_config.enable_fade) then
        battle_target_vol = 0;
        battle_fading = true;
        -- NOTE: pending_battle_stop is NOT set, so fade to 0 parks there without closing
    else
        set_volume(battle_alias, 0);
        battle_current_vol = 0;
    end
    battle_is_silent = true;
    battle_silent_time = os.clock();
end

-- Raise battle music from silence back to full volume (dynamic re-engage)
local function resume_battle_from_silence()
    if (not battle_is_playing or not battle_is_silent) then return; end
    battle_is_silent = false;
    battle_silent_time = 0;
    if (music_config.enable_fade) then
        battle_target_vol = music_config.volume;
        battle_fading = true;
    else
        battle_current_vol = music_config.volume;
        set_volume(battle_alias, music_config.volume);
    end
end

-- Update fades (called every frame)
-- === DUCKING SYSTEM ===
-- Check if voice addons have played recently
-- Signal file format: "timestamp" or "timestamp,duration"
local current_duck_duration = 2.5;  -- Dynamic duration from voice addons

local function check_duck_signal()
    local f = io.open(duck_signal_file, 'r');
    if f == nil then return 0, nil; end
    local content = f:read('*a');
    f:close();
    
    -- Parse format: "timestamp" or "timestamp,duration"
    local timestamp, duration;
    local comma_pos = string.find(content, ',');
    if comma_pos then
        timestamp = tonumber(string.sub(content, 1, comma_pos - 1)) or 0;
        duration = tonumber(string.sub(content, comma_pos + 1)) or nil;
    else
        timestamp = tonumber(content) or 0;
        duration = nil;
    end
    
    return timestamp, duration;
end

-- Update ducking state
local function update_ducking()
    if not music_config.enable_duck then 
        duck_current_vol = 1.0;
        return; 
    end
    
    -- Use os.clock() only for throttle check (same Lua state, safe)
    local clock_now = os.clock();
    if (clock_now - last_duck_check) < 0.05 then return; end
    
    -- Real dt from actual elapsed time (same Lua state clock, safe)
    local dt = (last_duck_update > 0) and (clock_now - last_duck_update) or 0.05;
    if dt < 0 then dt = 0; end
    if dt > 0.2 then dt = 0.2; end  -- Clamp against long frame spikes
    last_duck_check = clock_now;
    last_duck_update = clock_now;
    
    -- Use os.time() for cross-addon timestamp comparison (wall clock, consistent across Lua states)
    local voice_time, voice_duration = check_duck_signal();
    if voice_time > last_voice_time then
        last_voice_time = voice_time;
        if voice_duration and voice_duration > 0 then
            current_duck_duration = voice_duration;
        else
            current_duck_duration = music_config.duck_hold_time or 2.5;
        end
    end
    
    -- Determine if we should be ducked (os.time() on both sides now)
    local time_since_voice = os.time() - last_voice_time;
    local should_duck = (last_voice_time > 0) and (time_since_voice < current_duck_duration);
    
    -- Set target
    if should_duck then
        duck_target_vol = (music_config.duck_percent or 35) / 100;
    else
        duck_target_vol = 1.0;
    end
    
    -- Smooth transition using real dt
    local duck_speed = 1.0 / (music_config.duck_fade_speed or 0.3);
    
    if duck_current_vol < duck_target_vol then
        duck_current_vol = math.min(duck_current_vol + (duck_speed * dt), duck_target_vol);
    elseif duck_current_vol > duck_target_vol then
        duck_current_vol = math.max(duck_current_vol - (duck_speed * dt), duck_target_vol);
    end
    
    -- Volume application moved to apply_volumes() in the tick loop.
    -- This function is now state-only: it updates duck_current_vol toward
    -- duck_target_vol. apply_volumes handles the single MCI command per
    -- frame per alias, eliminating the previous double-set thrash where
    -- update_fades and update_ducking both wrote to the same alias on
    -- the same frame with different values.
end

local function update_fades()
    if (not music_config.enable_fade) then return; end
    
    local now = os.clock();
    
    -- Initialize on first call
    if (last_fade_time == 0) then
        last_fade_time = now;
        return;
    end
    
    local dt = now - last_fade_time;
    last_fade_time = now;
    
    -- Clamp dt to avoid huge jumps (and negative values)
    if (dt < 0) then dt = 0; end
    if (dt > 0.1) then dt = 0.1; end
    
    local fade_dur = music_config.fade_duration or 1.5;
    if (fade_dur < 0.1) then fade_dur = 0.1; end
    
    -- Volume change per second
    local vol_per_sec = music_config.volume / fade_dur;
    local vol_step = vol_per_sec * dt;
    
    -- Update zone volume (state-only; volume application happens in
    -- apply_volumes after both update_fades and update_ducking complete)
    if (zone_fading and (zone_is_playing or zone_is_paused)) then
        if (zone_current_vol < zone_target_vol) then
            -- Fading in
            zone_current_vol = zone_current_vol + vol_step;
            if (zone_current_vol >= zone_target_vol) then
                zone_current_vol = zone_target_vol;
                zone_fading = false;
            end
        elseif (zone_current_vol > zone_target_vol) then
            -- Fading out
            zone_current_vol = zone_current_vol - vol_step;
            if (zone_current_vol <= zone_target_vol) then
                zone_current_vol = zone_target_vol;
                zone_fading = false;
                
                -- Handle pending actions after fade out
                if (pending_zone_stop) then
                    stop_zone_music_instant();
                elseif (zone_target_vol == 0 and zone_is_playing) then
                    -- Pause after fade out
                    winmm.mciSendStringA("pause " .. zone_alias, nil, 0, nil);
                    zone_is_playing = false;
                    zone_is_paused = true;
                end
            end
        else
            zone_fading = false;
        end
    end
    
    -- Update battle volume (state-only; volume application happens in
    -- apply_volumes after both update_fades and update_ducking complete)
    if (battle_fading and battle_is_playing) then
        -- Quick-fade override (boss-kill cutscene handoff) shortens the
        -- effective duration for battle only; zone fade speed is unaffected.
        local battle_vol_step = vol_step;
        if (battle_fade_override > 0) then
            local override_dur = battle_fade_override;
            if (override_dur < 0.1) then override_dur = 0.1; end
            battle_vol_step = (music_config.volume / override_dur) * dt;
        end
        if (battle_current_vol < battle_target_vol) then
            -- Fading in
            battle_current_vol = battle_current_vol + battle_vol_step;
            if (battle_current_vol >= battle_target_vol) then
                battle_current_vol = battle_target_vol;
                battle_fading = false;
                battle_fade_override = 0;
            end
        elseif (battle_current_vol > battle_target_vol) then
            -- Fading out
            battle_current_vol = battle_current_vol - battle_vol_step;
            if (battle_current_vol <= battle_target_vol) then
                battle_current_vol = battle_target_vol;
                battle_fading = false;
                battle_fade_override = 0;
                
                -- Stop after fade out completes
                if (pending_battle_stop) then
                    stop_battle_music_instant();
                end
            end
        else
            battle_fading = false;
            battle_fade_override = 0;
        end
    end
end

local function stop_all_music()
    stop_zone_music();
    stop_battle_music();
end

local function stop_all_music_instant()
    stop_zone_music_instant();
    stop_battle_music_instant();
end

-- Per-second cutscene status logger. Extracted from update_music so that
-- function stays under Lua 5.1's 60-upvalue closure limit.
local function debug_log_status(status, status_server, animation)
    if (DEBUG_CUTSCENE) then
        local time_now = os.clock();
        if (time_now - (last_debug_log or 0) > 1.0) then
            local timer_val = (status4_start_time > 0) and (time_now - status4_start_time) or 0;
            zm_debug(string.format(
                'S=%d SS=%d A=%d handoff=%s timer=%.1f',
                status, status_server, animation, tostring(handoff.active), timer_val));
            last_debug_log = time_now;
        end
    end
end

-- update_music sits at LuaJIT's 60-upvalue limit, so state it touches only
-- through these helpers lives here instead of being captured there.

-- Clear event/cutscene tracking. Shared by the logout paths in update_music.
function jukebox.reset_event_tracking()
    jukebox.shadow:reset();
    jukebox.shadow_reset_intro();
    jukebox.shadow_poll = nil;
    jukebox.shadow_was_event = false;
    status4_start_time = 0;
    in_cutscene_from_packet = false;
    packet_event_pending_start = 0;
    was_in_cutscene = false;
    handoff.active = false;
    handoff.saw_event = false;
    handoff.end_grace = 0;
    handoff.started = 0;
    handoff.pending034 = 0;
end

-- Close the same-city transit window. On logout also forget Mog House state
-- so the next character starts clean.
function city_transit.clear(logout)
    city_transit.group = nil;
    city_transit.dest = nil;
    if (logout) then
        moghouse_zone_flag = nil;
        moghouse_active = false;
    end
end

-- SAME-CITY TRANSIT HOLD: between 0x00B and a settled arrival in the same
-- city group, an empty desired track means loading data is not ready yet
-- (entity, party zone, or HP% reading 0 -> false death). Returns true to
-- hold the WAV. The window settles once the entity is back in the 0x00A zone
-- with HP > 0, on real death status, or after LOGOUT_DEBOUNCE_ZONING; after
-- that an empty track is a real yield and update_music handles it.
function city_transit.hold(player_ent, party, zone_id)
    if (city_transit.group == nil) then return false; end
    local settled = false;
    pcall(function()
        if (player_ent ~= nil) then
            local st = player_ent.Status or 0;
            if (st == 2 or st == 3) then
                settled = true;
            elseif (city_transit.dest ~= nil and zone_id == city_transit.dest
                and (party:GetMemberHPPercent(0) or 0) > 0) then
                settled = true;
            end
        end
    end);
    if (DEBUG_CITY or DEBUG_CUTSCENE) then
        zm_debug(string.format('CITY transit "" zone=%s dest=%s settled=%s state=%s',
            tostring(zone_id), tostring(city_transit.dest),
            tostring(settled), tostring(current_state)));
    end
    if ((not settled) and (os.clock() - city_transit.started) < LOGOUT_DEBOUNCE_ZONING) then
        return true;
    end
    city_transit.clear(false);
    return false;
end

-- A real track in the destination zone closes the transit window.
function city_transit.arrive(zone_id)
    if (city_transit.group ~= nil and city_transit.dest ~= nil
        and zone_id == city_transit.dest) then
        city_transit.clear(false);
    end
end

local function update_music()
    if (not music_config.enabled) then
        stop_all_music();
        jukebox.mh_release();  -- native Mog House music returns with the addon off
        current_state = "Disabled";
        return;
    end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local current_zone_id = party:GetMemberZone(0);
    
    -- === EVENT / ENGINE-HANDOFF HANDLING (event-music rebuild) ===
    -- The old detection stack (10s StatusServer=4 fallback, 0x05F gate,
    -- Status==4 flash latch, resident passthrough) is retired. Packet
    -- captures proved: no FFXI event announces music unless a genuine 0x05F
    -- arrives, so there is nothing to pause for by default — the WAV plays
    -- through NPC talks, cutscenes, doors, and menus. Genuine event music is
    -- handled the instant it arrives, inside packet_in (see the 0x05F
    -- handler). This block only tracks the SS=4 window to know when an
    -- active handoff should END, and keeps the debug status line.
    local player_ent = GetPlayerEntity();
    if (player_ent ~= nil) then
        local status = player_ent.Status or 0;
        local status_server = player_ent.StatusServer or 0;
        local animation = player_ent.AnimationPlay or 0;
        local in_status4 = (status_server == 4);
        local now = os.clock();

        -- Track when the SS=4 window opens/closes (debug + handoff end logic).
        if (in_status4 and status4_start_time == 0) then
            status4_start_time = now;
        elseif (not in_status4) then
            status4_start_time = 0;
        end

        debug_log_status(status, status_server, animation);

        -- 0x034-opened event pause: fires everywhere when enabled, after
        -- the debounce, so scored cutscenes in ordinary zones stop
        -- overlapping the WAV. Doors/gates (also 0x034) dip a few
        -- seconds; accepted cost until the sound-hook plugin lands.
        if ((not handoff.active) and in_status4
            and (not engine_signal.present) -- ZMHelper supersedes this heuristic
            and (music_config.pause_on_event ~= false)
            and handoff.pending034 > 0
            and (now - handoff.pending034) >= EVENT034_PAUSE_DEBOUNCE) then
            begin_handoff('0x034 event exceeded debounce');
        end
        if ((not in_status4) and handoff.pending034 > 0
            and (now - handoff.pending034) > 8.0) then
            handoff.pending034 = 0; -- stale opener, no event materialized
        end

        -- Safety net: mid-event reload or missed packet in a cinematic
        -- zone — SS=4 alone is enough to hand off there. (The Sealion's Den
        -- log started 107s into the scene with the WAV still up; this line
        -- is what would have caught it.)
        if ((not handoff.active) and in_status4 and is_cinematic_zone(current_zone_id)) then
            begin_handoff('SS=4 in cinematic zone ' .. tostring(current_zone_id));
        end

        -- A battle stream can open just before the boss becomes engaged.
        -- Reclaim that orphan handoff immediately once its cover is ready;
        -- genuine event windows still use the existing event-end grace.
        if (handoff.active and not in_status4 and not handoff.saw_event
            and (jukebox.shadow_covers(handoff.shadow_song or engine_signal.last_music)
                or jukebox.shadow_native_covers(handoff.shadow_song or engine_signal.last_music))) then
            end_handoff(false);
        end

        if (handoff.active) then
            if (in_status4) then
                handoff.saw_event = true;
                handoff.end_grace = 0;
            else
                if (handoff.saw_event) then
                    -- SS left 4. Hold HANDOFF_END_GRACE before ending —
                    -- chained cutscenes blip SS to 0 for a single tick
                    -- between scenes (observed in capture) and must not
                    -- trigger a resume/re-pause stutter.
                    if (handoff.end_grace == 0) then
                        handoff.end_grace = now;
                    elseif ((now - handoff.end_grace) >= HANDOFF_END_GRACE) then
                        end_handoff(true);
                    end
                elseif ((now - handoff.started) >= HANDOFF_ORPHAN_TIMEOUT) then
                    -- Music packet arrived but no event window ever opened:
                    -- false alarm (or an instant scene). Undo the handoff.
                    end_handoff(true);
                end
            end
            if (handoff.active) then
                -- Engine owns audio: skip normal WAV management this tick.
                current_state = "Event Music (engine owns audio)";
                return;
            end
        end
    end

    local desired_track = get_desired_track();

    -- Stamp the last time we saw a real player entity. Used by the debounce
    -- below to distinguish transient zoning gaps from a real logout.
    local player_ent_check = GetPlayerEntity();
    if (player_ent_check ~= nil) then
        last_seen_logged_in = os.clock();
    end

    -- LOGOUT / CHARACTER-SELECT DETECTION (runs before everything else).
    -- Uses the game's own login status: GetPlayer():GetLoginStatus() is 0 at
    -- the character-select / login menu, 1 while logging in, 2 in-game. This
    -- is checked regardless of player-entity or desired_track state because at
    -- logout the player entity can LINGER non-nil for a moment and
    -- GetMemberZone still reports the last zone (e.g. 240) — which is why
    -- zone-based and entity-based detection both failed and the music hung
    -- until the 30s debounce. Status 0 is unambiguous: stop now, reset state,
    -- and the next character's login (status -> 2) re-resolves normally.
    -- Also fixes same-character relogin not stopping: that still passes
    -- through status 0 at the menu.
    do
        local login_status = nil;
        pcall(function()
            login_status = AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus();
        end);
        if (login_status ~= nil and login_status == 0) then
            if (zone_is_playing or zone_is_paused or battle_is_playing) then
                stop_all_music_instant();
            end
            jukebox.reset_event_tracking();
            previous_status = 0;
            previous_is_night = nil;
            is_zoning = false;
            zoning_from_city = nil;
            city_transit.clear(true);
            current_state = "Logged Out";
            return;
        end
    end

    -- Empty desired_track = addon explicitly yielded (e.g., death state
    -- where FFXI's native death.bgw should play uninterrupted). Stop any
    -- addon music here and skip the rest of the track-selection branches,
    -- which expect a non-empty filename.
    if (desired_track == nil or desired_track == "") then
        -- Same-city transit: hold through loading glitches (see city_transit.hold).
        if (city_transit.hold(player_ent_check, party, current_zone_id)) then
            return;
        end

        -- LOGOUT DEBOUNCE: if player_ent is nil, this could be either a
        -- real logout OR a transient gap during zoning. Hold music for
        -- LOGOUT_DEBOUNCE seconds before treating it as a real stop.
        -- If player_ent is non-nil and we still got an empty track, this
        -- is an intentional addon yield (death state) — stop immediately.
        if (player_ent_check == nil) then

            -- HOLD during transient nil gaps. Two cases keep the music alive
            -- instead of stopping (which clears current_zone_track and forces
            -- a 0:00 restart on arrival):
            --
            -- 1. Active zone-out (is_zoning, set on 0x00B, not yet cleared by
            --    0x00A): hold for the long zoning window.
            -- 2. Same-city continuity: previous_zone_id and the destination we
            --    are loading into belong to the same city group. This survives
            --    the 0x00B/0x00A race — 0x00A clears is_zoning before the
            --    player entity is ready, which previously dropped us onto the
            --    short 3s debounce and let slow capital loads (San d'Oria,
            --    Bastok, Windurst) stop the music mid-transition. We check the
            --    party-reported destination zone directly so it does not depend
            --    on is_zoning timing at all.
            local hold_for_city = false;
            pcall(function()
                local dest = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
                local dg = get_city_group(dest);
                local pg = get_city_group(previous_zone_id);
                if (dg ~= nil and pg ~= nil and dg == pg) then
                    hold_for_city = true;
                end
            end);

            if ((is_zoning and zoning_from_city ~= nil) or hold_for_city) then
                local time_since_logged_in = os.clock() - last_seen_logged_in;
                if (time_since_logged_in < LOGOUT_DEBOUNCE_ZONING) then
                    return;
                end
            end

            local time_since_logged_in = os.clock() - last_seen_logged_in;
            -- Tier the debounce by whether we know we're zoning. is_zoning
            -- is set true on 0x00B (zone-out) and cleared on 0x00A (zone-in).
            -- If we never receive 0x00A (true crash/disconnect during zone),
            -- the long timeout still fires and we correctly treat it as a
            -- logout.
            local debounce_window = is_zoning and LOGOUT_DEBOUNCE_ZONING or LOGOUT_DEBOUNCE_NORMAL;
            if (time_since_logged_in < debounce_window) then
                -- Within debounce window: hold music, treat as transient
                return;
            end
            -- Real logout confirmed (debounce expired with player_ent
            -- still nil). Reset all transient cutscene/event tracking so
            -- a switch to another character doesn't inherit stale state
            -- (e.g. status4_start_time from before, which would otherwise
            -- compute a huge time-since and falsely flag in_event_now on
            -- the next login if StatusServer == 4 momentarily during the
            -- loading frame).
            --
            -- NOTE: previous_zone_id is intentionally NOT reset here.
            -- Long zone loads on older capitals (Windurst, Bastok,
            -- San d'Oria — all of which have larger zone files than
            -- Jeuno) can keep player_ent == nil longer than the 3-second
            -- LOGOUT_DEBOUNCE during normal district transitions, NOT
            -- real logouts. Wiping previous_zone_id here caused the
            -- city-group continuity check to fail (current="windurst"
            -- vs previous=nil → restart music) when crossing district
            -- boundaries. Keeping the previous zone preserves the
            -- continuity check; a real character switch will update it
            -- naturally on the first frame in the new zone.
            -- Similarly previous_is_night and previous_status track
            -- player state that should reset on real logout — those
            -- still clear.
            jukebox.reset_event_tracking();
            previous_status = 0;
            previous_is_night = nil;
            -- Zoning flag clears on confirmed logout. If a real zone-in
            -- (0x00A) ever arrives later it'll just be a no-op set to false.
            is_zoning = false;
            city_transit.clear(false);
        end
        if (zone_is_playing or zone_is_paused or battle_is_playing) then
            stop_all_music_instant();
        end
        return;
    end

    city_transit.arrive(current_zone_id);

    -- Get current time for day/night change detection
    local vana_hour = get_vana_hour();
    local is_night = (vana_hour >= 18) or (vana_hour < 6);
    
    -- Check city group for zone transition logic
    local current_city_group = get_city_group(current_zone_id);
    local previous_city_group = get_city_group(previous_zone_id);
    local staying_in_city = (current_city_group ~= nil and current_city_group == previous_city_group);
    
    -- FIX: Detect day/night change separately
    local day_night_changed = (previous_is_night ~= nil and previous_is_night ~= is_night);
    previous_is_night = is_night;
    
    -- Check track types
    -- Death is no longer routed through this handler; FFXI plays the native
    -- death.bgw while the addon yields silence (see update_music's death
    -- state guard). The is_death_track variable and its branch were removed.
    --
    -- Fishing tracks are treated as "battle-like" (fishing_*.wav routed
    -- through the battle channel). This gives them automatic pause-zone-
    -- and-resume behavior identical to battle music: when fishing music
    -- starts, zone music pauses (preserving its position), and when it
    -- ends, zone music resumes from the same position. Battle and fishing
    -- are mutually exclusive at the player-status level (you can't fight
    -- and fish simultaneously), so reusing the channel is safe.
    local is_battle_track = (string.find(desired_track, "battle_") ~= nil)
                         or (desired_track:match("_battle%.wav$") ~= nil)
                         or (string.find(desired_track, "lowhp") ~= nil)
                         or (string.find(desired_track, "nm") ~= nil)
                         or (string.find(desired_track, "fishing") ~= nil)
                         or (string.find(desired_track, "moghouse") ~= nil)
                         or (string.find(desired_track, "chocobo") ~= nil);
    
    if (is_battle_track) then
        -- === BATTLE MODE ===
        -- The idle-replay timer is intentionally NOT cleared here: it keeps
        -- counting through the battle and only fires once normal zone music
        -- returns, so it can never interrupt battle music.

        -- Dynamic mode: if battle is silent and track hasn't changed, resume from silence
        if (battle_is_silent and desired_track == current_battle_track) then
            local resume_window = music_config.battle_resume_window or 60;
            if (os.clock() - battle_silent_time <= resume_window) then
                resume_battle_from_silence();
            else
                -- Window expired right as we re-engaged: restart clean
                stop_battle_music_instant();
                current_random_track = "";
                zone_coinflip_active = false;
                zone_coinflip_suffix = "";
                play_battle_music(desired_track);
                last_track_change = os.clock();
            end
        elseif (desired_track ~= current_battle_track) then
            local time_since_change = os.clock() - last_track_change;
            
            -- BOSS-KILL HANDOFF: a unique-NM theme was driving battle music
            -- and the NM scan no longer matches (boss dead/despawned), so the
            -- selection chain fell back to the generic zone battle track while
            -- the player is still flagged engaged for a few frames. Hard-
            -- restarting the generic theme here is the "music cuts off the
            -- instant the boss dies" bug. Quick-fade the NM theme instead and
            -- hold a short grace before any battle restart. A genuine NM→NM
            -- switch (Omega → Ultima) has unique_nm_scan_result ~= nil and
            -- takes the hard-restart path below, which is correct there.
            if (current_battle_track ~= "" 
                and current_battle_track == last_unique_nm_track
                and unique_nm_scan_result == nil) then
                stop_battle_music_quick();
                last_unique_nm_track = "";
                battle_kill_grace_until = os.clock() + BATTLE_KILL_GRACE;
            elseif (time_since_change >= TRACK_CHANGE_COOLDOWN or current_battle_track == "") then
                if (os.clock() >= battle_kill_grace_until) then
                    -- Track changed (zone change, mode change, etc.) - hard restart
                    stop_battle_music_instant();
                    play_battle_music(desired_track);
                    last_track_change = os.clock();
                end
            end
        end
        
        if (zone_is_playing and not zone_is_paused) then
            pause_zone_music();
        end
        
    else
        -- === ZONE/IDLE MODE ===
        
        if (battle_is_playing) then
            if (music_config.battle_dynamic) then
                local resume_window = music_config.battle_resume_window or 60;
                if (battle_is_silent) then
                    -- Already silent: check if the resume window has now expired
                    if (os.clock() - battle_silent_time > resume_window) then
                        stop_battle_music_instant();
                        current_battle_track = "";
                        current_random_track = "";
                        zone_coinflip_active = false;
                        zone_coinflip_suffix = "";
                    end
                    -- Still within window: do nothing, track keeps playing at vol 0
                else
                    -- Go silent: zone music resumes via the paused check below
                    silence_battle_music();
                end
            else
                -- Standard mode: kill it
                stop_battle_music();
                current_battle_track = "";
            end
        end
        
        local track_changed = (desired_track ~= current_zone_track);

        -- District continuity is handled by canonical track resolution
        -- (get_canonical_zone): every district in a city group resolves to the
        -- SAME desired_track filename, so a district hop yields
        -- desired_track == current_zone_track and track_changed is naturally
        -- false — no special same-city block needed, and none exists to get
        -- stuck on a stale foreign track after a logout/character switch.
        -- Day<->night swaps change the filename prefix (day_->night_), so they
        -- flip track_changed true on their own. The previously-present
        -- same-city suppression block was the source of the login-freeze bug
        -- and has been removed.
        
        local wants_continuous_replay = get_idle_replay_delay() <= 0;
        local replay_mode_changed =
            zone_is_playing and idle_replay.continuous ~= wants_continuous_replay;

        if (replay_mode_changed) then
            stop_zone_music_instant();
            play_zone_music(desired_track);
            previous_zone_id = current_zone_id;

        elseif (idle_replay.pending and not track_changed) then
            if (os.clock() >= idle_replay.due) then
                restart_idle_music();
            else
                current_state = string.format(
                    'Idle replay in %.0fs',
                    math.max(0, idle_replay.due - os.clock()));
            end

        elseif (track_changed) then
            stop_zone_music();
            play_zone_music(desired_track);
            previous_zone_id = current_zone_id;
        
        elseif (zone_is_paused) then
            resume_zone_music();
        
        elseif (not zone_is_playing and desired_track ~= "") then
            play_zone_music(desired_track);
            previous_zone_id = current_zone_id;
        end
    end
    
    current_track = desired_track;
end

-- Hand the zone's native tracks back to the engine: all five slots, exactly
-- as the zone packet carried them (a slot never captured is left alone
-- rather than forced to silence). Returns false when this zone's ids were
-- never captured, so the caller can say music returns on the next zone-in.
function jukebox.release_engine(zid)
    if (saved_bgm_ids.day == nil) then load_zone_bgm(zid); end
    if (saved_bgm_ids.day == nil) then return false; end
    local slots = { 'day', 'night', 'solo', 'party', 'mount' };
    for slot = 0, 4 do
        local id = saved_bgm_ids[slots[slot + 1]];
        if (id ~= nil) then pcall(inject_engine_music, slot, id); end
    end
    return true;
end

-- Silence all five engine slots so the addon's own track owns audio,
-- the same state a zone-in leaves behind in a covered zone.
function jukebox.silence_engine()
    for slot = 0, 4 do
        pcall(inject_engine_music, slot, ENGINE_SILENCE_ID);
    end
end

-- === MOG HOUSE MUSIC SLOT ===
-- The client keeps a dedicated Mog House music slot (0x05F block 6; LSB
-- setmusic.lua: "6=Moghouse", also what Symphonic Curator rewrites) and
-- starts it ITSELF whenever the zone-in packet flags a Mog House. The server
-- never sends music126 and the zone packet's slots 0-4 don't carry it, so
-- zeroing those never touched it: music126.bgw played under moghouse.wav.
-- While the cover owns the room, block 6 is set to silence; it is restored
-- on exit, when the feature is switched off, and on unload.
jukebox.MH_SLOT = 6;
jukebox.mh_native_song = 126;   -- last real block-6 track (126 unless the server set another)
jukebox.mh_slot_silenced = false;

-- Cover can own the Mog House in zone `zid`: feature on, asset present,
-- addon active in the parent city.
function jukebox.mh_cover_ready(zid)
    return (music_config.enable_moghouse ~= false) and file_exists("moghouse.wav")
        and zone_is_covered_expansion(zid);
end

function jukebox.mh_silence_slot()
    pcall(inject_engine_music, jukebox.MH_SLOT, ENGINE_SILENCE_ID);
    jukebox.mh_slot_silenced = true;
end

function jukebox.mh_release()
    if (not jukebox.mh_slot_silenced) then return; end
    pcall(inject_engine_music, jukebox.MH_SLOT, jukebox.mh_native_song or 126);
    jukebox.mh_slot_silenced = false;
end

-- Keep block 6 silent ahead of time. Silencing only on entry lets the client
-- start music126 first (two notes audible before the injected 0x05F lands),
-- so whenever the cover is usable the slot stays silenced: at load, on every
-- zone-in, and on exit. Block 6 is only heard inside a Mog House.
function jukebox.mh_prime()
    if ((music_config.enable_moghouse ~= false) and file_exists("moghouse.wav")) then
        jukebox.mh_silence_slot();
    end
end

-- Inside a Mog House (zone-in flag): hand the room to the cover immediately,
-- no Moogle scan needed, and silence the native slot.
function jukebox.mh_enter(zid)
    if (not jukebox.mh_cover_ready(zid)) then
        -- No cover here (e.g. addon off in this city): the primed silence
        -- would leave the room mute, so give the native theme back.
        jukebox.mh_release();
        return;
    end
    moghouse_active = true;
    jukebox.mh_silence_slot();
    if (DEBUG_CUTSCENE) then
        zm_debug(string.format('Mog House entered (zone %s) - cover owns audio, block 6 silenced', tostring(zid)));
    end
end

-- Re-apply ownership after the feature toggle changes mid-visit.
function jukebox.mh_sync()
    if (moghouse_zone_flag ~= true) then
        if (music_config.enable_moghouse == false) then
            moghouse_active = false;
            jukebox.mh_release();
        else
            jukebox.mh_prime();
        end
        return;
    end
    local zid = 0;
    pcall(function() zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0); end);
    if (jukebox.mh_cover_ready(zid)) then
        jukebox.mh_enter(zid);
    else
        moghouse_active = false;
        jukebox.mh_release();
    end
end

-- Battle-music watchdog for zones the game scores itself (the addon is not
-- driving audio there). When an event track is still playing as a fight
-- starts, the game can drop it without starting the battle slot, leaving
-- the fight silent. Seen in Empyreal Paradox: Dusk and Dawn plays through
-- the entry cutscene, stops at the engage, and phase 1 has no music, even
-- though the zone's battle slots hold that same track. If the game streams
-- nothing for 2 s after the player engages, re-send the zone's battle slots
-- once; the game then starts its battle music. A fight that already has
-- music (Promathia phase 2 keeps A Realm of Emptiness streaming) is never
-- touched. Needs ZMHelper, which is what reports the streaming.
jukebox.BATTLE_WATCHDOG_QUIET = 2.0;
function jukebox.battle_watchdog()
    local now = os.clock();
    if ((now - (jukebox.bw_poll or 0)) < 0.25) then return; end
    jukebox.bw_poll = now;

    local player = GetPlayerEntity();
    local engaged = (player ~= nil and player.Status == 1);
    if (not engaged) then
        jukebox.bw_engaged_at = nil;
        jukebox.bw_kicked = false;
        return;
    end
    if (not music_config.enabled or not engine_signal.present or jukebox.active) then return; end

    local zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) or 0;
    if (jukebox.ui ~= nil and jukebox.ui.owns_zone(zid)) then return; end  -- the addon plays here

    if (jukebox.bw_engaged_at == nil) then
        jukebox.bw_engaged_at = now;
        return;
    end
    if (jukebox.bw_kicked) then return; end
    local quiet_for = now - (engine_signal.last_change or 0);
    if ((now - jukebox.bw_engaged_at) < jukebox.BATTLE_WATCHDOG_QUIET or quiet_for < jukebox.BATTLE_WATCHDOG_QUIET) then
        return;
    end

    jukebox.bw_kicked = true;
    local solo, party = saved_bgm_ids.solo, saved_bgm_ids.party;
    if ((solo or 0) == 0 and (party or 0) == 0) then return; end  -- zone has no battle music
    if ((solo or 0) ~= 0) then pcall(inject_engine_music, 2, solo); end
    if ((party or 0) ~= 0) then pcall(inject_engine_music, 3, party); end
    if (DEBUG_CUTSCENE) then
        zm_debug(string.format('Battle watchdog: game silent %.1fs into a fight in zone %d, re-sent battle slots (solo=%s party=%s)',
            quiet_for, zid, tostring(solo), tostring(party)));
    end
end

-- Flip the per-zone opt-out and apply it right away if the player is
-- standing in an affected zone. Disabling hands the engine its own resident
-- tracks back (slots were zeroed at zone-in); enabling silences them again
-- the same way the init block does, then lets the DJ pick up.
local function set_zone_disabled(zone_id, disabled)
    if (zone_id == nil or zone_id == 0) then return; end
    if (music_config.disabled_zones == nil) then music_config.disabled_zones = {}; end
    local key = tostring(get_canonical_zone(zone_id));
    music_config.disabled_zones[key] = disabled and true or nil;
    pcall(settings.save);

    local here = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    local affects_here = (here ~= nil and here ~= 0
        and get_canonical_zone(here) == get_canonical_zone(zone_id));

    if (affects_here) then
        if (saved_bgm_ids.day == nil) then load_zone_bgm(here); end
        if (disabled) then
            -- Fade the cover out while the engine's own track comes back in.
            stop_all_music();
            jukebox.release_engine(here);
        elseif (zone_is_covered_expansion(here) and has_zonemusic_assets(here)) then
            jukebox.silence_engine();
            if (not jukebox.active) then pcall(update_music); end
        end
    end

    local name = AshitaCore:GetResourceManager():GetString('zones.names', zone_id) or ('Zone ' .. zone_id);
    local msg = disabled
        and string.format('Addon music OFF in %s. Game music plays there.', name)
        or  string.format('Addon music ON in %s.', name);
    if (affects_here and disabled and saved_bgm_ids.day == nil) then
        msg = msg .. ' Game music returns on your next zone-in.';
    end
    print(chat.header('ZoneMusic'):append(chat.message(msg)));
end

-- /zm zone [on|off|toggle|list]. Kept out of the command handler so that
-- closure stays clear of the upvalue limit.
local function handle_zone_command(args)
    local here = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    local sub = args[3] or 'toggle';
    if (sub == 'list') then
        local count = 0;
        for key, flag in pairs(music_config.disabled_zones or {}) do
            if (flag == true) then
                local zid = tonumber(key) or 0;
                print(chat.header('ZoneMusic'):append(chat.message(string.format('  %d  %s', zid,
                    AshitaCore:GetResourceManager():GetString('zones.names', zid) or '?'))));
                count = count + 1;
            end
        end
        if (count == 0) then
            print(chat.header('ZoneMusic'):append(chat.message('No zones are switched off.')));
        end
    elseif (sub == 'off') then
        set_zone_disabled(here, true);
    elseif (sub == 'on') then
        set_zone_disabled(here, false);
    else
        set_zone_disabled(here, not is_zone_disabled(here));
    end
end

-- Body of the settings tab (the pre-jukebox window pages). Lives outside
-- the render tick so neither closure hits the upvalue limit; the Crystal
-- shell in zm_ui.lua calls it with the page index and content width.
local function render_settings_page(page, CONTENT_W)
    local zm_page = { page };
    imgui.PushItemWidth(CONTENT_W - 10);

    local function zm_section(label)
        imgui.TextColored({0.45,0.65,0.85,1.0}, label);
        imgui.Separator();
    end

    -- PAGE 0: STATUS
    if zm_page[1] == 0 then
        zm_section('Volume');
        imgui.SetNextItemWidth(CONTENT_W - 50);
        if imgui.SliderInt('##zmvol', gui_state.volume, 0, 100) then
            music_config.volume = gui_state.volume[1] * 10;
            if zone_is_playing or zone_is_paused then
                if zone_fading then zone_target_vol = music_config.volume;
                else zone_current_vol = music_config.volume; set_volume(zone_alias, music_config.volume); end
            end
            if battle_is_playing and not battle_is_silent then
                if battle_fading then battle_target_vol = music_config.volume;
                else battle_current_vol = music_config.volume; set_volume(battle_alias, music_config.volume); end
            end
        end
        imgui.SameLine();
        imgui.TextColored({0.5,1.0,0.5,1.0}, string.format('%d%%', gui_state.volume[1]));

        imgui.Spacing();
        zm_section('Current State');
        imgui.TextColored({0.7,0.7,0.7,1.0}, current_state);

        local party = AshitaCore:GetMemoryManager():GetParty();
        local zone_id = party:GetMemberZone(0);
        local hp_per = party:GetMemberHPPercent(0);
        local vana_hour = get_vana_hour();
        local is_night = (vana_hour >= 18) or (vana_hour < 6);

        imgui.Text(string.format('Zone %d  |  HP %d%%  |  Vana %02d:00 (%s)',
            zone_id, hp_per, vana_hour, is_night and 'Night' or 'Day'));

        if in_crisis_mode then
            imgui.TextColored({1.0,0.4,0.4,1.0}, string.format('Crisis  |  Threshold %d%%', music_config.low_hp_threshold));
        else
            imgui.TextColored({0.5,0.5,0.5,1.0}, string.format('No crisis  |  Threshold %d%%', music_config.low_hp_threshold));
        end

        -- Per-zone opt-out for wherever the player is standing right now.
        -- It only means something while the addon itself is on.
        if (music_config.enabled) then
            local zone_on = { not is_zone_disabled(zone_id) };
            if imgui.Checkbox('Addon music in this zone', zone_on) then
                set_zone_disabled(zone_id, not zone_on[1]);
            end
        else
            imgui.TextColored({0.88,0.57,0.48,1.0}, 'ZoneMusic is off everywhere (switch at the top of the window).');
        end

        imgui.Spacing();
        zm_section('Now Playing');
        imgui.Spacing();
        local zone_display = (current_zone_track_display ~= "")
            and current_zone_track_display or current_zone_track;
        local zone_status = zone_is_playing and (zone_display .. ' ♪')
                         or (zone_is_paused and (zone_display .. ' ‖'))
                         or (idle_replay.pending and (zone_display .. ' · waiting'))
                         or '—';
        imgui.Text('Zone:   ' .. zone_status);
        if idle_replay.pending then
            imgui.TextColored({0.5,0.7,1.0,1.0},
                string.format('Replay in %.0fs', math.max(0, idle_replay.due - os.clock())));
        end

        if battle_is_playing then
            local battle_display = (current_battle_track_display ~= "")
                and current_battle_track_display or current_battle_track;
            if battle_is_silent then
                local rw = music_config.battle_resume_window or 60;
                local rem = math.max(0, rw - (os.clock() - battle_silent_time));
                imgui.TextColored({1.0,0.8,0.2,1.0},
                    string.format('Battle: %s (silent %.0fs)', battle_display, rem));
            else
                imgui.Text('Battle: ' .. battle_display);
            end
        end

        if duck_current_vol < 0.99 then
            imgui.TextColored({1.0,0.8,0.2,1.0},
                string.format('Ducked → %d%%', math.floor(duck_current_vol * 100)));
        end

    -- PAGE 1: BATTLE
    elseif zm_page[1] == 1 then
        zm_section('Battle Music');
        imgui.Checkbox('Enable Battle Music', gui_state.use_battle);

        imgui.Spacing();
        zm_section('Style');
        if imgui.RadioButton('Solo and Party', gui_state.battle_mode[1] == 0) then
            gui_state.battle_mode[1] = 0; music_config.battle_mode = 0;
        end
        imgui.SameLine();
        if imgui.RadioButton('Solo', gui_state.battle_mode[1] == 1) then
            gui_state.battle_mode[1] = 1; music_config.battle_mode = 1;
        end
        imgui.SameLine();
        if imgui.RadioButton('Party', gui_state.battle_mode[1] == 2) then
            gui_state.battle_mode[1] = 2; music_config.battle_mode = 2;
        end

        if imgui.Checkbox('Random Any Zone Battle Music', gui_state.random_battle) then
            music_config.random_battle = gui_state.random_battle[1];
            if gui_state.random_battle[1] then
                scan_battle_tracks();
                current_random_track = '';
            end
        end

        imgui.Spacing();
        zm_section('Dynamic Mode');

        local dyn_on = gui_state.battle_dynamic[1];
        local dyn_col = dyn_on and {0.1,0.5,0.1,1.0} or {0.35,0.35,0.35,1.0};
        local dyn_hov = dyn_on and {0.2,0.7,0.2,1.0} or {0.5,0.5,0.5,1.0};
        imgui.PushStyleColor(ImGuiCol_Button, dyn_col);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, dyn_hov);
        if imgui.Button(dyn_on and 'Dynamic ON' or 'Dynamic OFF', {CONTENT_W - 10, 22}) then
            gui_state.battle_dynamic[1] = not dyn_on;
            music_config.battle_dynamic = gui_state.battle_dynamic[1];
            if dyn_on and battle_is_silent then
                stop_battle_music_instant();
                current_battle_track = ''; current_random_track = '';
                zone_coinflip_active = false; zone_coinflip_suffix = '';
            end
        end
        imgui.PopStyleColor(2);

        if gui_state.battle_dynamic[1] then
            imgui.Text('Resume Window');
            imgui.SetNextItemWidth(CONTENT_W - 50);
            if imgui.SliderInt('##resumewin', gui_state.battle_resume_window, 10, 120) then
                music_config.battle_resume_window = gui_state.battle_resume_window[1];
            end
            imgui.SameLine();
            imgui.TextColored({0.5,0.5,0.5,1.0}, string.format('%ds', gui_state.battle_resume_window[1]));
            if battle_is_silent then
                local rw = music_config.battle_resume_window or 60;
                local rem = math.max(0, rw - (os.clock() - battle_silent_time));
                imgui.TextColored({1.0,0.8,0.2,1.0}, string.format('Re-engage: %.0fs left', rem));
            end
        end

        imgui.Spacing();
        imgui.Text('Battle Delay');
        imgui.SetNextItemWidth(CONTENT_W - 50);
        if imgui.SliderInt('##batdelay', gui_state.delay, 0, 100) then
            music_config.battle_delay = gui_state.delay[1] / 10;
        end
        imgui.SameLine();
        imgui.TextColored({0.5,0.5,0.5,1.0}, string.format('%.1fs', gui_state.delay[1] / 10));
        imgui.TextColored({0.5,0.5,0.5,1.0}, 'Delays battle/idle switching; it does not delay theme replays.');

    -- PAGE 2: PLAYBACK
    elseif zm_page[1] == 2 then
        zm_section('Zone Music');
        if imgui.Checkbox('Play zone themes', gui_state.use_zone) then
            music_config.enable_zone = gui_state.use_zone[1];
            clear_idle_replay();
            update_music();
        end
        imgui.TextColored({0.5,0.5,0.5,1.0}, 'Off silences the zone theme while the addon stays on.');
        imgui.Spacing();
        zm_section('Idle Theme Replay');
        if imgui.Checkbox('Enable idle replay', gui_state.use_idle_replay) then
            music_config.enable_idle_replay = gui_state.use_idle_replay[1];
            clear_idle_replay();
            update_music();
        end
        if gui_state.use_idle_replay[1] then
            imgui.TextColored({0.65,0.65,0.65,1.0}, 'After a zone theme finishes, wait before playing it again.');
            imgui.Spacing();
            imgui.Text('Replay after:');
            imgui.SameLine();
            imgui.SetNextItemWidth(CONTENT_W - 160);
            if imgui.SliderFloat('##idlereplaydelay', gui_state.idle_replay_delay_min, 0, 10, '%.1f') then
                music_config.idle_replay_delay = math.floor(gui_state.idle_replay_delay_min[1] * 60 + 0.5); -- minutes -> seconds
            end
            imgui.SameLine();
            imgui.TextColored({0.5,1.0,0.5,1.0}, 'minutes');
            if gui_state.idle_replay_delay_min[1] <= 0 then
                imgui.TextColored({0.5,0.5,0.5,1.0}, '0 keeps continuous looping.');
            else
                imgui.TextColored({0.5,0.5,0.5,1.0}, 'Idle themes play once, then wait before replaying.');
            end
        else
            imgui.TextColored({0.5,0.5,0.5,1.0}, 'Idle replay disabled — the zone theme loops continuously.');
        end

    -- PAGE 3: FADE & DUCK
    elseif zm_page[1] == 3 then
        zm_section('Fade');
        if imgui.Checkbox('Enable Fade In/Out', gui_state.use_fade) then
            music_config.enable_fade = gui_state.use_fade[1];
        end
        if gui_state.use_fade[1] then
            imgui.Text('Fade Duration');
            imgui.SetNextItemWidth(CONTENT_W - 50);
            if imgui.SliderInt('##fadedur', gui_state.fade_dur, 1, 50) then
                music_config.fade_duration = gui_state.fade_dur[1] / 10;
            end
            imgui.SameLine();
            imgui.TextColored({0.5,0.5,0.5,1.0}, string.format('%.1fs', gui_state.fade_dur[1] / 10));

            local fade_info = '';
            if zone_fading then
                fade_info = string.format('Zone %d%%→%d%%',
                    math.floor(zone_current_vol/10), math.floor(zone_target_vol/10));
            end
            if battle_fading then
                if fade_info ~= '' then fade_info = fade_info .. '  '; end
                fade_info = fade_info .. string.format('Battle %d%%→%d%%',
                    math.floor(battle_current_vol/10), math.floor(battle_target_vol/10));
            end
            if fade_info ~= '' then
                imgui.TextColored({0.5,0.8,1.0,1.0}, fade_info);
            end
        end

        imgui.Spacing();
        zm_section('Voice Ducking');
        if imgui.Checkbox('Duck when voices play', gui_state.use_duck) then
            music_config.enable_duck = gui_state.use_duck[1];
        end
        if gui_state.use_duck[1] then
            imgui.Text('Duck Level');
            imgui.SetNextItemWidth(CONTENT_W - 50);
            if imgui.SliderInt('##duckpct', gui_state.duck_pct, 0, 80) then
                music_config.duck_percent = gui_state.duck_pct[1];
            end
            imgui.SameLine();
            imgui.TextColored({0.5,0.5,0.5,1.0}, string.format('%d%%', gui_state.duck_pct[1]));
            if duck_current_vol < 0.99 then
                imgui.TextColored({1.0,0.8,0.2,1.0},
                    string.format('Ducked → %d%%', math.floor(duck_current_vol * 100)));
            end
        end

    -- PAGE 4: EVENTS
    elseif zm_page[1] == 4 then
        zm_section('Special Events');
        imgui.Checkbox('Play NM Music', gui_state.use_nm);

        imgui.Spacing();
        imgui.Checkbox('Play Low HP Music', gui_state.use_lowhp);
        if gui_state.use_lowhp[1] then
            imgui.Text('HP Threshold');
            imgui.SetNextItemWidth(CONTENT_W - 50);
            imgui.SliderInt('##hpthresh', gui_state.low_hp, 1, 50);
            imgui.SameLine();
            imgui.TextColored({0.5,0.5,0.5,1.0}, string.format('%d%%', gui_state.low_hp[1]));
        end

        imgui.Spacing();
        if imgui.Checkbox('Play Fishing Music', gui_state.use_fishing) then
            music_config.enable_fishing = gui_state.use_fishing[1];
        end
        if gui_state.use_fishing[1] then
            imgui.TextColored({0.5,0.5,0.5,1.0}, 'Small "!" bite: fishing_small.wav');
            imgui.TextColored({0.5,0.5,0.5,1.0}, 'Large "!!!" bite: fishing_large.wav');
            imgui.TextColored({0.5,0.5,0.5,1.0}, 'Fallback: fishing.wav (either type)');
            if fishing_active then
                imgui.TextColored({1.0,0.8,0.2,1.0},
                    string.format('Active: %s bite', fishing_bite_type or "?"));
            end
        end

        imgui.Spacing();
        if imgui.Checkbox('Play Mog House Music', gui_state.use_moghouse) then
            music_config.enable_moghouse = gui_state.use_moghouse[1];
            jukebox.mh_sync();
        end
        if gui_state.use_moghouse[1] then
            imgui.TextColored({0.5,0.5,0.5,1.0}, 'moghouse.wav');
            imgui.TextColored({0.5,0.5,0.5,1.0}, 'Plays only inside a Mog House (zone-in flag); native theme silenced');
            if moghouse_active then
                imgui.TextColored({1.0,0.8,0.2,1.0}, 'Active: in Mog House');
            end
        end

        imgui.Spacing();
        if imgui.Checkbox('Play Chocobo Music', gui_state.use_chocobo) then
            music_config.enable_chocobo = gui_state.use_chocobo[1];
        end
        if gui_state.use_chocobo[1] then
            imgui.TextColored({0.5,0.5,0.5,1.0}, 'chocobo.wav');
            imgui.TextColored({0.5,0.5,0.5,1.0}, 'Plays while mounted (Status 5)');
        end
    end
    imgui.PopItemWidth();
end

------------------------------------------------------------
-- 6.5 JUKEBOX
-- Browse every track in the sounds folder and preview it on demand. The
-- preview runs on its own MCI alias; live music is held (zone paused,
-- battle stopped) and picks back up when the preview ends, is stopped, or
-- the window closes.
------------------------------------------------------------

-- Friendly names for tracks the file name alone can't explain.
jukebox.labels = {
    nm_battle            = 'Notorious Monsters (shared theme)',
    eald_narche_battle   = 'Eald\'narche',
    eald_narche_belief   = 'Eald\'narche - Belief',
    belief_short         = 'Belief (short)',
    lowhp                = 'Low HP',
    fishing              = 'Fishing',
    fishing_small        = 'Fishing - small bite',
    fishing_large        = 'Fishing - large bite',
    moghouse             = 'Mog House',
    chocobo              = 'Chocobo',
    death                = 'Death',
    day_default          = 'Default day theme',
    night_default        = 'Default night theme',
    idle_default         = 'Default idle theme',
    battle_default       = 'Default battle theme',
};

-- Cutscene / menu tracks (musicNNN files). Titles are cleaned up from the
-- BGW name list, "where" says where the game plays them, and group sets the
-- section on the Cutscenes tab. Group follows the DAT folder the cover ships
-- in (sound = base, sound2 = Zilart, sound3 = Promathia), except title and
-- menu themes, which get their own section. hide = the same music already
-- exists as a zone track, so it is not listed twice.
jukebox.scene_groups = {
    menu  = { order = 1, title = 'Title & Menu' },
    base  = { order = 2, title = 'Base Game' },
    rotz  = { order = 3, title = 'Rise of the Zilart' },
    cop   = { order = 4, title = 'Chains of Promathia' },
    other = { order = 5, title = 'Other' },
};
jukebox.scene_info = {
    [34]  = { group = 'menu', title = 'We Are Vana\'diel',             where = 'Title screen' },
    [58]  = { group = 'menu', title = 'A New Direction',               where = 'Title screen' },
    [108] = { group = 'menu', title = 'Vana\'diel March',              where = 'Title screen' },
    [140] = { group = 'menu', title = 'Wings of the Goddess',          where = 'Title screen' },
    [179] = { group = 'menu', title = 'Vana\'diel March #4',           where = 'Title screen' },
    [242] = { group = 'menu', title = 'Unity',                         where = 'Title screen' },
    [153] = { group = 'menu', title = 'Prelude',                       where = 'Login and updating' },

    [111] = { group = 'base', title = 'Blackout',                      where = 'Knocked out' },
    [122] = { group = 'base', title = 'One Last Time',                 where = 'Mission and quest scenes' },
    [123] = { group = 'base', title = 'Hopelessness',                  where = 'Mission and quest scenes' },
    [124] = { group = 'base', title = 'Recollection',                  where = 'Mission and quest scenes' },
    [127] = { group = 'base', title = 'Anxiety',                       where = 'Mission and quest scenes' },
    [159] = { group = 'base', title = 'Sorrow',                        where = 'Mission and quest scenes' },
    [160] = { group = 'base', title = 'Repression',                    where = 'Memoro de la S^tono' },
    [161] = { group = 'base', title = 'Despair',                       where = 'Memoro de la S^tono' },
    [163] = { group = 'base', title = 'Sometime, Somewhere',           where = 'Mission and quest scenes' },
    [169] = { group = 'base', title = 'Regeneracy',                    where = 'Job Change Land' },
    [170] = { group = 'base', title = 'Buccaneers',                    where = 'Pirate attack on the ferry' },

    [181] = { group = 'rotz', title = 'Unnamed cutscene track',          where = 'Zilart cutscenes' },
    [194] = { group = 'rotz', title = 'Bloody Promises',               where = 'Raogrimm\'s theme' },
    [197] = { group = 'rotz', title = 'To the Heavens',                where = 'Kamlanaut, Zilart missions (unreleased track)' },
    [199] = { group = 'rotz', title = 'Grav\'iton',                    where = 'Zilart missions' },
    [200] = { group = 'rotz', title = 'Hidden Truths',                 where = 'Kamlanaut' },
    [201] = { group = 'rotz', title = 'End Theme',                     where = 'Zilart ending' },
    [202] = { group = 'rotz', title = 'Moongate',                      where = 'Memoro de la S^tono' },
    [203] = { group = 'rotz', title = 'Unnamed cutscene track',          where = 'Zilart cutscenes' },
    [204] = { group = 'rotz', title = 'Unnamed cutscene track',          where = 'Zilart cutscenes' },
    [205] = { group = 'rotz', title = 'Unnamed cutscene track',          where = 'Zilart cutscenes' },
    [206] = { group = 'rotz', title = 'Revenant Maiden',               where = 'Yve\'noile' },
    [212] = { group = 'rotz', title = 'Dash de Chocobo',               where = 'Chocobo riding' },
    [214] = { group = 'rotz', title = 'Eternal Oath',                  where = 'Wedding ceremony' },
    [256] = { group = 'rotz', title = 'Unnamed cutscene track',          where = 'Zilart cutscenes' },

    [137] = { group = 'cop',  title = 'A Realm of Emptiness',          where = 'Promathia final boss phase 2, Apocalypse Nigh (unreleased track)' },
    [223] = { group = 'cop',  title = 'Conflict: March of the Hero',   where = 'Conflict, your side winning' },
    [224] = { group = 'cop',  title = 'Dusk and Dawn',                 where = 'Promathia missions' },
    [231] = { group = 'cop',  title = 'Celestial Thunder',             where = 'Nag\'molada\'s theme' },
    [232] = { group = 'cop',  title = 'Ruler of the Skies',            where = 'Promathia missions' },
    [238] = { group = 'cop',  title = 'A New Morning',                 where = 'Promathia missions' },
    [229] = { hide = true },  -- Phanauet Channel / Manaclipper zone theme (day_1)
    [233] = { hide = true },  -- Al'Taieu zone theme (day_33, identical file)
    [245] = { hide = true },  -- Tavnazian Safehold zone theme (day_26)
};

function jukebox.zone_name(zid)
    local ok, name = pcall(function()
        return AshitaCore:GetResourceManager():GetString('zones.names', zid);
    end);
    if (ok and name ~= nil and name ~= '') then return name; end
    return 'Zone ' .. tostring(zid);
end

-- The jukebox list is grouped by expansion first, then by kind of area.
-- zone_expansion (above) only tags the new-world expansions the coverage
-- gate needs; the old world is split here into the three original releases.
jukebox.expansions = {
    base         = { order = 1, title = 'Base Game' },
    rotz         = { order = 2, title = 'Rise of the Zilart' },
    cop          = { order = 3, title = 'Chains of Promathia' },
    toau         = { order = 4, title = 'Treasures of Aht Urhgan' },
    wotg         = { order = 5, title = 'Wings of the Goddess' },
    abyssea      = { order = 6, title = 'Abyssea' },
    soa          = { order = 7, title = 'Seekers of Adoulin' },
    walkofechoes = { order = 8, title = 'Walk of Echoes' },
};

-- Old-world zones that shipped with Rise of the Zilart.
jukebox.rotz_zones = {
    [113] = true, [114] = true, [121] = true, [122] = true, [123] = true, [124] = true,  -- Teriggan, E. Altepa, Zi'Tah, Ro'Maeve, Yuhtunga, Yhoator
    [125] = true, [128] = true, [130] = true,                                            -- W. Altepa, Valley of Sorrows, Ru'Aun Gardens
    [153] = true, [154] = true, [159] = true, [160] = true, [163] = true, [168] = true,  -- Boyahda Tree, Dragon's Aery, Uggalepih, Den of Rancor, Sacrificial Chamber, Chamber of Oracles
    [174] = true, [176] = true, [177] = true, [178] = true, [179] = true, [180] = true,  -- Kuftal, Sea Serpent Grotto, Ve'Lugannon, Ru'Avitau, Stellar Fulcrum, La'Loff
    [181] = true, [201] = true, [202] = true, [203] = true, [205] = true, [207] = true,  -- Celestial Nexus, Cloisters, Ifrit's Cauldron
    [208] = true, [209] = true, [211] = true, [212] = true, [213] = true,                -- Quicksand Caves, Cloisters, Gustav Tunnel, Onzozo
    [226] = true, [247] = true, [250] = true, [251] = true, [252] = true,               -- Kazham airship, Rabao, Kazham, Hall of the Gods, Norg
};

-- Server zone types (1 city, 2 outdoors, 3 dungeon, 4 battlefield,
-- 5 Dynamis, 6 instanced), taken from the zone settings table.
jukebox.zone_types = {
    [0]=1, [1]=2, [2]=2, [3]=2, [4]=2, [5]=2, [6]=4, [7]=2, [8]=4, [9]=3, [10]=4, [11]=3,
    [12]=3, [13]=4, [14]=3, [15]=2, [16]=3, [17]=4, [18]=3, [19]=4, [20]=3, [21]=4, [22]=3, [23]=4,
    [24]=2, [25]=2, [26]=1, [27]=3, [28]=3, [29]=3, [30]=3, [31]=4, [32]=1, [33]=2, [34]=3, [35]=3,
    [36]=4, [37]=4, [38]=4, [39]=5, [40]=5, [41]=5, [42]=5, [43]=2, [44]=2, [45]=2, [46]=2, [47]=2,
    [48]=1, [50]=1, [51]=2, [52]=2, [53]=2, [54]=2, [55]=6, [56]=6, [57]=4, [58]=2, [59]=2, [60]=6,
    [61]=2, [62]=3, [63]=6, [64]=4, [65]=3, [66]=6, [67]=4, [68]=3, [69]=6, [70]=1, [71]=1, [72]=3,
    [73]=6, [74]=6, [75]=6, [76]=6, [77]=6, [78]=4, [79]=2, [80]=1, [81]=2, [82]=2, [83]=2, [84]=2,
    [85]=2, [86]=6, [87]=1, [88]=2, [89]=2, [90]=2, [91]=2, [92]=3, [93]=6, [94]=1, [95]=2, [96]=3,
    [97]=2, [98]=2, [99]=3, [100]=2, [101]=2, [102]=2, [103]=2, [104]=2, [105]=2, [106]=2, [107]=2, [108]=2,
    [109]=2, [110]=2, [111]=2, [112]=2, [113]=2, [114]=2, [115]=2, [116]=2, [117]=2, [118]=2, [119]=2, [120]=2,
    [121]=2, [122]=2, [123]=2, [124]=2, [125]=2, [126]=2, [127]=2, [128]=2, [129]=6, [130]=2, [131]=3, [132]=2,
    [134]=5, [135]=5, [136]=2, [137]=2, [138]=3, [139]=4, [140]=3, [141]=3, [142]=3, [143]=3, [144]=4, [145]=3,
    [146]=4, [147]=3, [148]=3, [149]=3, [150]=3, [151]=3, [152]=3, [153]=3, [154]=3, [155]=3, [156]=4, [157]=3,
    [158]=3, [159]=3, [160]=3, [161]=3, [162]=3, [163]=4, [164]=3, [165]=4, [166]=3, [167]=3, [168]=4, [169]=3,
    [170]=4, [171]=3, [172]=3, [173]=3, [174]=3, [175]=3, [176]=3, [177]=3, [178]=3, [179]=4, [180]=4, [181]=4,
    [182]=4, [183]=6, [184]=3, [185]=5, [186]=5, [187]=5, [188]=5, [189]=1, [190]=3, [191]=3, [192]=3, [193]=3,
    [194]=3, [195]=3, [196]=3, [197]=3, [198]=3, [199]=1, [200]=3, [201]=4, [202]=4, [203]=4, [204]=3, [205]=3,
    [206]=4, [207]=4, [208]=3, [209]=4, [211]=4, [212]=3, [213]=3, [214]=1, [215]=2, [216]=2, [217]=2, [218]=2,
    [219]=1, [222]=4, [223]=2, [224]=2, [225]=2, [226]=2, [227]=2, [228]=2, [229]=4, [230]=1, [231]=1, [232]=1,
    [233]=1, [234]=1, [235]=1, [236]=1, [237]=1, [238]=1, [239]=1, [240]=1, [241]=1, [242]=1, [243]=1, [244]=1,
    [245]=1, [246]=1, [247]=1, [248]=1, [249]=1, [250]=1, [251]=1, [252]=1, [253]=2, [254]=2, [255]=2, [256]=1,
    [257]=1, [258]=3, [259]=6, [260]=2, [261]=2, [262]=2, [263]=2, [264]=6, [265]=2, [266]=2, [267]=2, [268]=3,
    [269]=3, [270]=3, [271]=6, [272]=3, [273]=3, [274]=3, [280]=1, [284]=1, [285]=1, [287]=6, [288]=2, [289]=2,
    [294]=5, [295]=5, [296]=5, [297]=5,
};

-- Zones that exist but hold nothing worth browsing (staff-only areas).
jukebox.hidden_zones = { [0] = true, [210] = true };

jukebox.areas = {
    cities   = { order = 1, title = 'Cities' },
    towns    = { order = 2, title = 'Towns' },
    field    = { order = 3, title = 'Field' },
    dungeons = { order = 4, title = 'Dungeons' },
    battle   = { order = 5, title = 'Battlefields' },
    ships    = { order = 6, title = 'Ships & Airships' },
};

-- Returns expansion key and area key for a zone.
function jukebox.zone_category(zid)
    local exp = zone_expansion[zid];
    if (exp == nil) then
        if (jukebox.rotz_zones[zid]) then
            exp = 'rotz';
        elseif (zid >= 1 and zid <= 44) then
            exp = 'cop';
        else
            exp = 'base';
        end
    end

    local area;
    local ztype = jukebox.zone_types[zid] or 3;
    if ((zid >= 220 and zid <= 228) or zid == 1 or zid == 3 or zid == 46 or zid == 58 or zid == 59) then
        area = 'ships';     -- ships, airships, the barge and the Manaclipper
    elseif (zid == 32 or ztype == 4 or ztype == 5) then
        area = 'battle';    -- Sealion's Den is typed as a city server-side
    elseif (zid == 251) then
        area = 'dungeons';  -- Hall of the Gods is typed as a city server-side
    elseif (ztype == 1) then
        area = (zid >= 230 and zid <= 246) and 'cities' or 'towns';
    elseif (ztype == 2) then
        area = 'field';
    else
        area = 'dungeons';
    end
    return exp, area;
end

-- Event tracks the addon does not play in-game, so their cards say so.
jukebox.event_notes = {
    death = 'Preview only: on death the addon steps aside for the game\'s own death music',
};

-- Zones the game scores itself from the cover DATs, with correct phase
-- timing the addon cannot reproduce. Like Eald'narche, the addon never
-- takes these over: adding day_/battle_ files for them would silence the
-- game's battle slot and cut the phase-2 theme after the cutscene.
jukebox.game_zones = {
    [36] = {  -- Empyreal Paradox: Promathia (Dawn) and Apocalypse Nigh
        note = 'The game plays this zone\'s music from the cover DATs so the Promathia fight keeps its timing: Dusk and Dawn in phase 1, then A Realm of Emptiness from the cutscene on. The addon stays out of this zone on purpose. Do not add day_36 or battle_36 files: they would silence the fight.',
        tracks = {
            { label = 'Battle (phase 1)',    file = 'music224.mp3' },
            { label = 'Promathia (phase 2)', file = 'music137.mp3' },
        },
    },
};

jukebox.city_titles = {
    sandoria = 'San d\'Oria', bastok = 'Bastok', windurst = 'Windurst', jeuno = 'Jeuno',
    ronfaure = 'Ronfaure', gustaberg = 'Gustaberg', sarutabaruta = 'Sarutabaruta',
};

function jukebox.pretty(base)
    local s = base:gsub('_', ' ');
    return (s:gsub('(%a)([%w\']*)', function(a, b) return a:upper() .. b; end));
end

function jukebox.build_catalog()
    local sounds_path = jukebox.sounds_dir();
    -- base name (lowercase, no extension) -> on-disk filename; MP3 wins
    -- over a WAV master of the same name.
    local files = {};
    for _, ext in ipairs({ 'wav', 'mp3' }) do
        for _, entry in ipairs(jukebox.list_dir(sounds_path, '*.' .. ext)) do
            local base = entry.name:match('^(.*)%.[^.]+$');
            if (base ~= nil) then files[string.lower(base)] = entry.name; end
        end
    end

    -- Boss theme file -> mob names, straight from the NM override map.
    local boss_names = {};
    for mob, track in pairs(unique_nm_list) do
        if (type(track) == 'string') then
            local base = string.lower(track:match('^(.*)%.[^.]+$') or track);
            boss_names[base] = boss_names[base] and (boss_names[base] .. ' / ' .. mob) or mob;
        end
    end

    local zones_by_id = {};
    local catalog = { zones = {}, bosses = {}, events = {}, scenes = {}, other = {}, by_file = {} };

    local function add_track(list, base, file, label, sub)
        local item = { file = file, label = label, sub = sub };
        table.insert(list, item);
        catalog.by_file[string.lower(file)] = item;
        catalog.by_file[base .. '.wav'] = item; -- DJ tables still use WAV names
        return item;
    end

    for base, file in pairs(files) do
        local kind, zid = nil, nil;
        local d = base:match('^day_(%d+)$');
        local n = base:match('^night_(%d+)$');
        local bs = base:match('^battle_(%d+)_solo$');
        local bp = base:match('^battle_(%d+)_party$');
        local mus = base:match('^music(%d+)$');
        if (d) then kind, zid = 'day', tonumber(d);
        elseif (n) then kind, zid = 'night', tonumber(n);
        elseif (bs) then kind, zid = 'solo', tonumber(bs);
        elseif (bp) then kind, zid = 'party', tonumber(bp);
        end

        if (kind ~= nil) then
            local zone = zones_by_id[zid];
            if (zone == nil) then
                zone = { id = zid, tracks = {} };
                zones_by_id[zid] = zone;
            end
            zone.tracks[kind] = file;
        elseif (mus ~= nil) then
            local id = tonumber(mus);
            local info = jukebox.scene_info[id];
            if (info == nil or not info.hide) then
                local group = (info and info.group) or 'other';
                local title = (info and info.title) or BGW_NAMES[id] or ('Unnamed track ' .. id);
                local where = (info and info.where) and (info.where .. '  ·  ') or '';
                local item = add_track(catalog.scenes, base, file, title, where .. 'music' .. id);
                item.group = group;
                item.group_title = jukebox.scene_groups[group].title;
                item.sort = jukebox.scene_groups[group].order * 1000 + id;
            end
        elseif (boss_names[base] ~= nil or base:match('_battle$') or base:match('belief')) then
            local label = jukebox.labels[base] or boss_names[base] or jukebox.pretty(base:gsub('_battle$', ''));
            add_track(catalog.bosses, base, file, label, file);
        elseif (jukebox.labels[base] ~= nil) then
            add_track(catalog.events, base, file, jukebox.labels[base], jukebox.event_notes[base] or file);
        else
            add_track(catalog.other, base, file, jukebox.pretty(base), file);
        end
    end

    -- City groups collapse onto their canonical id, mirroring how the DJ
    -- resolves idle tracks (canonical file first, then any sibling).
    local merged = {};
    for zid, zone in pairs(zones_by_id) do
        if (not jukebox.hidden_zones[zid]) then
            local canon = get_canonical_zone(zid);
            local entry = merged[canon];
            if (entry == nil) then
                entry = { id = canon, tracks = {} };
                merged[canon] = entry;
            end
            for kind, file in pairs(zone.tracks) do
                if (zid == canon or entry.tracks[kind] == nil) then
                    entry.tracks[kind] = file;
                end
            end
        end
    end

    local sort_key = {};
    for canon, entry in pairs(merged) do
        local group = city_groups[canon];
        if (group ~= nil) then
            entry.name = jukebox.city_titles[group] or jukebox.pretty(group);
            local members = {};
            for zid, g in pairs(city_groups) do
                if (g == group) then table.insert(members, zid); end
            end
            table.sort(members);
            local names = {};
            for _, zid in ipairs(members) do table.insert(names, jukebox.zone_name(zid)); end
            entry.districts = table.concat(names, ' · ');
            entry.members = members;
        else
            entry.name = jukebox.zone_name(canon);
            entry.members = { canon };
        end
        local exp, area = jukebox.zone_category(canon);
        entry.expansion = exp;
        entry.expansion_title = jukebox.expansions[exp].title;
        entry.area = area;
        entry.category = jukebox.areas[area].title;
        entry.active_expansion = expansion_enabled[zone_expansion[canon] or 'base'] == true;
        sort_key[entry] = jukebox.expansions[exp].order * 100 + jukebox.areas[area].order;
        table.insert(catalog.zones, entry);
        for _, kind in ipairs({ 'day', 'night' }) do
            local f = entry.tracks[kind];
            if (f ~= nil) then
                local key = string.lower(f);
                catalog.by_file[key] = { zone = entry, kind = kind };
                catalog.by_file[(key:gsub('%.mp3$', '.wav'))] = catalog.by_file[key];
            end
        end
    end

    -- Zones whose music the game plays from the cover DATs (the addon stays
    -- out of them on purpose), listed so they are not missing from the
    -- jukebox. They get their own cards instead of day/night/battle.
    for zid, info in pairs(jukebox.game_zones) do
        if (merged[zid] == nil) then
            local cards = {};
            for _, track in ipairs(info.tracks) do
                local base = string.lower(track.file:match('^(.*)%.[^.]+$') or track.file);
                if (files[base] ~= nil) then
                    table.insert(cards, { label = track.label, file = files[base] });
                end
            end
            if (#cards > 0) then
                local exp, area = jukebox.zone_category(zid);
                local entry = {
                    id = zid, tracks = {}, custom = cards, game_played = true, note = info.note,
                    name = jukebox.zone_name(zid), members = { zid },
                    expansion = exp, expansion_title = jukebox.expansions[exp].title,
                    area = area, category = jukebox.areas[area].title, active_expansion = true,
                };
                sort_key[entry] = jukebox.expansions[exp].order * 100 + jukebox.areas[area].order;
                table.insert(catalog.zones, entry);
            end
        end
    end

    table.sort(catalog.zones, function(a, b)
        if (sort_key[a] ~= sort_key[b]) then return sort_key[a] < sort_key[b]; end
        return a.name < b.name;
    end);
    table.sort(catalog.scenes, function(a, b) return (a.sort or 0) < (b.sort or 0); end);
    for _, list in ipairs({ catalog.bosses, catalog.events, catalog.other }) do
        table.sort(list, function(a, b) return a.label < b.label; end);
    end

    -- Optional review list (review.lua next to the addon): a curated queue of
    -- tracks to listen through, e.g. the ones an audio scan flagged. The
    -- Review tab only appears while the file exists; players never see it.
    catalog.review, catalog.review_title, catalog.review_desc = {}, nil, nil;
    pcall(function()
        local path = jukebox.sounds_dir():gsub('sounds\\$', '') .. 'review.lua';
        local chunk = loadfile(path);
        if (chunk == nil) then return; end
        local data = chunk();
        if (type(data) ~= 'table' or type(data.items) ~= 'table') then return; end
        catalog.review_title = tostring(data.title or 'Review');
        catalog.review_desc = tostring(data.description or '');
        for _, entry in ipairs(data.items) do
            local base = type(entry.file) == 'string' and string.lower(entry.file:match('^(.*)%.[^.]+$') or entry.file) or nil;
            if (base ~= nil and files[base] ~= nil) then
                table.insert(catalog.review, {
                    file = files[base],
                    label = tostring(entry.label or files[base]),
                    sub = tostring(entry.note or files[base]),
                });
            end
        end
    end);

    jukebox.catalog = catalog;
    return catalog;
end

-- Friendly name for whatever file is playing live, for the footer.
function jukebox.describe(file)
    if (file == nil or file == '') then return nil; end
    local cat = jukebox.catalog;
    if (cat == nil) then return file; end
    local key = string.lower(file);
    local item = cat.by_file[key] or cat.by_file[(key:gsub('%.mp3$', '.wav'))];
    if (item == nil) then return file; end
    if (item.zone ~= nil) then
        return string.format('%s · %s', item.zone.name, item.kind == 'night' and 'Night' or 'Day');
    end
    return item.label;
end

function jukebox.mci(cmd, want_reply)
    if (not want_reply) then
        return winmm.mciSendStringA(cmd, nil, 0, nil);
    end
    local buf = ffi.new('char[64]');
    if (winmm.mciSendStringA(cmd, buf, 64, nil) ~= 0) then return nil; end
    return ffi.string(buf);
end

-- What happens when a preview reaches its end: stop and go back to live
-- music, loop the same track, or move on through the queue.
jukebox.MODES = { 'once', 'repeat', 'continue' };
jukebox.mode = 'continue';
jukebox.paused = false;
jukebox.queue = nil;   -- list of { file, label } the transport steps through
jukebox.index = 0;

function jukebox.stop(resume_live)
    if (jukebox.active or jukebox.file ~= '') then
        jukebox.mci('stop ' .. jukebox.alias);
        jukebox.mci('close ' .. jukebox.alias);
    end
    local owed = jukebox.paused_zone;
    jukebox.active = false;
    jukebox.paused = false;
    jukebox.file = '';
    jukebox.label = '';
    jukebox.length_ms = 0;
    jukebox.pos_time = nil;
    jukebox.paused_zone = false;
    jukebox.last_vol = -1;
    -- The queue survives a stop so Play can pick the list back up.
    -- Only resume what the preview itself paused, and never over event music.
    if (resume_live and owed and zone_is_paused and not handoff.active) then
        resume_zone_music();
    end
end

-- Open and start one queue entry. Live music is held the first time a
-- preview starts; switching between previews leaves it held.
function jukebox.open_track(item)
    local file = item.file;
    local resolved = resolve_audio_filename(file);
    if (resolved == nil) then
        print(chat.header('ZoneMusic'):append(chat.error('Jukebox: file not found: ' .. tostring(file))));
        jukebox.stop(true);
        return false;
    end

    if (jukebox.active) then
        jukebox.mci('stop ' .. jukebox.alias);
        jukebox.mci('close ' .. jukebox.alias);
    else
        if (zone_is_playing and not zone_is_paused) then
            pause_zone_music_fast();
            jukebox.paused_zone = true;
        end
        if (battle_is_playing) then
            stop_battle_music_instant();
        end
    end

    local path = jukebox.sounds_dir() .. resolved;
    local result = jukebox.mci(string.format('open "%s" type %s alias %s', path, get_mci_type(resolved), jukebox.alias));
    if (result ~= 0) then
        print(chat.header('ZoneMusic'):append(chat.error('Jukebox could not open ' .. resolved .. ': ' .. jukebox.mci_error(result))));
        jukebox.stop(true);
        return false;
    end
    jukebox.mci('set ' .. jukebox.alias .. ' time format milliseconds');
    jukebox.last_vol = -1;
    set_volume(jukebox.alias, music_config.volume * duck_current_vol);
    if (jukebox.mci('play ' .. jukebox.alias) ~= 0) then
        print(chat.header('ZoneMusic'):append(chat.error('Jukebox: could not play ' .. resolved)));
        jukebox.stop(true);
        return false;
    end

    jukebox.active = true;
    jukebox.paused = false;
    jukebox.pos_time = nil;
    jukebox.file = file;
    jukebox.label = item.label or file;
    jukebox.length_ms = tonumber(jukebox.mci('status ' .. jukebox.alias .. ' length', true) or '') or 0;
    jukebox.last_poll = os.clock();
    return true;
end

-- Start playing a list at a given entry; next/previous step through it.
function jukebox.play_queue(queue, index)
    if (queue == nil or queue[index] == nil) then return; end
    jukebox.queue = queue;
    jukebox.index = index;
    jukebox.open_track(queue[index]);
end

function jukebox.play(file, label)
    jukebox.play_queue({ { file = file, label = label } }, 1);
end

function jukebox.toggle_pause()
    if (not jukebox.active) then
        -- Nothing loaded: pick the queue back up where it stopped.
        local q = jukebox.queue;
        if (q ~= nil and q[jukebox.index] ~= nil) then
            jukebox.open_track(q[jukebox.index]);
        end
        return;
    end
    if (jukebox.paused) then
        -- 'play' with no range continues from the current (or seeked) spot.
        jukebox.mci('play ' .. jukebox.alias);
        jukebox.paused = false;
    else
        jukebox.mci('pause ' .. jukebox.alias);
        jukebox.paused = true;
    end
    jukebox.pos_time = nil;
end

function jukebox.seek(ms)
    if (not jukebox.active) then return; end
    local limit = math.max(0, (jukebox.length_ms or 0) - 250);
    ms = math.floor(math.max(0, math.min(ms or 0, limit)));
    jukebox.mci(string.format('seek %s to %d', jukebox.alias, ms));
    -- MCI parks the device after a seek; keep playing unless paused.
    if (not jukebox.paused) then
        jukebox.mci('play ' .. jukebox.alias);
    end
    jukebox.pos_ms = ms;
    jukebox.pos_time = os.clock();
    jukebox.last_poll = os.clock();
end

-- Skip within the queue. Previous restarts the current track first if it
-- has been playing for more than a few seconds, like any media player.
function jukebox.step(delta)
    local q = jukebox.queue;
    if (q == nil or #q == 0) then return; end
    if (delta < 0 and jukebox.active and jukebox.position_ms() > 3000) then
        jukebox.seek(0);
        return;
    end
    local i = jukebox.index + delta;
    if (i < 1) then i = #q; end
    if (i > #q) then i = 1; end
    jukebox.index = i;
    jukebox.open_track(q[i]);
end

function jukebox.cycle_mode()
    for i, m in ipairs(jukebox.MODES) do
        if (m == jukebox.mode) then
            jukebox.mode = jukebox.MODES[(i % #jukebox.MODES) + 1];
            return;
        end
    end
    jukebox.mode = 'continue';
end

-- A preview reached its natural end.
function jukebox.finished()
    if (jukebox.mode == 'repeat') then
        jukebox.seek(0);
    elseif (jukebox.mode == 'continue' and jukebox.queue ~= nil and jukebox.index < #jukebox.queue) then
        jukebox.step(1);
    else
        jukebox.return_live();
    end
end

-- The one real off switch. Off stops the addon's player and hands every
-- music slot back to the game, so the zone's own music plays, and later
-- zone-ins are left untouched. On takes the slots back and lets the DJ pick
-- the zone's track. The per-zone switch still applies on top of this.
function jukebox.set_addon_enabled(on)
    local here = 0;
    pcall(function() here = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) or 0; end);
    if (jukebox.active) then jukebox.stop(false); end

    local msg;
    if (on) then
        music_config.enabled = true;
        gui_state.enabled[1] = true;
        if (zone_is_covered_expansion(here) and has_zonemusic_assets(here)) then
            jukebox.silence_engine();
        end
        clear_idle_replay();
        pcall(update_music);
        msg = 'ZoneMusic ON.';
    else
        -- Ownership has to be read before the flag flips; afterwards every
        -- zone reports as uncovered.
        local owned = zone_is_covered_expansion(here) and has_zonemusic_assets(here);
        music_config.enabled = false;
        gui_state.enabled[1] = false;
        stop_all_music();
        msg = 'ZoneMusic OFF. Game music plays everywhere.';
        if (owned and not jukebox.release_engine(here)) then
            msg = msg .. ' This zone\'s music returns on your next zone-in.';
        end
        if (jukebox.detect_dat_overlay()) then
            msg = msg .. ' Covers installed as DATs (zonemusicDATS) still play until that overlay is removed in /pivot.';
        end
    end
    pcall(settings.save);
    print(chat.header('ZoneMusic'):append(chat.message(msg)));
end

-- True when XIPivot's overlay list includes the ZoneMusic cover DATs. Those
-- covers replace the game's own music files, so they keep playing even with
-- the addon off; the window warns about it. Read once, then cached.
function jukebox.detect_dat_overlay()
    if (jukebox.dat_overlay ~= nil) then return jukebox.dat_overlay; end
    jukebox.dat_overlay = false;
    local f = io.open(AshitaCore:GetInstallPath() .. 'config\\pivot\\pivot.ini', 'r');
    if (f == nil) then return false; end
    local in_overlays = false;
    for line in f:lines() do
        local section = line:match('^%s*%[([^%]]+)%]');
        if (section ~= nil) then
            in_overlays = (string.lower(section) == 'overlays');
        elseif (in_overlays and not line:match('^%s*;')) then
            local value = line:match('=%s*(.-)%s*$');
            if (value ~= nil and string.lower(value):find('zonemusic', 1, true)) then
                jukebox.dat_overlay = true;
            end
        end
    end
    f:close();
    return jukebox.dat_overlay;
end

-- The health check lives in zm_doctor.lua, loaded on demand and protected
-- like the window, so a missing copy only disables /zm doctor.
function jukebox.run_doctor()
    if (jukebox.doctor == nil) then
        local ok, mod = pcall(require, 'zm_doctor');
        jukebox.doctor = (ok and type(mod) == 'table') and mod or false;
        jukebox.doctor_error = (not ok) and tostring(mod) or nil;
    end
    if (jukebox.doctor == false) then return nil; end

    local helper, pivot = nil, nil;
    pcall(function() helper = AshitaCore:GetPluginManager():IsLoaded('ZMHelper'); end);
    pcall(function() pivot = AshitaCore:GetPolPluginManager():IsLoaded('pivot'); end);
    local env = {
        version = addon.version,
        install_path = AshitaCore:GetInstallPath(),
        sounds_path = jukebox.sounds_dir(),
        list_dir = jukebox.list_dir,
        mci = jukebox.mci,
        mci_error = jukebox.mci_error,
        ui_error = zm_ui.load_error,
        helper_loaded = helper,
        pivot_loaded = pivot,
        settings_repairs = jukebox.settings_repairs,
        errors = jukebox.errors,
        enabled = music_config.enabled,
        disabled_zones = music_config.disabled_zones,
        zone_name = jukebox.zone_name,
    };
    local report = jukebox.doctor.run(env);
    jukebox.last_report = report;
    pcall(function()
        local f = io.open(env.install_path .. 'logs\\zonemusic_report.txt', 'w');
        if (f ~= nil) then
            f:write(jukebox.doctor.format(report, env));
            f:close();
        end
    end);
    return report;
end

-- /zm doctor: run the check and print the problems in chat.
function jukebox.print_doctor()
    local report = jukebox.run_doctor();
    local header = chat.header('ZoneMusic');
    if (report == nil) then
        print(header:append(chat.error('The health check file (zm_doctor.lua) is missing: ' .. tostring(jukebox.doctor_error))));
        return;
    end
    if (report.failures + report.warnings == 0) then
        print(header:append(chat.success('Health check: everything looks good.')));
    else
        print(header:append(chat.message(string.format('Health check: %d problem(s), %d warning(s).',
            report.failures, report.warnings))));
        for _, item in ipairs(report.items) do
            if (item.level == 'fail' or item.level == 'warn') then
                local line = (item.level == 'fail' and 'PROBLEM: ' or 'Warning: ') .. item.title;
                print(header:append(item.level == 'fail' and chat.error(line) or chat.warning(line)));
                if (item.fix ~= nil) then print(chat.message('   Fix: ' .. item.fix)); end
            end
        end
    end
    print(chat.message('   Full report: logs\\zonemusic_report.txt (open the ZoneMusic window > Settings > Health for details).'));
end

-- Quiet check shortly after load: says nothing unless something is wrong.
function jukebox.startup_check()
    if (jukebox.startup_checked) then return; end
    if (os.clock() < jukebox.quiet_until) then return; end
    jukebox.startup_checked = true;
    local report = jukebox.run_doctor();
    if (report ~= nil and report.failures + report.warnings > 0) then
        print(chat.header('ZoneMusic'):append(chat.warning(string.format(
            'Found %d thing(s) that may affect your music. Type /zm doctor to see what and how to fix it.',
            report.failures + report.warnings))));
    end
end

-- End the preview and put the live zone music back right now. A plain stop
-- only resumes a track the preview paused; if the zone was sitting in its
-- idle-replay wait (or had nothing loaded), live music would stay silent
-- until the replay timer fired. Clearing the wait and running the DJ once
-- makes the zone theme come straight back.
function jukebox.return_live()
    jukebox.stop(true);
    if (music_config.enabled and not handoff.active) then
        clear_idle_replay();
        pcall(update_music);
    end
end

-- Cached for 0.1s: the window asks every frame, and MCI status calls at
-- frame rate are the same thrash set_volume's dedupe exists to avoid.
function jukebox.position_ms()
    if (not jukebox.active) then return 0; end
    local now = os.clock();
    if (jukebox.pos_time ~= nil and (now - jukebox.pos_time) < 0.1) then
        return jukebox.pos_ms or 0;
    end
    jukebox.pos_time = now;
    jukebox.pos_ms = tonumber(jukebox.mci('status ' .. jukebox.alias .. ' position', true) or '') or 0;
    return jukebox.pos_ms;
end

-- Per-frame housekeeping, rate-limited: handle the end of a track, the
-- window closing, and logout.
function jukebox.tick()
    if (not jukebox.active) then return; end
    if (not gui_state.is_open[1]) then
        jukebox.return_live();
        return;
    end
    local now = os.clock();
    if ((now - jukebox.last_poll) < 0.25) then return; end
    jukebox.last_poll = now;

    local login_status = nil;
    pcall(function()
        login_status = AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus();
    end);
    if (login_status == 0) then
        jukebox.stop(false);
        return;
    end

    local player = GetPlayerEntity();
    local status = (player ~= nil) and (player.Status or 0) or 0;
    if (status == 1 or status == 2 or status == 3) then
        jukebox.return_live();
        print(chat.header('ZoneMusic'):append(chat.message(
            (status == 1) and 'Preview stopped: you entered battle.' or 'Preview stopped.')));
        return;
    end

    -- A paused (or paused-then-seeked) device reports stopped too; only an
    -- unpaused stop is the end of the track.
    if (jukebox.paused) then return; end
    local mode = jukebox.mci('status ' .. jukebox.alias .. ' mode', true);
    if (mode == nil or string.lower(mode) == 'stopped') then
        jukebox.finished();
    end
end

-- Everything the Crystal window needs, in one place. zm_ui.lua never
-- touches addon locals directly; it reads this table.
jukebox.ui = {
    gui_state = gui_state,
    jukebox = jukebox,
    is_zone_disabled = is_zone_disabled,
    set_zone_disabled = set_zone_disabled,
    render_settings_page = render_settings_page,
    save_settings = save_settings,
    zone_name = jukebox.zone_name,
    catalog = function()
        return jukebox.catalog or jukebox.build_catalog();
    end,
    current_zone = function()
        local zid = 0;
        pcall(function() zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) or 0; end);
        return zid;
    end,
    canonical_zone = get_canonical_zone,
    -- True when the addon (not the engine) owns audio in this zone, so a
    -- preview plays alone rather than on top of the game's music.
    -- Cached for 2s because has_zonemusic_assets opens files on disk.
    owns_zone = function(zid)
        local c = jukebox.owns_cache;
        local now = os.clock();
        if (c == nil or c.zid ~= zid or (now - c.t) > 2.0) then
            c = { zid = zid, t = now,
                  value = zone_is_covered_expansion(zid) and has_zonemusic_assets(zid) };
            jukebox.owns_cache = c;
        end
        return c.value;
    end,
    live = function()
        return {
            enabled = music_config.enabled,
            state = current_state,
            zone_playing = zone_is_playing,
            zone_paused = zone_is_paused,
            battle_playing = battle_is_playing and not battle_is_silent,
            zone_track = current_zone_track_display ~= '' and current_zone_track_display or current_zone_track,
            battle_track = current_battle_track_display ~= '' and current_battle_track_display or current_battle_track,
        };
    end,
    set_addon_enabled = function(on) jukebox.set_addon_enabled(on); end,
    run_doctor = function() return jukebox.run_doctor(); end,
    doctor_report = function() return jukebox.last_report; end,
    report_error = function(source, err) jukebox.report_error(source, err); end,
    dat_overlay = function() return jukebox.detect_dat_overlay(); end,
    set_volume_percent = function(pct)
        music_config.volume = pct * 10;
        if (zone_is_playing or zone_is_paused) then
            if (zone_fading) then zone_target_vol = music_config.volume;
            else zone_current_vol = music_config.volume; end
        end
        if (battle_is_playing and not battle_is_silent) then
            if (battle_fading) then battle_target_vol = music_config.volume;
            else battle_current_vol = music_config.volume; end
        end
    end,
};

-- 7. Loops
local timer = 0;
ashita.events.register('d3d_present', 'bard_music_tick', function ()
    local ok, leaving_event = pcall(jukebox.shadow_event_exit);
    if (not ok) then
        jukebox.report_error('event exit', leaving_event);
    elseif (leaving_event and not jukebox.active) then
        timer = os.clock();
        jukebox.guard('music event exit', update_music);
    end
    jukebox.guard('engine signal', poll_engine_signal);
    jukebox.guard('idle replay', update_idle_replay);
    -- Update fades every frame (state-only, no MCI calls)
    jukebox.guard('fades', update_fades);

    -- Update ducking every frame (state-only, no MCI calls)
    jukebox.guard('ducking', update_ducking);

    -- Single source of truth for MCI volume commands. Applies
    -- final = base_volume * duck_multiplier per alias, with dedupe in
    -- set_volume to skip MCI when the integer value hasn't changed.
    -- This eliminates the per-frame double-set that was causing audible
    -- stutter during fade+duck overlap.
    jukebox.guard('volume', apply_volumes);

    if not init_complete then
        if init_timer == 0 then
            init_timer = os.clock();
        elseif (os.clock() - init_timer > 2.0) then
            init_complete = true;
            if music_config.enabled then
                -- On first load the engine is already playing the native BGW
                -- for the current zone because the 0x0A packet was never
                -- intercepted (addon wasn't loaded yet). Silence all five
                -- engine slots now so MCI owns audio cleanly, same as if a
                -- zone-in had just occurred.
                local party = AshitaCore:GetMemoryManager():GetParty();
                local current_zone_id = party:GetMemberZone(0);
                if (zone_is_covered_expansion(current_zone_id) and
                    has_zonemusic_assets(current_zone_id)) then
                    pcall(inject_engine_music, 0, ENGINE_SILENCE_ID);  -- Day
                    pcall(inject_engine_music, 1, ENGINE_SILENCE_ID);  -- Night
                    pcall(inject_engine_music, 2, ENGINE_SILENCE_ID);  -- Battle Solo
                    pcall(inject_engine_music, 3, ENGINE_SILENCE_ID);  -- Battle Party
                    pcall(inject_engine_music, 4, ENGINE_SILENCE_ID);  -- Mount
                end
                -- Pre-silence the Mog House slot so the first entry this
                -- session never lets music126 through.
                pcall(jukebox.mh_prime);
                pcall(update_music);
            end
        end
    end

    -- PER-FRAME cutscene local-lock latch. update_music runs only every 0.5s,
    -- but a real cutscene flashes the player's local Status == 4 for as little
    -- as a single game frame at its start. Sampling only every 0.5s would miss
    -- it and fail to pause. So we sample Status every frame here and latch.
    -- The latch is consumed/reset inside update_music's StatusServer=4 window
    -- handling. NPC dialogue never sets Status==4, so it never latches.
    pcall(function()
        local pe = GetPlayerEntity();
        if (pe ~= nil) then
            local ss = pe.StatusServer or 0;
            local st = pe.Status or 0;
            if (ss == 4 and st == 4) then
                cutscene_local_lock_seen = true;
            end
        end
    end);

    if (os.clock() - timer > 0.5) then
        timer = os.clock();
        -- A jukebox preview holds the DJ; live music picks up when it ends.
        if (not jukebox.active) then
            jukebox.guard('music', update_music);
        end

        -- Fishing state cleanup — status-based detection is the primary
        -- end-of-fishing signal. When the player's Status drops out of the
        -- 56-62 fishing range for FISHING_STATUS_GRACE seconds, fishing
        -- is treated as ended. This is FFXI's actual engine state and is
        -- immune to chat noise from nearby players, RoE notifications,
        -- etc. The grace period handles brief status flicker during
        -- stamina updates and minigame transitions.
        --
        -- The 60-second timeout below is a safety net only — should never
        -- normally fire if status detection is working.
        if (fishing_active) then
            local pe = GetPlayerEntity();
            if (pe ~= nil) then
                local s = pe.Status or 0;
                local in_fishing_range = (s >= 56 and s <= 62);
                if (not in_fishing_range) then
                    if (fishing_status_left == 0) then
                        fishing_status_left = os.clock();
                    elseif ((os.clock() - fishing_status_left) > FISHING_STATUS_GRACE) then
                        -- Confirmed exit from fishing state
                        if (DEBUG_FISHING) then
                            print(chat.header('ZoneMusic'):append(chat.message(
                                string.format('Fishing END (status) — Status=%d for >%.1fs', s, FISHING_STATUS_GRACE))));
                        end
                        fishing_active = false;
                        fishing_bite_type = nil;
                        fishing_last_message = 0;
                        fishing_status_left = 0;
                    end
                else
                    -- Back in fishing range — clear pending exit timer
                    fishing_status_left = 0;
                end
            end

            -- Defensive timeout safety net (should rarely fire if status
            -- detection is working). Catches edge cases like zoning
            -- during reel-in where status reads might be unreliable.
            if (fishing_active and fishing_last_message > 0 and
                (os.clock() - fishing_last_message) > FISHING_TIMEOUT) then
                fishing_active = false;
                fishing_bite_type = nil;
                fishing_last_message = 0;
                fishing_status_left = 0;
            end
        end
    end

    jukebox.guard('jukebox', jukebox.tick);
    jukebox.guard('battle watchdog', jukebox.battle_watchdog);
    jukebox.guard('health check', jukebox.startup_check);
    if (not gui_state.is_open[1]) then return; end
    jukebox.guard('window', zm_ui.render, jukebox.ui);
end);

-- === CHAT-BASED FISHING DETECTION ===
-- FFXI's player Status byte (56-62) covers all fishing phases but does NOT
-- distinguish small vs large fish — both report Status 57 (FishBite).
-- The actual size signal is the chat message the server sends on bite,
-- which uses a fixed set of strings (verified via SE patch notes [dev1008]
-- and player-confirmed reports).
--
-- BITE MESSAGES (start fishing music):
--   "Something caught the hook!"                    -> small (fishing_small)
--   "Something caught the hook!!!"                  -> large (fishing_large)
--   "You feel something pulling at your line."      -> small (fishing_small)
--   "Something clamps onto your line ferociously!"  -> large (fishing_large)
--
-- POST-BITE IDENTIFICATION MESSAGES (set type if unset, OR escalate):
--   "Your keen angler's senses tell you that this is the pull of a"
--      -> Critical bite reveal. If no bite_type yet (rare timing), default
--         to small. Does NOT downgrade an already-set large.
--   "This strength... You get the sense that you are on the verge of an
--    epic catch!"
--      -> Confirms an exceptionally large fish. Always sets large; can
--         escalate a previously-set small to large mid-fight.
--
-- RESOLUTION MESSAGES (end fishing music — verified canonical strings):
--   "Your line snaps!"
--   "Your rod breaks!"
--   "You lost your catch due to your lack of skill."
--   "You didn't catch anything."
--   "caught a"   /  "caught the"   (success — covers "Player caught a Fish")
--   "obtains"    (gil/item success variant)
--
-- ASSESSMENT MESSAGES (do NOT change state — mid-fight commentary):
--   "You have a good/bad/terrible feeling about this one"
--   "You're fairly sure you don't have enough skill"

ashita.events.register('text_in', 'zonemusic_shadow_text', function(e)
    if (e == nil or type(e.message) ~= 'string') then return; end
    if (AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) ~= 165) then return; end
    local msg = e.message;
    if (msg.strip_colors) then msg = msg:strip_colors(); end
    if (msg.strip_translate) then msg = msg:strip_translate(true); end
    jukebox.shadow:message(msg, os.clock());
    jukebox.shadow_poll = nil;
end);

ashita.events.register('text_in', 'zonemusic_fishing_text', function(e)
    if (not music_config.enable_fishing) then return; end
    if (e == nil or e.message == nil) then return; end

    local msg = e.message;
    if (type(msg) ~= "string") then return; end

    -- Strip color/translate codes if helpers are available. The fishing
    -- strings don't typically contain embedded codes mid-phrase, so raw
    -- match works in practice if helpers are absent.
    if (msg.strip_colors) then msg = msg:strip_colors(); end
    if (msg.strip_translate) then msg = msg:strip_translate(true); end

    -- ============================================================
    -- BITE DETECTION (large checked first — "!!!" substring would
    -- otherwise be caught by the "!" small-bite matcher)
    -- ============================================================
    if (msg:find("Something caught the hook!!!", 1, true)) then
        fishing_active = true;
        fishing_bite_type = "large";
        fishing_last_message = os.clock();
        return;
    end
    if (msg:find("Something clamps onto your line ferociously!", 1, true)) then
        fishing_active = true;
        fishing_bite_type = "large";
        fishing_last_message = os.clock();
        return;
    end
    if (msg:find("Something caught the hook!", 1, true)) then
        fishing_active = true;
        fishing_bite_type = "small";
        fishing_last_message = os.clock();
        return;
    end
    if (msg:find("You feel something pulling at your line.", 1, true)) then
        fishing_active = true;
        fishing_bite_type = "small";
        fishing_last_message = os.clock();
        return;
    end

    -- ============================================================
    -- POST-BITE IDENTIFICATION (only relevant while fishing is active)
    -- ============================================================
    if (fishing_active) then
        -- Epic catch detection — ALWAYS escalates to large. Whether
        -- the bite was originally small or already large, this confirms
        -- a remarkable fish and the swelling music is appropriate.
        if (msg:find("on the verge of an epic catch", 1, true)) then
            fishing_bite_type = "large";
            fishing_last_message = os.clock();
            return;
        end

        -- Angler's sense (critical bite identifies the fish). Defaults
        -- bite_type to small ONLY if not already set — a previous
        -- large/epic detection takes precedence and is preserved.
        if (msg:find("Your keen angler's senses tell you", 1, true)) then
            if (fishing_bite_type == nil) then
                fishing_bite_type = "small";
            end
            fishing_last_message = os.clock();
            return;
        end

        -- ============================================================
        -- RESOLUTION DETECTION (player-specific failure + success)
        --
        -- Tightened to require "You" / "Your" prefix where possible to
        -- prevent false positives from ambient NPC dialogue, player chat,
        -- or other players' loot/obtain messages firing nearby.
        --
        -- Generic patterns ("caught a", "obtains") were removed because
        -- they false-positive on other players' fishing catches in the
        -- same area, RoE notifications, item/gil obtainment text, and
        -- any system message containing those substrings.
        --
        -- Chat-based detection is the FAST path: fires immediately on
        -- the canonical message. The status-byte fallback in the tick
        -- loop catches edge cases (zone change during reel-in, etc.)
        -- where the resolution chat message might be missed.
        -- ============================================================
        local end_patterns = {
            "Your line snaps",
            "Your rod breaks",
            "You lost your catch",          -- "You lost your catch due to your lack of skill"
            "You didn't catch anything",
            "You caught a ",                -- Success: "You caught a [Fish]!"
            "You caught the ",              -- Success variant: "You caught the [Item]!"
        };
        for _, pattern in ipairs(end_patterns) do
            if (msg:find(pattern, 1, true)) then
                if (DEBUG_FISHING) then
                    print(chat.header('ZoneMusic'):append(chat.message(
                        string.format('Fishing END (chat) matched "%s"', pattern))));
                end
                fishing_active = false;
                fishing_bite_type = nil;
                fishing_last_message = 0;
                fishing_status_left = 0;
                return;
            end
        end
    end
end);


-- Packet 0x034 = Event Start (incoming from server)
-- Packet 0x052 = Event End / Menu Release (type > 0 = release)
-- StatusServer == 4 is the primary detection, packets are backup

ashita.events.register('packet_in', 'zonemusic_packet_in', function(e)
    -- === DIAGNOSTIC opcode tracer (temporary) ===
    if (DEBUG_CUTSCENE and DEBUG_TRACER) then
        local now = os.clock();
        -- Event-related signals keep the tracer window open.
        if (e.id == 0x034 or e.id == 0x032 or e.id == 0x033 or e.id == 0x05F
            or e.id == 0x052 or was_in_cutscene) then
            if (not tracer_event_active) then
                tracer_event_active = true;
                tracer_seen = {};
                zm_debug('--- TRACE begin ---');
            end
            tracer_last_activity = now;
        elseif (tracer_event_active and (now - tracer_last_activity) > TRACER_PREROLL) then
            tracer_event_active = false;
            zm_debug('--- TRACE end ---');
        end

        if (tracer_event_active) then
            -- Log each distinct opcode once per event.
            if (not tracer_seen[e.id]) then
                tracer_seen[e.id] = true;
                zm_debug(
                    string.format('OP 0x%03X', e.id));
            end
            -- Hex-dump candidate music/event packets (first 16 bytes).
            if (TRACER_DUMP_OPCODES[e.id]) then
                local bytes = {};
                pcall(function()
                    for i = 1, math.min(16, #e.data) do
                        bytes[#bytes + 1] = string.format('%02X', string.byte(e.data, i));
                    end
                end);
                zm_debug(
                    string.format('  0x%03X: %s', e.id, table.concat(bytes, ' ')));
            end
        end
    end

    -- 0x034 = Event Start (server tells client to start event/cutscene)
    -- Record pending timestamp; main loop promotes to active cutscene flag
    -- only after PACKET_EVENT_DELAY has elapsed. Brief events (gathering,
    -- item pickups, quick NPC dialog) will be cleared by 0x052 release
    -- before maturing, so music never pauses for them.

    if (e.id == 0x034) then
        if (CUTSCENE_EAGER_PAUSE) then
            -- Pause MCI immediately so the engine's event BGM (its own 0x05F,
            -- which we never touch) is audible from the first frame. A fast
            -- 0x052 release (handled below) cancels and resumes.
            eager_pause_start = os.clock();
            in_cutscene_from_packet = true;
            if (zone_is_playing and not zone_is_paused) then
                pause_zone_music_fast();
            end
            if (battle_is_playing) then
                stop_battle_music_instant();
                current_battle_track = "";
            end
            if (DEBUG_CUTSCENE) then
                zm_debug('EVENT START (0x034) - eager pause, engine owns BGM');
            end
        else
            packet_event_pending_start = os.clock();
            -- CINEMATIC ZONES: this zone's cutscenes carry client-side script
            -- music that never appears on the wire (capture-proven in Sealion's
            -- Den). Hand off the moment the event starts so the WAV is silent
            -- before the scene's first frame.
            local zid = nil;
            pcall(function()
                zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
            end);
            if (is_cinematic_zone(zid)) then
                begin_handoff(string.format('event start (0x034) in cinematic zone %s', tostring(zid)));
            else
                -- Cutscene-opener seen: arm the debounced pause (fires in
                -- update_music). Scored cutscenes in ordinary zones (e.g. the
                -- RoV intro in Windurst Walls) play CLIENT-SIDE script music
                -- that never touches the wire; 0x034 + debounce is the best
                -- packet-level signal available. NPC talks open with 0x032
                -- and never arm this.
                handoff.pending034 = os.clock();
                if (DEBUG_CUTSCENE) then
                    zm_debug('EVENT START packet (0x034) - pause armed, debounce ' .. EVENT034_PAUSE_DEBOUNCE .. 's');
                end
            end
        end
        return;
    end

    -- 0x05F = Runtime music change (event/cutscene/Mog House music). The
    -- engine plays the referenced .bgw; we do not touch this packet. Logged
    -- under cutscene debug so you can confirm whether a failing cutscene
    -- actually sends its own music (type/song printed) or relies on resident
    -- zone BGM (no 0x05F line during the cutscene). Offsets per the standard
    -- music-change layout (type uint16 @0x04, song uint16 @0x06); verify
    -- against a raw dump on this build if the values look wrong.
    if (e.id == 0x05F) then
        local mtype, song = -1, -1;
        pcall(function()
            mtype = struct.unpack('H', e.data, 0x04 + 1);
            song  = struct.unpack('H', e.data, 0x06 + 1);
        end);

        if (not e.injected) then
            engine_05f_seen_time = os.clock();
            jukebox.shadow_note_intro(song);

            -- Mog House slot (block 6) from the server, e.g. Symphonic
            -- Curator. Remember it as the native track for restore; while
            -- the cover owns the room, block it so it cannot play underneath.
            if (mtype == jukebox.MH_SLOT) then
                if (song > 0) then jukebox.mh_native_song = song; end
                local zid = 0;
                pcall(function() zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0); end);
                if (jukebox.mh_cover_ready(zid)) then
                    e.blocked = true;
                    jukebox.mh_slot_silenced = true;
                    if (DEBUG_CUTSCENE) then
                        zm_debug(string.format('Mog House slot 0x05F blocked (song=%d) - cover owns audio', song));
                    end
                end
                return;
            end

            -- NPC-TALK / RESIDENT RESEND vs REAL EVENT MUSIC.
            -- Retail-verified FFXI behavior: some events make the server
            -- resend the zone's RESIDENT track via 0x05F (NPC talks on
            -- retail). Our WAV already covers that track, so the resend is
            -- BLOCKED — otherwise the engine's copy starts under the WAV.
            -- Mog House music (track 126) is likewise blocked when a
            -- moghouse.wav cover exists, since the proximity detector plays
            -- the cover. Any OTHER genuine track is real event music: hand
            -- off instantly, right here in the packet handler, so the WAV
            -- is silent before the engine track's first note.
            -- Only block where the addon actually owns audio. Resident ids are
            -- captured in every zone now, and in an uncovered or disabled zone
            -- the engine's resend IS the music the player should hear.
            local addon_owns_zone = false;
            pcall(function()
                addon_owns_zone = zone_is_covered_expansion(
                    AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0));
            end);
            local rd, rn = saved_bgm_ids.day, saved_bgm_ids.night;
            local is_resident_resend =
                addon_owns_zone and (song >= 0)
                and (((rd ~= nil) and (song == rd)) or ((rn ~= nil) and (song == rn)));
            local is_covered_moghouse =
                addon_owns_zone and (song == 126)
                and (music_config.enable_moghouse ~= false)
                and file_exists("moghouse.wav");

            if (is_resident_resend or is_covered_moghouse or jukebox.shadow_covers(song, mtype)
                or jukebox.shadow_native_covers(song, mtype)) then
                e.blocked = true;
                if (DEBUG_CUTSCENE) then
                    zm_debug(string.format(
                        'Resident/covered 0x05F blocked (type=%d song=%d) — WAV keeps playing',
                        mtype, song));
                end
            else
                begin_handoff(string.format(
                    'genuine 0x05F event music (type=%d song=%d)', mtype, song));
                handoff.shadow_song = song;
            end
        else
            if (DEBUG_CUTSCENE) then
                zm_debug(string.format(
                    'MUSIC CHANGE (0x05F) type=%d song=%d injected=true | resident day=%s night=%s',
                    mtype, song, tostring(saved_bgm_ids.day), tostring(saved_bgm_ids.night)));
            end
        end
        return;
    end
    
    -- 0x052 = Menu Event Update / Release
    -- Type > 0 means release (end of event)
    if (e.id == 0x052) then
        -- Event release / menu update. Under the handoff design this packet
        -- is LOG-ONLY: releases fire mid-event on dialogue choices (observed
        -- in capture, 1.6s into a 10s talk), so acting on them here cut
        -- cutscene music dead. Handoff end is decided solely by the SS=4
        -- window closing (update_music, with grace).
        if (DEBUG_CUTSCENE) then
            local pkt_type = 0;
            pcall(function()
                pkt_type = string.byte(e.data_modified, 0x05) or 0;
            end);
            zm_debug(string.format('EVENT packet (0x052) type=%d handoff=%s',
                pkt_type, tostring(handoff.active)));
        end
        packet_event_pending_start = 0;
        return;
    end
    
    -- Zone packets clear cutscene state and update the zoning flag.
    -- 0x00A = Zone In  -> arrived in a new zone, zoning gap over
    -- 0x00B = Zone Out -> server told client we're leaving; player_ent
    --                     will go nil shortly. Set is_zoning so the
    --                     logout debounce uses the long timeout instead
    --                     of treating the gap as a real logout.
    if (e.id == 0x00A) then
        jukebox.shadow:reset();
        jukebox.shadow_reset_intro();
        jukebox.shadow_poll = nil;
        jukebox.shadow_was_event = false;
        -- Wipe the previous zone's resident ids, then load any STORED ids
        -- for the incoming zone (reload-survival fallback). The fresh packet
        -- capture in suppress_engine_bgm_in_zone_packet overwrites both.
        pcall(function()
            local zid = struct.unpack('H', e.data, 0x30 + 1);
            saved_bgm_ids.day, saved_bgm_ids.night = nil, nil;
            saved_bgm_ids.solo, saved_bgm_ids.party, saved_bgm_ids.mount = nil, nil, nil;
            load_zone_bgm(zid);
        end);

        -- Engine BGM suppression: zero out music slots for zones where
        -- ZoneMusic has assets. Zones without assets pass through and
        -- play retail music normally.
        pcall(suppress_engine_bgm_in_zone_packet, e);

        -- Mog House flag + same-city transit bookkeeping for the arrival.
        pcall(function()
            local zid = struct.unpack('H', e.data, 0x30 + 1);
            -- 1 = inside a Mog House. LSB writes 2 on every ordinary zone-in,
            -- so "nonzero" is not "inside" (zone_in.cpp, CZoneInPacket).
            moghouse_zone_flag = (struct.unpack('b', e.data, 0x80 + 1) == 1);
            if (moghouse_zone_flag) then
                -- Inside: the cover owns the room from the first frame and
                -- the client's native Mog House slot is silenced.
                jukebox.mh_enter(zid);
            else
                -- Left (or never entered) a Mog House: end its music now,
                -- and keep the native slot silenced so the NEXT entry starts
                -- clean (silencing on entry lets music126 sound briefly).
                moghouse_active = false;
                jukebox.mh_prime();
            end
            if (DEBUG_CITY or DEBUG_CUTSCENE) then
                zm_debug(string.format('ZONE IN %d moghouse_flag=%s transit=%s',
                    zid, tostring(moghouse_zone_flag), tostring(city_transit.group)));
            end
            if (city_transit.group ~= nil and get_city_group(zid) == city_transit.group) then
                city_transit.dest = zid;
            else
                city_transit.group = nil;
                city_transit.dest = nil;
            end
        end);

        is_zoning = false;
        zoning_from_city = nil;
        packet_event_pending_start = 0;
        eager_pause_start = 0;
        -- Zoning ends any handoff without a resume (zone logic restarts the
        -- WAV) and without touching the engine (0x00A zeroing just did it).
        handoff.active = false;
        handoff.saw_event = false;
        handoff.end_grace = 0;
        handoff.started = 0;
    handoff.pending034 = 0;
        was_in_cutscene = false;
        in_cutscene_from_packet = false;
        return;
    end
    if (e.id == 0x00B) then
        jukebox.shadow:reset();
        jukebox.shadow_reset_intro();
        jukebox.shadow_poll = nil;
        handoff.active = false;
        handoff.saw_event = false;
        handoff.end_grace = 0;
        handoff.started = 0;
    handoff.pending034 = 0;
        is_zoning = true;
        -- Record the city group of the zone we're leaving. previous_zone_id
        -- still holds the zone we're standing in at the moment of zone-out.
        zoning_from_city = get_city_group(previous_zone_id);
        -- Open the same-city transit window from the zone we are actually
        -- standing in (party data is still valid at zone-out; previous_zone_id
        -- only advances when a track starts).
        pcall(function()
            local here = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
            local g = get_city_group(here) or zoning_from_city;
            city_transit.group = g;
            city_transit.dest = nil;
            city_transit.started = os.clock();
        end);
        was_in_cutscene = false;
        in_cutscene_from_packet = false;
        packet_event_pending_start = 0;
        eager_pause_start = 0;
        return;
    end
end);

ashita.events.register('command', 'bard_cmd', function (e)
    local args = e.command:args();
    if (#args > 0 and (args[1] == '/zonemusic' or args[1] == '/zm')) then
        if (#args > 1 and args[2] == 'zone') then
            handle_zone_command(args);
            e.blocked = true;
            return;
        end
        if (#args > 1 and (args[2] == 'doctor' or args[2] == 'check')) then
            jukebox.print_doctor();
            e.blocked = true;
            return;
        end
        if (#args > 1 and args[2] == 'jukebox') then
            if (args[3] == 'rescan') then
                jukebox.build_catalog();
                print(chat.header('ZoneMusic'):append(chat.message('Jukebox catalog rebuilt.')));
            end
            gui_state.is_open[1] = true;
            gui_state.ui_tab = 0;
            e.blocked = true;
            return;
        end
        -- Debug command for ducking
        if (#args > 1 and args[2] == 'duck') then
            -- /zonemusic duck on/off - force enable/disable
            if (#args > 2 and args[3] == 'on') then
                music_config.enable_duck = true;
                print(chat.header('ZoneMusic'):append(chat.success('Ducking ENABLED')));
                e.blocked = true;
                return;
            end
            if (#args > 2 and args[3] == 'off') then
                music_config.enable_duck = false;
                duck_current_vol = 1.0;
                print(chat.header('ZoneMusic'):append(chat.error('Ducking DISABLED')));
                e.blocked = true;
                return;
            end
            
            -- Read current signal file
            local f = io.open(duck_signal_file, 'r');
            local content = "FILE NOT FOUND";
            if f then
                content = f:read('*a') or "EMPTY";
                f:close();
            end
            local now = os.clock();
            print(chat.header('ZoneMusic'):append(chat.message(string.format(
                'Duck: enabled=%s, vol=%.2f→%.2f, last=%.1fs ago, dur=%.1fs',
                tostring(music_config.enable_duck), duck_current_vol, duck_target_vol, 
                now - last_voice_time, current_duck_duration))));
            print(chat.header('ZoneMusic'):append(chat.message('Signal: ' .. content)));
            e.blocked = true;
            return;
        end
        -- Toggle the debounced pause for 0x034-opened events.
        if (#args > 1 and args[2] == 'eventpause') then
            music_config.pause_on_event = not (music_config.pause_on_event ~= false);
            local status = (music_config.pause_on_event ~= false) and 'ON' or 'OFF';
            print(chat.header('ZoneMusic'):append(chat.message('Event pause (0x034 cutscene openers): ' .. status)));
            pcall(settings.save);
            e.blocked = true;
            return;
        end
        -- Toggle the CURRENT zone in/out of the cinematic-zone list.
        -- Cinematic zones: any event pauses the WAV instantly (client-side
        -- script music can't be detected on the wire). Persisted in settings.
        if (#args > 1 and args[2] == 'cinema') then
            local zid = nil;
            pcall(function()
                zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
            end);
            if (zid == nil) then
                print(chat.header('ZoneMusic'):append(chat.error('Could not read current zone.')));
            elseif (cinematic_zone_seed[zid]) then
                print(chat.header('ZoneMusic'):append(chat.message(
                    string.format('Zone %d is a built-in cinematic zone (always on).', zid))));
            else
                if (music_config.cinematic_zones == nil) then music_config.cinematic_zones = {}; end
                local key = tostring(zid);
                if (music_config.cinematic_zones[key]) then
                    music_config.cinematic_zones[key] = nil;
                    print(chat.header('ZoneMusic'):append(chat.message(
                        string.format('Zone %d REMOVED from cinematic zones — events play through the WAV again.', zid))));
                else
                    music_config.cinematic_zones[key] = true;
                    print(chat.header('ZoneMusic'):append(chat.message(
                        string.format('Zone %d ADDED to cinematic zones — any event here now pauses the WAV instantly.', zid))));
                end
                pcall(settings.save);
            end
            e.blocked = true;
            return;
        end
        -- Debug command for cutscene detection
        if (#args > 1 and args[2] == 'cutscene') then
            DEBUG_CUTSCENE = not DEBUG_CUTSCENE;
            local status = DEBUG_CUTSCENE and 'ON' or 'OFF';
            print(chat.header('ZoneMusic'):append(chat.message('Cutscene debug mode: ' .. status)));
            e.blocked = true;
            return;
        end
        -- Debug command for fishing detection
        if (#args > 1 and args[2] == 'fishingdebug') then
            DEBUG_FISHING = not DEBUG_FISHING;
            local status = DEBUG_FISHING and 'ON' or 'OFF';
            print(chat.header('ZoneMusic'):append(chat.message('Fishing debug mode: ' .. status)));
            e.blocked = true;
            return;
        end
        -- Set/test the engine silence track id, and fire it immediately.
        -- Usage: /zm enginesilence [id]
        --   With an id: sets ENGINE_SILENCE_ID and injects it on day/night now,
        --   so you can hear whether that id mutes the engine. Iterate until the
        --   engine goes quiet, then that id is the silence value.
        --   Without an id: just fires the current ENGINE_SILENCE_ID.
        if (#args > 1 and args[2] == 'enginesilence') then
            if (#args > 2) then
                local id = tonumber(args[3]);
                if (id ~= nil) then
                    ENGINE_SILENCE_ID = id;
                end
            end
            print(chat.header('ZoneMusic'):append(chat.message(
                string.format('Engine silence id=%d - injecting on day/night now', ENGINE_SILENCE_ID))));
            -- Test command bypasses the covered-zone gate so you can probe the
            -- engine in any zone to find the silencing track id.
            inject_engine_music(0, ENGINE_SILENCE_ID);
            inject_engine_music(1, ENGINE_SILENCE_ID);
            e.blocked = true;
            return;
        end
        -- Manually inject a 0x05F music change: /zm enginemusic <slot> <track>
        if (#args > 3 and args[2] == 'enginemusic') then
            local slot = tonumber(args[3]);
            local track = tonumber(args[4]);
            if (slot ~= nil and track ~= nil) then
                inject_engine_music(slot, track);
                print(chat.header('ZoneMusic'):append(chat.message(
                    string.format('Injected 0x05F slot=%d track=%d', slot, track))));
            else
                print(chat.header('ZoneMusic'):append(chat.error('Usage: /zm enginemusic <slot> <track>')));
            end
            e.blocked = true;
            return;
        end
        -- Manual pause/resume commands for cutscenes/dialogue
        if (#args > 1 and args[2] == 'pause') then
            if (zone_is_playing and not zone_is_paused) then
                pause_zone_music();
                print(chat.header('ZoneMusic'):append(chat.message('Music paused manually')));
            elseif (battle_is_playing) then
                stop_battle_music();
                current_battle_track = "";
                print(chat.header('ZoneMusic'):append(chat.message('Battle music stopped')));
            else
                print(chat.header('ZoneMusic'):append(chat.message('No music playing')));
            end
            e.blocked = true;
            return;
        end
        if (#args > 1 and args[2] == 'resume') then
            if (zone_is_paused) then
                resume_zone_music();
                print(chat.header('ZoneMusic'):append(chat.success('Music resumed')));
            else
                update_music();
                print(chat.header('ZoneMusic'):append(chat.success('Music started')));
            end
            e.blocked = true;
            return;
        end
        if (#args > 1 and args[2] == 'toggle') then
            if (zone_is_paused) then
                resume_zone_music();
                print(chat.header('ZoneMusic'):append(chat.success('Music resumed')));
            elseif (zone_is_playing) then
                pause_zone_music();
                print(chat.header('ZoneMusic'):append(chat.message('Music paused')));
            else
                update_music();
                print(chat.header('ZoneMusic'):append(chat.success('Music started')));
            end
            e.blocked = true;
            return;
        end
        if (#args > 1 and (args[2] == 'stop' or args[2] == 'off')) then
            jukebox.set_addon_enabled(false);
            e.blocked = true;
            return;
        end
        if (#args > 1 and (args[2] == 'play' or args[2] == 'on')) then
            jukebox.set_addon_enabled(true);
            e.blocked = true;
            return;
        end
        if (#args > 1 and args[2] == 'debug') then
            local vana_hour = get_vana_hour();
            local party = AshitaCore:GetMemoryManager():GetParty();
            local hp_per = party:GetMemberHPPercent(0);
            local mode_names = { [0] = "Mixed", [1] = "Solo", [2] = "Party" };
            print(chat.header('ZoneMusic'):append(chat.message(string.format(
                'Vana Hour: %02d | HP: %d%% | Crisis: %s | Battle Mode: %s',
                vana_hour, hp_per, in_crisis_mode and "YES" or "no", mode_names[music_config.battle_mode] or "Mixed"
            ))));
            return;
        end
        -- Battle mode commands
        if (#args > 1 and args[2] == 'solo') then
            gui_state.battle_mode[1] = 1;
            music_config.battle_mode = 1;
            print(chat.header('ZoneMusic'):append(chat.success('Battle music: SOLO mode')));
            return;
        end
        if (#args > 1 and args[2] == 'party') then
            gui_state.battle_mode[1] = 2;
            music_config.battle_mode = 2;
            print(chat.header('ZoneMusic'):append(chat.success('Battle music: PARTY mode')));
            return;
        end
        if (#args > 1 and (args[2] == 'mix' or args[2] == 'auto')) then
            gui_state.battle_mode[1] = 0;
            music_config.battle_mode = 0;
            print(chat.header('ZoneMusic'):append(chat.success('Battle music: SOLO AND PARTY mode')));
            return;
        end
        if (#args > 1 and args[2] == 'random') then
            music_config.random_battle = not music_config.random_battle;
            gui_state.random_battle[1] = music_config.random_battle;
            if (music_config.random_battle) then
                scan_battle_tracks();
                current_random_track = "";
                print(chat.header('ZoneMusic'):append(chat.success(string.format(
                    'Random battle: ON (%d solo, %d party tracks)',
                    #random_battle_tracks_solo, #random_battle_tracks_party))));
            else
                print(chat.header('ZoneMusic'):append(chat.error('Random battle: OFF')));
            end
            return;
        end
        if (#args > 1 and args[2] == 'dynamic') then
            music_config.battle_dynamic = not music_config.battle_dynamic;
            gui_state.battle_dynamic[1] = music_config.battle_dynamic;
            if (music_config.battle_dynamic) then
                print(chat.header('ZoneMusic'):append(chat.success('Dynamic battle music: ON')));
            else
                -- Clean up if turning off while battle is sitting silent
                if (battle_is_silent) then
                    stop_battle_music_instant();
                    current_battle_track = "";
                    current_random_track = "";
                    zone_coinflip_active = false;
                    zone_coinflip_suffix = "";
                end
                print(chat.header('ZoneMusic'):append(chat.error('Dynamic battle music: OFF')));
            end
            e.blocked = true;
            return;
        end
        if (#args > 1 and args[2] == 'help') then
            print(chat.header('ZoneMusic'):append(chat.message('Commands:')));
            print(chat.message('  /zm or /zonemusic - Toggle GUI'));
            print(chat.message('  /zm play/stop - Start/stop music'));
            print(chat.message('  /zm pause/resume/toggle - Pause controls'));
            print(chat.message('  /zm solo/party/auto - Battle music mode'));
            print(chat.message('  /zm random - Toggle random battle music'));
            print(chat.message('  /zm dynamic - Toggle dynamic battle mode (FFXIV-style resume)'));
            print(chat.message('  /zm fade - Toggle fade in/out'));
            print(chat.message('  /zm zone on/off/toggle - Addon music in the current zone (whole city)'));
            print(chat.message('  /zm zone list - Zones where the addon is off'));
            print(chat.message('  /zm jukebox - Open the jukebox (rescan: re-read the sounds folder)'));
            print(chat.message('  /zm doctor - Check the install and explain anything that is wrong'));
            print(chat.message('  /zm duck on/off - Toggle voice ducking'));
            print(chat.message('  /zm cutscene - Toggle cutscene debug'));
            print(chat.message('  /zm debug - Show current state'));
            print(chat.message('  /zm help - This list'));
            return;
        end
        if (#args > 1 and args[2] == 'fade') then
            music_config.enable_fade = not music_config.enable_fade;
            gui_state.use_fade[1] = music_config.enable_fade;
            print(chat.header('ZoneMusic'):append(chat.success('Fade: ' .. (music_config.enable_fade and 'ON' or 'OFF'))));
            return;
        end
        gui_state.is_open[1] = not gui_state.is_open[1];
    end
end);

ashita.events.register('unload', 'bard_cleanup', function ()
    -- Save all settings using the proper function
    pcall(save_settings);
    
    -- Give the client its Mog House music slot back.
    pcall(jukebox.mh_release);

    -- Stop music instantly (no fade on unload)
    pcall(jukebox.stop, false);
    pcall(stop_all_music_instant);
end);
