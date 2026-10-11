A fan port of *Museum Madness* (MECC, 1994) to Godot / Redot.

Instead of rewriting the game from scratch, this runs the original DOS programs inside Godot on a
small built-in PC (an x86 real-mode CPU, VGA, AdLib/OPL3 and Sound Blaster). Everything you see and
hear comes from the original code and data, so the puzzles, timing and dialogue are the real thing.
It runs on desktop and in the browser.

**You need your own copy of the game.** None of the original files are included here.

## Getting started

1. Install [Redot](https://www.redotengine.org/) 26.2 (Godot 4.5 should work too).
2. Copy the files from your *Museum Madness* install (`MUSEUM.COM`, `MUSEUM.RES`, `MUSEUM.NDX`,
   the `MUSEUM*.OVL` files, `MUSEUM.CFG` and the rest of the folder) into `assets/original/`.
   `docs/FILE_INVENTORY.md` lists the files and their SHA-256 hashes if you want to check your copy.
3. Open the project and press Play.

## Controls

- Click once in the window to let the game take the mouse.
- **Ctrl**, **Alt** or **Ctrl+F10** gives the mouse back.
- **Esc** skips the intro (and a few other scenes), **Space** turns dialogue pages.
- Saves go to Godot's user folder (`user://dos/`), or the browser's storage on the web.

## Exporting

Godot can't export `assets/original/` (it's hidden from the editor because Godot would try to load
`MUSEUM.RES` as one of its own resource files), so copy your data into `assets/game/` first:

```
tools/prepare-data.sh        # or tools\prepare-data.ps1 on Windows
```

Then export with the **Web** or **Windows Desktop** preset. The web preset uses the no-threads
build, so any plain static server works, e.g. `npx serve bin/web`. Don't publish an export
anywhere public: it contains the game data.

## Building the native part

The emulator core is a small GDExtension in `native/`. Prebuilt libraries for Windows and the web
are in `bin/`, so you only need this if you change the C++. See `docs/NATIVE_BUILD.md`.

## Layout

```
scripts/vm/        DOS layer (files, memory, mouse, keyboard) and the game scene
native/src/        X86Core: CPU, VGA, timer, OPL3 and Sound Blaster
scenes/vm/         main scene
scripts/formats/   readers for the game's resource archive, images, fonts and text
scripts/inspector/ resource browser for poking around the data files
scripts/port/      an earlier hand-written port of the intro, kept for reference
docs/              file notes and build instructions
tools/             data copy scripts, DOSBox-X launcher for comparing with the original
```

## Status

The intro, the outside of the museum, the Main Hall, the backpack and the exhibits start up and
run. It hasn't been played start to finish yet, so expect rough edges, especially around the
mouse. Bug reports are welcome.

## Legal

*Museum Madness* belongs to its rights holders (originally MECC). This project isn't affiliated
with or endorsed by them, includes none of the game's files, and is meant for people who own the
game. The code in this repository is MIT licensed, except Nuked-OPL3 (LGPL 2.1 or later, see
`native/src/thirdparty/`).
