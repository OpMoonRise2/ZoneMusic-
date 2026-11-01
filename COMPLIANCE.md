# Publication and verification state

Updated 2026-11-01. Maintainer: MoonRise (Eldorin).

GitHub hosts the addon source, author-supplied screenshots, and an installation ZIP. Optional recordings remain separate on Nexus Mods or may be supplied by each player. GitHub packages exclude audio, DAT overlays, personal configuration, runtime signals, recovery backups, and unrelated binaries. Existing attribution is preserved; no new license is granted for third-party material or project code.

Current verification: the Lua files pass loadfile syntax checks. This publication changes documentation, screenshots and packaging, not runtime logic. Earlier live-test reports in MAINTENANCE.md are historical evidence, not new tests. No new in-client playback, combat or cutscene test was performed for this publication.

The author-supplied screenshots show the author's installed UI. Their exact runtime revision has not been established; they are visual reference, not proof that the published source reproduces every shown control. Compare the published source before relying on a particular feature.

At release time (tag v2.0.2), Nexus descriptions and downloadable archives had not been changed. The dated sections below record the later Nexus changes. Nexus keeps downloads for optional audio assets only. Historical audio distribution is not evidence of redistribution rights. No audio or DAT asset is newly published here.

This publication does not assert reviewer approval. Final review remains pending.

## Binary transparency

The only bundled binary is plugins/ZMHelper.dll. Its SHA-256 is 50e4ac2669f3b75bd9ca9e9073dd10ed6e3ce442b087eb9a41fb0b5bfe38799b. The existing repository binary is retained unchanged. Source is in helper/src/ZMHelper.cpp and helper/src/exports.def, with CMake build configuration and vendored Microsoft Detours source and MIT license. The Ashita SDK is an external build dependency and is not republished. The helper uses Windows APIs; system DLLs are not bundled.

The public source builds successfully as Win32 Release using CMake and Visual Studio 2026, MSVC 19.51, with the external installed Ashita SDK. The SDK emitted one legacy-header warning (U+001A in dxfile.h). The existing DLL exports all three entry points listed in helper/src/exports.def. The rebuilt DLL has a different SHA-256, which is not evidence of equivalence or a source mismatch across toolchains. Exact correspondence of the existing DLL to this source remains unverified. The existing binary is retained to avoid introducing an untested replacement. No newly built binary is distributed in this release. The existing DLL imports Windows system/CRT components including VCRUNTIME140.dll; provide the Microsoft Visual C++ x86 runtime if missing, rather than downloading individual DLLs.

Provenance record: the retained DLL was committed in c6e5eb2 (2026-10-20 15:55:19 UTC) together with the helper source, with the message "rebuild DLL from it". The DLL's PE link timestamp is 2026-10-20 15:53:08 UTC, about two minutes before that commit. helper/src has not changed since. This supports, but does not prove byte for byte, that the retained DLL was built from the published source.

## Nexus follow-up completed (2026-11-01)

After the GitHub release publication, the signed-in Nexus short and full descriptions were updated and verified on the public pages. They direct addon/helper downloads to GitHub only and explain optional audio installation. Current mixed-archive file descriptions also direct users to copy only audio/optional sound overlays and ignore bundled legacy code. The ZoneMusic legacy helper file explicitly directs users to GitHub instead of installing it from Nexus.

The release-tag snapshot above predates these external-page edits. The existing Nexus archives themselves remain unchanged, including legacy bundled code and older documentation. Audio-only replacement archives are still pending; no audio, DAT files or newly compiled binaries were uploaded during this follow-up. Historical files and internal archive documentation were not rewritten. Final reviewer approval remains pending.

## Nexus file cleanup (2026-11-01)

All superseded Nexus files were moved to Nexus's archived category. This includes the old Lua-only downloads, the standalone ZMHelper download and older full packages. Nothing was deleted. The current 2.0.2 full package stays listed for its optional audio until an audio-only replacement is uploaded. Its file description tells users to copy only the audio and ignore the bundled Lua and DLL.
