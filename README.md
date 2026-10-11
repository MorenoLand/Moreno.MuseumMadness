A fan port of *Museum Madness* (MECC, 1994) to Godot / Redot.

Instead of rewriting the game from scratch, this runs the original DOS programs inside Godot on a
small built-in PC (an x86 real-mode CPU, VGA, AdLib/OPL3 and Sound Blaster). Everything you see and
hear comes from the original code and data, so the puzzles, timing and dialogue are the real thing.
It runs on desktop and in the browser.

Nothing here is prebuilt and none of the game's files are included: you build it yourself and
supply your own copy of the game.

## What you need

- [Redot](https://www.redotengine.org/) 26.2 (or Godot 4.5).
- Your own copy of *Museum Madness* for DOS.
- Python 3 and SCons (`pip install scons`).
- A C++ compiler: MinGW-w64 or Visual Studio on Windows, GCC or Clang on Linux, Xcode on macOS.
- For browser builds: [emsdk](https://emscripten.org/docs/getting_started/downloads.html) with
  emscripten 4.0.10 (the version Redot 26.2's web templates use).

## Setup

1. **Get godot-cpp** (branch `4.5`) somewhere outside this repo:

   ```
   git clone -b 4.5 https://github.com/godotengine/godot-cpp.git
   ```

2. **Dump your engine's API** and give godot-cpp the matching header:

   ```
   redot --headless --dump-extension-api --dump-gdextension-interface
   cp gdextension_interface.h godot-cpp/gdextension/
   ```

3. **Build the emulator library** from `native/` (the first build also compiles godot-cpp, which
   takes a while):

   ```
   cd native
   GODOT_CPP=/path/to/godot-cpp scons target=template_debug custom_api_file=/path/to/extension_api.json
   ```

   On Windows with MinGW add `platform=windows use_mingw=yes`. The library lands in `bin/`.
   Build `target=template_release` as well if you plan to export. More detail, including the web
   build, is in `docs/NATIVE_BUILD.md`.

4. **Add your game files.** Copy everything from your *Museum Madness* folder (`MUSEUM.COM`,
   `MUSEUM.RES`, `MUSEUM.NDX`, the `MUSEUM*.OVL` files, `MUSEUM.CFG` and the rest) into
   `assets/original/`. `docs/FILE_INVENTORY.md` lists the files and their SHA-256 hashes if you
   want to check your copy.

5. **Open the project** in Redot and press Play.

## Controls

- Click once in the window to let the game take the mouse.
- **Ctrl**, **Alt** or **Ctrl+F10** gives the mouse back.
- **Esc** skips the intro (and a few other scenes), **Space** turns dialogue pages.
- **F1** opens the save menu: export your saves as a `.zip`, import one, or open the save folder.
- **F2** switches between the original shape and stretched to fill the window.

On desktop, saves live in `%APPDATA%\Museum Madness\dos\` (Windows) or the matching user data
folder on other systems. In the browser they're kept in the site's storage, so use **F1 > Export
saves** if you want a copy you can move around.

## Exporting

Godot can't export `assets/original/` (it's hidden from the editor because Godot would try to load
`MUSEUM.RES` as one of its own resource files), so copy your data into `assets/game/` first:

```
tools/prepare-data.sh        # or tools\prepare-data.ps1 on Windows
```

Then export with the **Web** or **Windows Desktop** preset. You'll need the export templates for
your engine version, and for the web the release libraries built with emsdk (see
`docs/NATIVE_BUILD.md`). The web preset uses the no-threads build, so any plain static server
works, e.g. `npx serve bin/web`.

An export contains the game data, so keep it to yourself rather than putting it online.

## Layout

```
scripts/vm/        DOS layer (files, memory, mouse, keyboard), save menu and the game scene
native/src/        X86Core: CPU, VGA, timer, OPL3 and Sound Blaster
scenes/vm/         main scene
scripts/formats/   readers for the game's resource archive, images, fonts and text
scripts/inspector/ resource browser for poking around the data files
scripts/port/      an earlier hand-written port of the intro, kept for reference
docs/              file notes and build instructions
tools/             scripts that copy your game data for export
```

## Status

The intro, the outside of the museum, the Main Hall and the exhibits run, and an exhibit can be
finished. It hasn't been played start to finish yet, so expect rough edges. Bug reports are
welcome.

## Legal

*Museum Madness* belongs to its rights holders (originally MECC). This project isn't affiliated
with or endorsed by them, includes none of the game's files, and is meant for people who own the
game. The code in this repository is MIT licensed, except Nuked-OPL3 (LGPL 2.1 or later, see
`native/src/thirdparty/`).
