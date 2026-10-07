# Changelog

## [0.1.6] - 2026-10-07

- Improve control readability with a translucent black panel, rounded corners, and consistent margins and padding.
- Centre the symbols inside uniform 44 × 44-point button targets and fit the time target to its text.
- Centre the scrub hit area on the seek line and keep all control targets inside the panel.
- Show the hover timestamp above the panel on its own noninteractive dark background.
- Keep controls visible while hovering the panel padding.

## [0.1.5] - 2026-10-04

First public release of mpx, a minimal native macOS video player powered by libmpv.

- Native windows, menus, Dock presence, file opening and a command-line launcher that returns immediately.
- Opaque white SF Symbol controls, a progress/scrub line and hover-time preview.
- Trackpad zoom and pan, with aspect-constrained window resizing.
- Resume playback, keyboard volume controls and accelerated scanning.
- Self-contained Apple silicon app with bundled playback libraries, licence notices, matching dependency sources and checksums.

Requires **Apple silicon and macOS 27 or later**. The app is ad-hoc signed and **not notarised**; see the [README](https://github.com/lukejanicke/mpx#download-the-app) for installation and first-open instructions. The initial renderer targets SDR; native HDR output is not implemented. This is an early release.

Download the `mpx-0.1.5-macos-arm64.zip` app asset. The larger `mpx-0.1.5-dependency-sources.tar.gz` is for source/licence access and rebuilding the bundled libraries; it is not needed to run the app. `SHA256SUMS.txt` lists the asset checksums.

mpx's original code is GPLv3-or-later. SF Symbols remain subject to Apple's SDK licence; the existing `play.rectangle` app icon has the restriction described in the README.
