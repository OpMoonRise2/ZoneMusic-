# Publication and verification state

Updated 2026-11-01. Maintainer: MoonRise (Eldorin).

GitHub hosts the addon source, author-supplied screenshots, and an installation ZIP. Optional recordings remain separate on Nexus Mods or may be supplied by each player. GitHub packages exclude audio, DAT overlays, personal configuration, runtime signals, recovery backups, and unrelated binaries. Existing attribution is preserved; no new license is granted for third-party material or project code.

Current verification: the Lua files pass loadfile syntax checks. This publication changes documentation, screenshots and packaging, not runtime logic. Earlier live-test reports in MAINTENANCE.md are historical evidence, not new tests. No new in-client playback, combat or cutscene test was performed for this publication.

The author-supplied screenshots show the author's installed UI. Their exact runtime revision has not been established; they are visual reference, not proof that the published source reproduces every shown control. Compare the published source before relying on a particular feature.

External Nexus descriptions and downloadable archives have not been changed by this publication. Any old wording directing users to download the addon there still needs removal by the maintainer; retain Nexus downloads for optional audio assets only. Historical audio distribution is not evidence of redistribution rights. No audio or DAT asset is newly published here.

This publication does not assert reviewer approval. Final review remains pending.

## Binary transparency

The only bundled binary is plugins/ZMHelper.dll. Its SHA-256 is 50e4ac2669f3b75bd9ca9e9073dd10ed6e3ce442b087eb9a41fb0b5bfe38799b. The existing repository binary is retained unchanged. Source is in helper/src/ZMHelper.cpp and helper/src/exports.def, with CMake build configuration and vendored Microsoft Detours source and MIT license. The Ashita SDK is an external build dependency and is not republished. The helper uses Windows APIs; system DLLs are not bundled.

The public source builds successfully as Win32 Release using CMake and Visual Studio 2026, MSVC 19.51, with the external installed Ashita SDK. The SDK emitted one legacy-header warning (U+001A in dxfile.h). The existing DLL exports all three entry points listed in helper/src/exports.def. The rebuilt DLL has a different SHA-256, which is not evidence of equivalence or a source mismatch across toolchains. Exact correspondence of the existing DLL to this source remains unverified. The existing binary is retained to avoid introducing an untested replacement. No newly built binary is distributed in this release. The existing DLL imports Windows system/CRT components including VCRUNTIME140.dll; provide the Microsoft Visual C++ x86 runtime if missing, rather than downloading individual DLLs.
