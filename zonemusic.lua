addon.name      = 'ZoneMusic';
addon.author    = 'MoonRise (Eldorin)';
addon.version   = '1.2.1';
addon.desc      = 'Dynamic Zone Themes and Battle Themes /zm for gui';
addon.link      = '';

require('common');
local chat = require('chat');
local ffi = require('ffi');
local imgui = require('imgui');
local settings = require('settings');

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
    enable_moghouse = true, -- Play Mog House music when a Moogle NPC is detected nearby
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
    -- Pause WAV for 0x034-opened events (cutscene openers) after a short
    -- debounce, everywhere. NPC talks (0x032) never trigger this.
    -- Toggle in-game with /zm eventpause.
    pause_on_event = true,
};

-- Load settings (returns live settings object)
local music_config = settings.load(default_settings);

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

-- Mog House state — detected by scanning nearby entities for an NPC named
-- "Moogle" within MOGHOUSE_DISTANCE yalms. Inside a Mog House, your housekeeper
-- Moogle is always in the same room (5-10 yalms typical). Outside, you
-- aren't physically standing next to anything called "Moogle" — the
-- residential-area Moogle stops being a nearby entity once you exit the
-- Mog House interior because the engine unloads the interior model.
--
-- Rate-limited scan (MOGHOUSE_SCAN_INTERVAL) keeps the per-frame cost low.
-- Persistence flag with EXIT_GRACE prevents flicker if the Moogle entity
-- briefly de-syncs (e.g., during animation transitions).
local moghouse_active = false;
local moghouse_last_seen = 0;        -- os.clock() of last successful Moogle detection
local moghouse_scan_timer = 0;       -- os.clock() of last scan
local MOGHOUSE_SCAN_INTERVAL = 1.0;  -- scan every 1 second
local MOGHOUSE_DISTANCE = 12.0;      -- yalms — comfortably covers small Mog House interior
local MOGHOUSE_EXIT_GRACE = 4.0;     -- seconds of no detection before clearing flag
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
    
    local sounds_path = string.format('%saddons\\ZoneMusic\\sounds\\', AshitaCore:GetInstallPath());
    
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

    -- === HORIZON-SPECIFIC ===
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
        local path = string.format('%saddons\\ZoneMusic\\sounds\\%s', AshitaCore:GetInstallPath(), candidate);
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

-- Master coverage gate. Returns true if the addon should control
-- audio in this zone; false = stay hands-off, engine plays.
local function zone_is_covered_expansion(zone_id)
    local tag = zone_expansion[zone_id] or "base";
    return expansion_enabled[tag] == true;
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

    -- EXPANSION GATE: if this zone's expansion is not enabled (e.g. ToAU /
    -- WotG [S] / SoA / Abyssea before their covers ship), the addon stays
    -- fully hands-off — never suppress the engine, so native BGM plays.
    if (not zone_is_covered_expansion(incoming_zone_id)) then
        return;
    end

    local should_suppress = has_zonemusic_assets(incoming_zone_id)
                         or (entering_moghouse and file_exists("moghouse.wav"));

    if (not should_suppress) then
        return;
    end

    -- Preserve the engine's original resident music IDs before zeroing.
    pcall(function()
        saved_bgm_ids.day   = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.day   + 1);
        saved_bgm_ids.night = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.night + 1);
        saved_bgm_ids.solo  = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.solo  + 1);
        saved_bgm_ids.party = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.party + 1);
        saved_bgm_ids.mount = struct.unpack('H', e.data, ENGINE_BGM_OFFSETS.mount + 1);
    end);

    -- Persist the fresh capture (see store_zone_bgm comment).
    pcall(store_zone_bgm, incoming_zone_id);

    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.day,   0, 16);
    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.night, 0, 16);
    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.solo,  0, 16);
    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.party, 0, 16);
    ashita.bits.pack_be(e.data_modified_raw, 0, ENGINE_BGM_OFFSETS.mount, 0, 16);
end

