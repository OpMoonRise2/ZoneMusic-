# ZoneMusic

Dynamic zone and battle music for Ashita v4. Runtime version: 1.3.0.

## Install

Copy `zonemusic.lua`, `zm_ui.lua` and `zm_doctor.lua` to `Ashita/addons/zonemusic/`. Copy `ZMHelper.dll` to `Ashita/plugins/`. Put the separately supplied `sounds/` folder beside the Lua files, and the `zonemusicDATS` overlay under `Ashita/polplugins/DATs/`.

Add `zonemusicDATS` to your Pivot overlay list while preserving other entries. Load `/load ZMHelper` and `/addon load zonemusic`. Open the menu with `/zm`; run `/zm doctor` to inspect installation health.

This prepared asset snapshot contains 427 MP3 recordings. The music library and DAT replacements are separate from the Git source bundle. The helper creates `engine_music.signal` at runtime; do not ship or track a signal captured from another session. Character settings, live configuration files, logs and backups are excluded.

The deployed helper DLL is byte-identical to the current upstream binary. Its build source is not included in this repository snapshot.

For the complete published installation package, use the [Nexus Mods release](https://www.nexusmods.com/finalfantasy11/mods/34).
