# Changelog

## 1.3.1 — 2026-10-18

- Added separate Shadow Lord phase-one and phase-two battle themes: shadow_battle.mp3 and shadow_battle_2.mp3.
- Kept the Throne Room day theme unchanged; solo and party engagement select the same boss theme.
- Added encounter-aware phase switching using phase-one defeat and boss re-engagement, with Implosion as a phase-two fallback.
- Prevented ordinary disengage/re-engage from advancing the phase or restarting the intro.
- Smoothed native music handover on teleport/menu exit and battle engagement by clearing all covered music slots and handling event exit before the normal music-update delay.
- Recovered missing native music IDs after reloading inside the battlefield without overwriting fresh packet values.
- Locked repeated intro music outside genuine event windows until the next visit/logout; later real cutscenes retain native music ownership.
- Routed named boss battle tracks through the battle playback channel.
- Added resolved track-start and intro-lock messages to cutscene debug logging.
- Added automated encounter and handover regression coverage. Final behavior was confirmed by the author in live testing.