-- 5. The DJ Logic
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
        current_state = "Idle (Game Music)";
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
    -- Detected by scanning nearby entities for an NPC named exactly "Moogle"
    -- within MOGHOUSE_DISTANCE yalms. Every Mog House and Rent-a-Room has
    -- a housekeeper Moogle (verified across all four nation cities per
    -- BG Wiki / FFXIclopedia NPC naming).
    --
    -- WHY THIS WORKS:
    --   - Inside any Mog House, the Moogle is in the room with you (5-10y).
    --   - Outside Mog Houses, the Mog House interior is unloaded — the
    --     Moogle is not in your entity scan range, even when you're standing
    --     just outside the residential area door.
    --   - Nomad Moogles (Selbina, Mhaura, Norg, Rabao, Kazham, etc.) are in
    --     different zones and named differently from a strict-equality
    --     standpoint? Actually no, they are also named "Moogle". This is a
    --     known concern: standing next to a Nomad Moogle for >1 second would
    --     trigger Mog House music. Mitigations:
    --     (a) Outdoor Nomad Moogle zones (Selbina, Mhaura, etc.) don't
    --         typically share city-music architecture with Mog House music,
    --         and the user-controlled enable_moghouse toggle lets the user
    --         disable it when traveling.
    --     (b) MOGHOUSE_SCAN_INTERVAL=1.0 + EXIT_GRACE=4.0 means you have to
    --         dwell next to a Nomad Moogle for ~5 sec before music kicks in,
    --         and music ends within ~5 sec of walking away.
    --
    -- Rate-limited via moghouse_scan_timer to avoid scanning every frame.
    if (music_config.enable_moghouse) then
        local now = os.clock();
        if (now - moghouse_scan_timer >= MOGHOUSE_SCAN_INTERVAL) then
            moghouse_scan_timer = now;
            local moogle_found = false;
            local success, _ = pcall(function()
                for j = 0, 2303 do
                    local ent = GetEntity(j);
                    if (ent ~= nil and ent.Name == "Moogle") then
                        -- Distance is squared yalms; threshold compares squared
                        -- to avoid the sqrt cost on every entity.
                        if (ent.Distance ~= nil and ent.Distance > 0 and
                            ent.Distance <= (MOGHOUSE_DISTANCE * MOGHOUSE_DISTANCE)) then
                            moogle_found = true;
                            return;
                        end
                    end
                end
            end);
            if (success and moogle_found) then
                moghouse_last_seen = now;
                if (not moghouse_active) then
                    moghouse_active = true;
                end
            elseif (moghouse_active) then
                -- No Moogle in range this scan; check exit grace
                if ((now - moghouse_last_seen) > MOGHOUSE_EXIT_GRACE) then
                    moghouse_active = false;
                end
            end
        end

        if (moghouse_active and file_exists("moghouse.wav")) then
            current_state = "Mog House";
            return "moghouse.wav";
        end
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

-- End of an engine handoff: resume the WAV first (instant, full volume),
-- then re-silence the engine's slots so its lingering event track does not
-- ride under the WAV. Resume-before-silence closes the dead-air gap that the
-- old order (silence, then 1.5s fade-in from zero) produced at cutscene end.
-- engine_silence() is still gated on mci_owned_before_event, so engine-only
-- zones (no WAV cover) are left untouched.
local function end_handoff(resume_wav)
    if (resume_wav and zone_is_paused) then
        resume_zone_music_fast();
    end
    engine_silence();
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
        -- Track 0 is the engine's silence slot; ignore.
        if (music_id == 0) then return; end
        -- Only react when the WAV actually owns audio here; engine-native
        -- zones (no cover / DAT-swapped boss fights) are the engine's turf.
        if (handoff.active) then return; end
        if (zone_is_playing or zone_is_paused or battle_is_playing) then
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
    local path = string.format('%saddons\\ZoneMusic\\sounds\\%s', AshitaCore:GetInstallPath(), resolved_track);
    local mci_type = get_mci_type(resolved_track);
    
    local open_cmd = string.format('open "%s" type %s alias %s', path, mci_type, zone_alias);
    local result = winmm.mciSendStringA(open_cmd, nil, 0, nil);
    
    if (result ~= 0) then
        print(chat.header('ZoneMusic'):append(chat.error('Zone music open failed! Error: ' .. result)));
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
        print(chat.header('ZoneMusic'):append(chat.error('Zone music play failed! Error: ' .. result)));
        winmm.mciSendStringA("close " .. zone_alias, nil, 0, nil);
        return;
    end
    
    zone_is_playing = true;
    zone_is_paused = false;
    current_zone_track = track;
    current_zone_track_display = resolved_track;
    
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
    local path = string.format('%saddons\\ZoneMusic\\sounds\\%s', AshitaCore:GetInstallPath(), resolved_track);
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

