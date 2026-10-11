## Contributing

Thanks for wanting to help. A few things to keep in mind:

- **Never commit game files.** That includes anything from `assets/original/` or `assets/game/`,
  decoded images, sounds or text dumps, and exported builds. If a bug needs data to reproduce,
  describe where in the game it happens instead.
- Keep it faithful. The point is to run the original as it was. Fixes should make the emulated
  hardware behave more like a real PC, not change how the game plays.
- Match the style of the code around you. GDScript uses tabs and static types; the C++ in
  `native/` follows godot-cpp conventions.
- If you change `native/src/`, rebuild the libraries in `bin/` (see `docs/NATIVE_BUILD.md`) and
  mention which platforms you built in the pull request.

For bugs, say what you did, what you expected and what happened, plus whether it was desktop or
web. A screenshot helps a lot.
