# mpx

A minimal native macOS video player powered by libmpv. Native windows and menus, simple SF Symbol controls, trackpad zoom and pan, and broad codec support.

Requires **Apple silicon and macOS 27 or later**. Intel Macs and older macOS versions are not supported.

## Download the app

Download the `mpx-…-macos-arm64.zip` asset from [Releases](https://github.com/lukejanicke/mpx/releases/latest), unzip it, and drag `mpx.app` into Applications. The release bundles its playback libraries; Homebrew and Xcode are not needed to run it.

The release is ad-hoc signed, **not Developer ID signed or notarised**. macOS may block its first launch. If you trust this download, follow [Apple’s instructions for opening an app from an unidentified developer](https://support.apple.com/102445): try opening it, then use **System Settings > Privacy & Security > Open Anyway** if that option is available. Managed Macs may prohibit exceptions. Do not disable Gatekeeper system-wide.

`SHA256SUMS.txt` accompanies each release. You can check an app archive against its listed SHA-256 with `shasum -a 256 mpx-…-macos-arm64.zip`.

## Clone and build

Install Xcode 27 or later with its command-line tools, and [Homebrew](https://brew.sh/). Complete Xcode’s initial setup before building. Then:

```sh
git clone https://github.com/lukejanicke/mpx.git
cd mpx
brew install mpv pkgconf
scripts/build.sh
open build/mpx.app
```

The development build uses your installed Homebrew libraries. The build script also creates `build/mpx.zip`; that small development ZIP requires Homebrew too. Use `scripts/package.sh` to create a self-contained release instead; see [PACKAGING.md](PACKAGING.md).

Launch from the cloned source directory:

```sh
bin/mpx
bin/mpx '/path/to/video.mkv'
```

For the downloaded app installed in Applications, use `open -a mpx '/path/to/video.mkv'`.

The launcher returns immediately. Each file opens in an empty window if one is available; otherwise it opens a new window. Dragging a file onto a video replaces it. File > New Window, File > Open, Open Recent, Finder's Open With, and the Dock are supported.

The app plays on opening and remembers each file's previous position. Completed videos reopen at the beginning. Closing the last window leaves the app running in the Dock; Command–Q quits.

## Controls

Fully opaque white SF Symbols and text sit directly over the video, with no shadows or controls background. They appear on mouse movement or playback input and fade away after two seconds. Hovering, interacting, or keyboard focus keeps them visible.

Empty windows are plain black, centred in the screen’s usable area, with 16:9 content at half the screen width. Each window is independent, without tab bars or tab menu options. Opening a file adjusts the window to the video’s display proportions; resizing preserves them, so the video fills the content area without added black bars. Portrait videos fit within the available screen height. The complete encoded frame is preserved; black borders encoded into a video remain visible.

The five playback buttons stay centred beneath the progress line. Elapsed/total time aligns with its left edge, and volume/fullscreen with its right edge. In narrow windows, time and utilities move to a row above playback instead of shrinking the buttons. Interactive controls use a pointing-hand cursor and buttons have a subtle pressed response. Fullscreen preserves the whole image and may have margins where the screen proportions differ; the controls stay inside the video frame.

| Action | Input |
| --- | --- |
| Play / pause | Space |
| Back / forward 10 seconds | Tap Left / Right |
| Seek / scrub | Click the progress line / drag its position thumb |
| Muted scan backward / forward | Hold Left / Right |
| Start / end | Option–Left / Option–Right |
| Volume | Up / Down, in 5% increments |
| Mute / unmute | M |
| Fullscreen | Control–Command–F, double-click video, or fullscreen button |
| Leave fullscreen / cancel scan | Escape |
| Zoom | Pinch, or View > Zoom In / Zoom Out |
| Pan enlarged video | Two-finger scrolling |
| Reset zoom and pan to fit | Command–0 |
| Go to a timestamp | Click elapsed time or Shift–Command–G |
| Open file / new window | Command–O / Command–N |
| Close window / quit app | Command–W / Command–Q |

A rounded progress line spans 90% of the video width above the buttons. The played section is opaque white; the unplayed section is white at 20% opacity (80% transparency). An opaque white thumb appears when the pointer approaches the current position and remains visible during dragging. A small timestamp above the pointer previews the seek time on hover and follows dragging, staying inside the window at either endpoint. Clicking the line seeks. Dragging previews frames while paused, then restores the previous play/pause state on release, preserving mute. The elapsed-time display follows the dragged position. The line fades with the other controls and stays visible while hovered or dragged.

The speaker is an indicator only; volume and mute are controlled with the keyboard. Muted or 0% volume uses `speaker.slash.fill`. The four nonzero ranges are >0–25% (`speaker.fill`), >25–50% (`speaker.wave.1.fill`), >50–75% (`speaker.wave.2.fill`), and >75–100% (`speaker.wave.3.fill`).

Scanning begins after a 0.4-second hold, starting at 2× and increasing to 4×, 8×, then 16× at one-second intervals. Releasing returns to the previous play/pause and mute states. A tap seeks on release. Reverse scanning uses seek previews; smoothness varies by codec and keyframe spacing.

Zoom ranges from fit to 8× and anchors at the pointer. Panning stops at the image edges. The overlay stays fixed. Audio and subtitle tracks are available in native menus; Subtitles > Open Subtitle File supports external subtitles.

## Dependencies and local data

- Xcode / Swift and Homebrew's `mpv` and `pkgconf` are needed to build. `brew install mpv pkgconf` installs them if absent.
- Development builds use Homebrew libmpv and FFmpeg at runtime; rebuild after an incompatible library upgrade. Downloadable release apps include the linked libraries inside the app bundle.
- The renderer uses libmpv's OpenGL render API. OpenGL is deprecated by Apple but remains available on the target Mac. This version targets SDR output; native HDR/extended-dynamic-range output has not been implemented.
- Playback history is local JSON at `~/Library/Application Support/mpx/playback-history.json`. It is saved every five seconds, on file replacement, close, and quit. Replacing a file at the same path resets its stored position. History is limited to 1,000 entries.
- macOS manages Open Recent separately. Audio volume is saved in the app's local preferences.
- No network media opening, mpv configuration loading, scripts, plugins, playlists UI, or playback history service.

File Provider/Finder can attach metadata to app bundles in Documents after signing; keeping the runnable app in Applications avoids that packaging issue.

## Licence

mpx’s original source code is licensed under **GPLv3-or-later**; see [LICENSE](LICENSE). The release uses GPL-enabled libmpv/FFmpeg and other third-party libraries, with their own upstream licences and notices. Matching dependency sources, patches, Homebrew recipes and checksums are supplied as a separate release asset; licence notices are also included in the app bundle.

Copyright © 2026 Luke Janicke.

SF Symbols are Apple-provided assets under Apple’s SDK licence, not the GPL. The current app icon uses `play.rectangle`; [Apple’s SDK terms, section 2.10](https://www.apple.com/legal/sla/docs/xcode.pdf), prohibit system-provided symbols in app icons. That restriction remains relevant to GitHub distribution.

## Verification

```sh
scripts/make-fixtures.sh
MPX_TEST_VIDEO_PATH="$PWD/build/fixtures/h264.mp4" \
MPX_TEST_FIXTURE_DIRECTORY="$PWD/build/fixtures" scripts/test.sh
```

Tests cover time input, scan acceleration, pointer-centred zoom, pan limits, return to fit, resume-file identity, completed-file handling, decoding, resume autoplay, exact paused seeking, playback error reporting, scan state restoration, saved-history reloading, and rendering after paused window resizing. The window tests verify the centred 16:9 empty-window default, matching content proportions on portrait/ultrawide file replacement, native resize ratio configuration, and rendered content without added margins at constrained sizes. Volume tests cover every icon boundary and mute. Scrubbing tests cover input clamping, hover-thumb proximity, stable drag position, exact release seeking, pause/mute restoration, and saving the selected position. Overlay tests verify independent centring, alignment and non-overlapping groups in wide and narrow windows, preserved button sizes, and hover-time mapping without seeking. The codec fixtures are H.264/MP4, HEVC/MKV, VP9/WebM, AV1/MKV, MPEG-4/AVI, and FFV1/MKV. All 20 tests passed on macOS 27.0.1 / Apple silicon on 4 October 2026.

GitHub's hosted runner cannot always create accelerated OpenGL. CI may explicitly skip the seven display-dependent tests in that environment; the complete suite and playback inspection must pass locally on a supported physical Mac before approving a release.

Native UI checks confirmed video rendering, overlay appearance, ten-second keyboard skipping, fullscreen, mute, empty-window launching, and saved-position reopening. The CLI also rejects network URLs and returns immediately after launching.

`scripts/test.sh` stages XCTest builds in a temporary directory to avoid Finder metadata breaking test-bundle signatures inside Documents. Zoom and pan geometry are tested automatically. Physical pinch gestures and trackpad feel have been confirmed by the user on the Mac.

See [PACKAGING.md](PACKAGING.md) for release packaging and verification.
