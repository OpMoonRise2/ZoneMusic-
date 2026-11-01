# ZMHelper — ZoneMusic engine-music sentinel

Ashita v4 plugin, version 1.1. This folder contains the published source accompanying the existing `ZMHelper.dll` in the repository root. A Win32 Release build succeeds; exact correspondence to the existing binary is not independently established. See [verification state](../COMPLIANCE.md).

## What it does

FFXI cutscene scores can be started by client-side event scripts with no network traffic, so no packet-based addon can see them. The client streams every music track from a `.bgw` file under `...\win\music\...`. ZMHelper watches those file opens and reports each music track to ZoneMusic through a one-line signal file:

```
<Ashita>\addons\zonemusic\engine_music.signal
format: "<counter> <music_id> <tickcount>"
```

ZoneMusic polls that file; a counter change means "the client just started track X", and ZoneMusic hands audio back to the game.

## What it hooks

On load it uses Microsoft Detours to attach observers to `fopen_s`, `_fsopen` and `fopen` in each loaded C runtime, and to kernel32 `CreateFileA`. Every hook calls the original function first and returns its result unchanged. When the opened path is a `.bgw` file under a `music` folder, the hook writes the signal file. ZMHelper never alters paths, file contents or results, sends nothing to the server, reads no game memory and registers no commands. Unloading (`/unload zmhelper`) removes every hook.

Detours chains hooks, so ZMHelper and XIPivot are designed to hook the same functions side by side. Not every load order has been tested.

## Build

Requires Visual Studio with MSVC C++20 and CMake supporting your Visual Studio generator. Visual Studio 2026 with CMake 4.4.0-rc2 was used for the 2026-11-01 build check; Visual Studio 2022 is the historical build target. Build 32-bit; FFXI is a 32-bit client. The Ashita SDK headers ship with Ashita in `<Ashita>/plugins/sdk`.

```
cmake -B build -A Win32 -DASHITA_SDK_DIR="<Ashita>/plugins/sdk"
cmake --build build --config Release
```

Output: `build/Release/ZMHelper.dll`. Copy it to `<Ashita>/plugins/` and load it with `/load zmhelper` (add that line to your boot script to keep it permanent).

## Credits and licenses

- Microsoft Detours is vendored in `deps/detours` under the MIT license (`deps/detours/license.md`).
- The hook layer follows XIPivot by Renee Koecher, which established which file APIs FFXI's music streaming uses.
- The Ashita SDK headers are LGPL-3.0 and are not vendored; they come from your Ashita install.

For Visual Studio 2026, configure from this helper directory with `cmake -B build -G "Visual Studio 18 2026" -A Win32 -DASHITA_SDK_DIR="<Ashita>/plugins/sdk"`, then build as above. Use a CMake version that lists this generator. The required SDK is external and is not included in this repository or ZIP.
