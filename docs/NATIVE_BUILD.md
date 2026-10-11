# Building the `museum_vm` GDExtension

The game runs the original DOS programs on `X86Core` (C++, `native/src/`). The built libraries go
to `bin/` and are loaded through `bin/museum_vm.gdextension`.

## Requirements

- godot-cpp, branch `4.5` (Redot 26.2 reports Godot 4.5.2 API compatibility).
- The engine's API dump: `redot --headless --dump-extension-api --dump-gdextension-interface`
  (writes `extension_api.json` and `gdextension_interface.h`; copy the header over
  `godot-cpp/gdextension/gdextension_interface.h`).
- SCons (`pip install scons`).
- Windows: MinGW-w64 g++ (MSYS2).
- Web: emsdk with emscripten **4.0.10** (the version the Redot 26.2 web templates were built with;
  see `"4.0.10"` in the templates' `godot.js`). Export with the `web_dlink_*` templates
  ("Extensions Support" on).

## Commands

From `native/`, with `GODOT_CPP` pointing at the godot-cpp checkout and `API` at the dumped
`extension_api.json`:

```bash
GODOT_CPP=/path/to/godot-cpp scons platform=windows use_mingw=yes target=template_debug custom_api_file=$API
GODOT_CPP=/path/to/godot-cpp scons platform=windows use_mingw=yes target=template_release custom_api_file=$API
# web, inside an emsdk environment (threads and no-threads variants):
GODOT_CPP=/path/to/godot-cpp scons platform=web target=template_release threads=no custom_api_file=$API
GODOT_CPP=/path/to/godot-cpp scons platform=web target=template_debug threads=no custom_api_file=$API
GODOT_CPP=/path/to/godot-cpp scons platform=web target=template_release custom_api_file=$API
GODOT_CPP=/path/to/godot-cpp scons platform=web target=template_debug custom_api_file=$API
```

godot-cpp builds its static library on the first run for each platform/target (about 15 minutes).
Objects go to `native/build/<platform>.<target>/`, so platforms don't clobber each other.

## Third-party code

- Nuked-OPL3 (`native/src/thirdparty/opl3.c`, `opl3.h`), LGPL 2.1 or later, licence text in
  `native/src/thirdparty/NUKED_OPL3_LICENSE`.
