# ZoneMusic 1.2.1

ZoneMusic is a dynamic music overhaul for Final Fantasy XI with 379 themed MP3 tracks covering zone ambience, day/night variations, solo and party battle music, notorious monsters, low HP, chocobo riding, fishing, Mog House music, and other contextual states.

## Complete Ashita Package

Version 1.2.1 is now distributed as a single complete Ashita package.

The archive includes:
- ZoneMusic addon
- 379 MP3 tracks
- ZMHelper.dll
- XIPivot DAT replacements

Everything is already placed under the correct `ashita` folder structure.

## Features

- Unique music selected around each zone's atmosphere, terrain, history, and mood.
- Separate day and night themes where available.
- Separate solo and party battle music.
- Dynamic battle music that can resume instead of restarting after short gaps between fights.
- Optional random battle music.
- Contextual music for notorious monsters, low HP, chocobo riding, fishing, Mog House, and other states.
- Native FFXI music can take control when required for cutscenes, menus, and engine-driven events.
- Coverage currently includes the base game, Rise of the Zilart, and Chains of Promathia.

## ZMHelper

ZMHelper monitors native FFXI music playback and allows ZoneMusic to hand control back to the game when an engine-controlled track begins.

This is used for events where FFXI itself needs to control music timing, including certain cutscenes, menus, bosses, and cinematic sequences.

## XIPivot DAT Support

The package also includes the ZoneMusic DAT replacements under:

`ashita/polplugins/DATs/zonemusicDATS/`

These provide additional native-engine music coverage for cutscenes, menus, and other events better handled through FFXI's original `.bgw` system.

XIPivot is required for these DAT replacements to take effect.

## Installation

1. Extract the archive into the folder containing your existing `ashita` folder.
2. Allow the included `ashita` folder to merge with your existing installation.
3. Confirm these paths exist:
   - `ashita/addons/zonemusic/zonemusic.lua`
   - `ashita/addons/zonemusic/sounds/`
   - `ashita/plugins/ZMHelper.dll`
   - `ashita/polplugins/DATs/zonemusicDATS/`
4. Load ZMHelper with `/load zmhelper`
5. Load ZoneMusic with `/addon load zonemusic`
6. Use `/zm` to open the settings window.

## Commands

`/zm` - Open settings  
`/zm on` or `/zm off` - Start or stop ZoneMusic  
`/zm solo`, `/zm party`, or `/zm auto` - Set battle music mode  
`/zm random` - Toggle random battle music  
`/zm dynamic` - Toggle dynamic battle music  
`/zm fade` - Toggle fade in/out  
`/zm help` - List available commands

## Version 1.2.1

- Cleaned MP3 metadata.
- Updated and repackaged the public release.
- Added ZMHelper directly to the complete package.
- Integrated the XIPivot DAT payload into the same Ashita-ready archive.
- ZoneMusic is now distributed as one complete installation package instead of multiple separate downloads.