local function update_music()
    if (not music_config.enabled) then
        stop_all_music();
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
            status4_start_time = 0;
            in_cutscene_from_packet = false;
            packet_event_pending_start = 0;
            was_in_cutscene = false;
            handoff.active = false;
            handoff.saw_event = false;
            handoff.end_grace = 0;
            handoff.started = 0;
    handoff.pending034 = 0;
            previous_status = 0;
            previous_is_night = nil;
            is_zoning = false;
            zoning_from_city = nil;
            current_state = "Logged Out";
            return;
        end
    end

    -- Empty desired_track = addon explicitly yielded (e.g., death state
    -- where FFXI's native death.bgw should play uninterrupted). Stop any
    -- addon music here and skip the rest of the track-selection branches,
    -- which expect a non-empty filename.
    if (desired_track == nil or desired_track == "") then
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
            status4_start_time = 0;
            in_cutscene_from_packet = false;
            packet_event_pending_start = 0;
            was_in_cutscene = false;
            handoff.active = false;
            handoff.saw_event = false;
            handoff.end_grace = 0;
            handoff.started = 0;
    handoff.pending034 = 0;
            previous_status = 0;
            previous_is_night = nil;
            -- Zoning flag clears on confirmed logout. If a real zone-in
            -- (0x00A) ever arrives later it'll just be a no-op set to false.
            is_zoning = false;
        end
        if (zone_is_playing or zone_is_paused or battle_is_playing) then
            stop_all_music_instant();
        end
        return;
    end

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

-- 7. Loops
local timer = 0;
ashita.events.register('d3d_present', 'bard_music_tick', function ()
    poll_engine_signal();
    pcall(update_idle_replay);
    -- Update fades every frame (state-only, no MCI calls)
    pcall(update_fades);
    
    -- Update ducking every frame (state-only, no MCI calls)
    pcall(update_ducking);
    
    -- Single source of truth for MCI volume commands. Applies
    -- final = base_volume * duck_multiplier per alias, with dedupe in
    -- set_volume to skip MCI when the integer value hasn't changed.
    -- This eliminates the per-frame double-set that was causing audible
    -- stutter during fade+duck overlap.
    pcall(apply_volumes);
    
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
        pcall(update_music);

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

    if (not gui_state.is_open[1]) then return; end

    local nav_labels = { 'Status', 'Battle', 'Playback', 'Fade & Duck', 'Events' };
    local zm_page = gui_state.zm_page or { 0 };
    gui_state.zm_page = zm_page;

    local NAV_W = 112;

    -- Default size; the window is user-resizable so the long descriptive
    -- lines can be revealed by dragging the window edge wider.
    imgui.SetNextWindowSize({ 600, 0 }, ImGuiCond_Once);
    if (imgui.Begin('ZoneMusic', gui_state.is_open)) then

        -- LEFT NAV
        imgui.BeginGroup();
        imgui.PushItemWidth(NAV_W);

        local status_col = music_config.enabled and {0.2,0.8,0.3,1.0} or {0.8,0.2,0.2,1.0};
        imgui.TextColored(status_col, music_config.enabled and 'PLAYING' or 'STOPPED');

        -- Zone status short
        local zs = zone_is_playing and 'Zone ♪' or (zone_is_paused and 'Zone ‖' or 'Zone —');
        local bs = battle_is_playing and (battle_is_silent and 'Battle ‖' or 'Battle ♪') or '';
        imgui.TextColored({0.5,0.7,1.0,1.0}, zs);
        if bs ~= '' then imgui.TextColored({1.0,0.6,0.3,1.0}, bs); end

        imgui.Spacing(); imgui.Separator(); imgui.Spacing();

        for i, lbl in ipairs(nav_labels) do
            local active = (zm_page[1] == i - 1);
            imgui.PushStyleColor(ImGuiCol_Button,        active and {0.25,0.45,0.75,1.0} or {0.15,0.15,0.20,1.0});
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, active and {0.30,0.52,0.85,1.0} or {0.20,0.30,0.45,1.0});
            if imgui.Button(lbl, {NAV_W, 22}) then zm_page[1] = i - 1; end
            imgui.PopStyleColor(2);
        end

        imgui.Spacing(); imgui.Separator(); imgui.Spacing();

        -- Play / Stop in nav
        imgui.PushStyleColor(ImGuiCol_Button,        {0.15,0.45,0.15,1.0});
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.20,0.60,0.20,1.0});
        if imgui.Button('Play', {NAV_W, 22}) then
            music_config.enabled = true;
            gui_state.enabled[1] = true;
            clear_idle_replay();
            update_music();
        end
        imgui.PopStyleColor(2);

        imgui.PushStyleColor(ImGuiCol_Button,        {0.45,0.15,0.15,1.0});
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.60,0.20,0.20,1.0});
        if imgui.Button('Stop', {NAV_W, 22}) then
            stop_all_music();
            music_config.enabled = false;
            gui_state.enabled[1] = false;
        end
        imgui.PopStyleColor(2);

        imgui.PopItemWidth();
        imgui.EndGroup();
        imgui.SameLine();

        -- CONTENT (width tracks the window so it can be expanded by dragging)
        local CONTENT_W = 440;
        local win_w = imgui.GetWindowWidth and imgui.GetWindowWidth();
        if (win_w and win_w > 0) then
            CONTENT_W = win_w - NAV_W - 40;
        end
        if (CONTENT_W < 240) then CONTENT_W = 240; end
        imgui.BeginGroup();
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
            end
            if gui_state.use_moghouse[1] then
                imgui.TextColored({0.5,0.5,0.5,1.0}, 'moghouse.wav');
                imgui.TextColored({0.5,0.5,0.5,1.0}, 'Detects nearby Moogle NPC (~12 yalms)');
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

        imgui.Spacing(); imgui.Separator();
        if imgui.Button('Save Settings', {CONTENT_W - 10, 24}) then save_settings(); end

        imgui.PopItemWidth();
        imgui.EndGroup();
    end
    imgui.End();
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
            local rd, rn = saved_bgm_ids.day, saved_bgm_ids.night;
            local is_resident_resend =
                (song >= 0)
                and (((rd ~= nil) and (song == rd)) or ((rn ~= nil) and (song == rn)));
            local is_covered_moghouse =
                (song == 126)
                and (music_config.enable_moghouse ~= false)
                and file_exists("moghouse.wav");

            if (is_resident_resend or is_covered_moghouse) then
                e.blocked = true;
                if (DEBUG_CUTSCENE) then
                    zm_debug(string.format(
                        'Resident/covered 0x05F blocked (type=%d song=%d) — WAV keeps playing',
                        mtype, song));
                end
            else
                begin_handoff(string.format(
                    'genuine 0x05F event music (type=%d song=%d)', mtype, song));
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
        handoff.active = false;
        handoff.saw_event = false;
        handoff.end_grace = 0;
        handoff.started = 0;
    handoff.pending034 = 0;
        is_zoning = true;
        -- Record the city group of the zone we're leaving. previous_zone_id
        -- still holds the zone we're standing in at the moment of zone-out.
        zoning_from_city = get_city_group(previous_zone_id);
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
            stop_all_music();
            music_config.enabled = false;
            gui_state.enabled[1] = false;
            print(chat.header('ZoneMusic'):append(chat.message('Music stopped!')));
            e.blocked = true;
            return;
        end
        if (#args > 1 and (args[2] == 'play' or args[2] == 'on')) then
            music_config.enabled = true;
            gui_state.enabled[1] = true;
            clear_idle_replay();
            update_music();
            print(chat.header('ZoneMusic'):append(chat.success('Music playing!')));
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
    
    -- Stop music instantly (no fade on unload)
    pcall(stop_all_music_instant);
end);
