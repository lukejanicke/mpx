# Patched libmpv

mpx pins mpv 0.41.0 with two Homebrew backports and `audio-channel-layout.patch`. The local patch replaces the invalid ChannelMap property call with AudioChannelLayout on Input scope, element 0, and zero-initializes its layout allocations. It fixes initialization on the tested macOS 27 Mac without forcing the app's audio backend.

The [upstream omission proposal](https://github.com/mpv-player/mpv/pull/18463) remains open as of 8 October 2026. The property correction preserves layout information rather than removing the call, but accepting the layout does not establish correct custom or multichannel speaker routing. Review the patch when adopting a newer upstream version.

`recipe.json` records immutable sources and SHA256 checksums. Build with `python3 scripts/libmpv_build.py` from the project root. The app build, test and package scripts do this automatically. Nothing is installed into Homebrew. Corresponding-source packages include the recipe, builder, build receipt, upstream archive and every patch.
