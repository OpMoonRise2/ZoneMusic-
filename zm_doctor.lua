--[[
    ZoneMusic - health check (/zm doctor).

    Looks for the things that break an install and says, in plain words,
    what is wrong and how to fix it. Everything it needs comes through the
    env table built in zonemusic.lua (jukebox.run_doctor); it never touches
    addon state directly and never changes anything on disk.

    Levels: ok (working), info (worth knowing), warn (something will sound
    wrong), fail (something is broken).
--]]

local doctor = {};

local SILENCE_STUB_SIZE = 176478;  -- the old 1-second silence BGWs

local ROM_FOLDERS = { 'sound', 'sound2', 'sound3', 'sound4', 'sound5', 'sound6', 'sound7', 'sound8', 'sound9' };

local function new_report(env)
    return { items = {}, warnings = 0, failures = 0, when = os.date('%Y-%m-%d %H:%M:%S'), version = env.version };
end

local function add(report, level, title, detail, fix)
    table.insert(report.items, { level = level, title = title, detail = detail, fix = fix });
    if (level == 'warn') then report.warnings = report.warnings + 1; end
    if (level == 'fail') then report.failures = report.failures + 1; end
end

local function short_list(names, limit)
    limit = limit or 6;
    local shown = {};
    for i = 1, math.min(#names, limit) do shown[i] = names[i]; end
    local text = table.concat(shown, ', ');
    if (#names > limit) then text = text .. string.format(' and %d more', #names - limit); end
    return text;
end

-- XIPivot's config: root folder plus overlays in load order.
local function read_pivot(install_path)
    local f = io.open(install_path .. 'config\\pivot\\pivot.ini', 'r');
    if (f == nil) then return nil; end
    local cfg = { root = nil, overlays = {} };
    local section = nil;
    for line in f:lines() do
        local sec = line:match('^%s*%[([^%]]+)%]');
        if (sec ~= nil) then
            section = string.lower(sec);
        elseif (not line:match('^%s*;')) then
            local key, value = line:match('^%s*([^=]-)%s*=%s*(.-)%s*$');
            if (key ~= nil and section == 'settings' and string.lower(key) == 'root_path' and value ~= '') then
                cfg.root = value;
            elseif (key ~= nil and section == 'overlays' and tonumber(key) ~= nil and value ~= '') then
                table.insert(cfg.overlays, { order = tonumber(key), name = value });
            end
        end
    end
    f:close();
    table.sort(cfg.overlays, function(a, b) return a.order < b.order; end);
    cfg.root = (cfg.root or (install_path .. 'polplugins\\DATs')):gsub('/', '\\'):gsub('\\+$', '');
    return cfg;
end

-- Music BGWs inside one overlay, keyed 'rom/musicNNN.bgw' because the same
-- file name under sound\ and sound2\ are two different game files.
local function overlay_music(env, folder)
    local files, count = {}, 0;
    for _, rom in ipairs(ROM_FOLDERS) do
        local dir = folder .. '\\' .. rom .. '\\win\\music\\data\\';
        for _, entry in ipairs(env.list_dir(dir, '*.bgw')) do
            files[rom .. '/' .. string.lower(entry.name)] = {
                rom = rom, name = string.lower(entry.name), size = entry.size, mtime = entry.mtime, path = dir .. entry.name,
            };
            count = count + 1;
        end
    end
    return files, count;
end

local function check_install(env, report)
    -- Sounds folder.
    local mp3 = env.list_dir(env.sounds_path, '*.mp3');
    local wav = env.list_dir(env.sounds_path, '*.wav');
    local total = #mp3 + #wav;
    if (total == 0) then
        add(report, 'fail', 'No music files found',
            'Looked in ' .. env.sounds_path .. ' and found nothing to play.',
            'The sounds folder must sit next to zonemusic.lua (addons\\zonemusic\\sounds). Reinstall the addon if it is missing.');
    else
        add(report, 'ok', string.format('%d music files found', total), env.sounds_path, nil);
    end

    -- Window module.
    if (env.ui_error ~= nil) then
        add(report, 'fail', 'The ZoneMusic window could not load',
            'zm_ui.lua is missing or damaged: ' .. env.ui_error,
            'Reinstall the addon so zm_ui.lua sits next to zonemusic.lua, then /addon reload zonemusic. Music keeps working meanwhile.');
    end

    -- Helper plugin.
    if (env.helper_loaded == false) then
        add(report, 'warn', 'ZMHelper plugin is not running',
            'Without it, cutscene music is detected by a slower fallback, so some cutscenes can briefly play on top of ZoneMusic.',
            'Type /load ZMHelper, and add that line to your Ashita boot script so it loads every time.');
    elseif (env.helper_loaded == true) then
        add(report, 'ok', 'ZMHelper plugin is running', nil, nil);
    end

    -- Audio device: open (never play) one real file.
    local probe = mp3[1] or wav[1];
    if (probe ~= nil) then
        local kind = probe.name:lower():match('%.wav$') and 'waveaudio' or 'mpegvideo';
        local result = env.mci(string.format('open "%s%s" type %s alias zm_probe', env.sounds_path, probe.name, kind));
        env.mci('close zm_probe');
        if (result ~= 0) then
            add(report, 'fail', 'Windows could not open a music file',
                string.format('%s: %s', probe.name, env.mci_error(result)),
                'Check that Windows has a working sound output device and that MP3 playback works on this PC (Windows Media Player can test it).');
        else
            add(report, 'ok', 'Windows audio playback works', nil, nil);
        end
    end
end

local function check_settings(env, report)
    if (#env.settings_repairs > 0) then
        add(report, 'warn', 'Damaged settings were repaired',
            table.concat(env.settings_repairs, '; ') .. '.',
            'Nothing to do; the fixed values are saved the next time settings are saved. If this keeps coming back, delete the ZoneMusic settings file for this character.');
    end
    if (env.enabled == false) then
        add(report, 'info', 'ZoneMusic is switched off',
            'The game plays its own music everywhere.',
            'Use the switch at the top of the ZoneMusic window, or type /zm on.');
    end
    local off = {};
    for key, flag in pairs(env.disabled_zones or {}) do
        if (flag == true) then table.insert(off, env.zone_name(tonumber(key) or 0)); end
    end
    table.sort(off);
    if (#off > 0) then
        add(report, 'info', string.format('ZoneMusic is off in %d zone(s)', #off), short_list(off),
            'Turn them back on from the Zones tab or with /zm zone on while standing there.');
    end
end

local function check_dats(env, report)
    local pivot = read_pivot(env.install_path);
    if (pivot == nil) then return; end
    local ours = nil;
    for _, overlay in ipairs(pivot.overlays) do
        if (string.lower(overlay.name):find('zonemusic', 1, true)) then ours = overlay; break; end
    end
    if (ours == nil) then return; end

    if (env.pivot_loaded == false) then
        add(report, 'warn', 'XIPivot is not loaded',
            'pivot.ini lists ' .. ours.name .. ', but the pivot plugin is not running, so no cover DATs play (cutscenes, menus, death, chocobo use the original music).',
            'Make sure pivot is in your POL plugin list (polplugins\\pivot.dll) and restart the game.');
    end

    local folder = pivot.root .. '\\' .. ours.name;
    local files, count = overlay_music(env, folder);
    if (count == 0) then
        add(report, 'fail', 'Cover DAT folder is missing or empty',
            'pivot.ini lists ' .. ours.name .. ' but ' .. folder .. ' has no music files.',
            'Reinstall the zonemusicDATS folder into ' .. pivot.root .. ', or remove the ' .. ours.name .. ' line from config\\pivot\\pivot.ini.');
        return;
    end
    add(report, 'ok', string.format('Cover DATs found (%d music files)', count), folder, nil);

    -- Overlays loaded earlier win for the same file name.
    for _, overlay in ipairs(pivot.overlays) do
        if (overlay.order < ours.order) then
            local theirs = overlay_music(env, pivot.root .. '\\' .. overlay.name);
            local clash = {};
            for name, info in pairs(theirs) do
                if (files[name] ~= nil and info.size ~= SILENCE_STUB_SIZE) then table.insert(clash, name); end
            end
            table.sort(clash);
            if (#clash > 0) then
                add(report, 'warn', string.format('Overlay "%s" overrides %d cover(s)', overlay.name, #clash),
                    short_list(clash) .. '. It loads before ' .. ours.name .. ' in pivot.ini, so its versions play instead.',
                    'In /pivot, move ' .. ours.name .. ' above "' .. overlay.name .. '", or remove those music files from "' .. overlay.name .. '". Restart the game after.');
            end
        end
    end
end

local function check_errors(env, report)
    local sources = {};
    for source, entry in pairs(env.errors or {}) do table.insert(sources, source); end
    table.sort(sources);
    for _, source in ipairs(sources) do
        local entry = env.errors[source];
        add(report, 'fail', string.format('Error in "%s" (%d time%s this session)', source, entry.count, entry.count == 1 and '' or 's'),
            entry.first, 'Send logs\\zonemusic_errors.log and logs\\zonemusic_report.txt to the ZoneMusic author.');
    end
end

-- Run every check. Each group is protected so one failing check can never
-- stop the others (or the addon).
function doctor.run(env)
    local report = new_report(env);
    for _, check in ipairs({
        { 'install', check_install }, { 'settings', check_settings },
        { 'cover DATs', check_dats }, { 'errors', check_errors },
    }) do
        local ok, err = pcall(check[2], env, report);
        if (not ok) then
            add(report, 'warn', 'Could not finish the ' .. check[1] .. ' check', tostring(err), nil);
        end
    end
    return report;
end

-- Plain-text report for logs\zonemusic_report.txt.
function doctor.format(report, env)
    local lines = {
        'ZoneMusic health check',
        string.format('Version %s  |  %s', tostring(report.version), report.when),
        'Ashita: ' .. tostring(env.install_path),
        'Sounds: ' .. tostring(env.sounds_path),
        string.format('Result: %d problem(s), %d warning(s)', report.failures, report.warnings),
        '',
    };
    local marks = { ok = '[ OK ]', info = '[INFO]', warn = '[ !! ]', fail = '[FAIL]' };
    for _, item in ipairs(report.items) do
        table.insert(lines, string.format('%s %s', marks[item.level] or '[    ]', item.title));
        if (item.detail ~= nil) then table.insert(lines, '       ' .. item.detail); end
        if (item.fix ~= nil) then table.insert(lines, '       Fix: ' .. item.fix); end
    end
    return table.concat(lines, '\n') .. '\n';
end

return doctor;
