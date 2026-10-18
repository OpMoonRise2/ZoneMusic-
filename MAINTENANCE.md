# Maintenance state

`zonemusic.lua` owns music selection and playback state; `zm_ui.lua` owns the GUI; `zm_doctor.lua` provides read-only installation checks. The helper plugin writes the runtime music signal. Audio and DAT replacements are maintained as separate release assets.

This snapshot was copied from the installed 1.3.0 runtime on 2026-10-18. It adds the UI and doctor modules to the source repository, refreshes the runtime and documentation, and removes the tracked generated signal. The helper DLL is unchanged from upstream. No runtime behavior was edited during cleanup.

Before release, exercise district continuity, day/night changes, Mog House entry/exit, event handoff, battle transitions, zone loading, and interaction with voice ducking. These require live checks; this cleanup verifies source syntax, payload hashes and package layout only.

Do not copy character configuration, runtime signals or old diagnostic reports into the source repository. Preserve the original author and existing license terms; this preparation does not grant a new license.
