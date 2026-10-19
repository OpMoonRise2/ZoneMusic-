# Maintenance state

## Release 1.3.1

`zonemusic.lua` owns track selection, playback and native-music handover; `zm_shadow.lua` owns Shadow Lord phase state; `zm_ui.lua` owns the GUI; `zm_doctor.lua` provides installation checks. Keep all four Lua files together. Audio and DAT overlays are separate Nexus assets; keep the Nexus download link in README.

The 2026-10-18 handover investigation identified missing resident/battle IDs after an in-zone reload. The trace showed native music reopening handover 0.13 seconds after event completion and battle-track start. Missing fields now recover from persisted zone settings; fresh packet values take precedence. An intro score observed during the event is locked outside subsequent event windows for that visit. Zone/logout lifecycle resets the lock. Do not replace this with a global cutscene mute or a re-engagement counter.

The author confirmed final live behavior after testing teleport exit, encounter handover and the phase transitions. Automated actual-function regressions cover both phases, entity gaps, re-engagement, missing assets, settings gates, death, other zones, native packets/helper signals, genuine events, nil-ID reload recovery, intro replay and reset. Available compiler checks keep the maximum per-function upvalue count at 59. Any further playback/handover edit needs focused live regression, including fades and interaction with voice ducking; the existing encounter confirmation is not a test of every zone/cutscene.

Preserve character settings. Never ship captured runtime signals, personal logs/configuration, recovery backups or Git internals. Debug captures and rollback source from this work are stored outside the repository. The helper DLL is unchanged from upstream; its build source is not available in this repository. Preserve original attribution and existing license terms.
