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
brew install mpv pkgconf python
scripts/build.sh
open build/mpx.app
```

The build script compiles the pinned patched libmpv into a private prefix under `build/libmpv`, using existing Homebrew dependencies. It does not replace Homebrew libraries. Python 3.12 or later is required; Meson and Ninja are installed in a private build environment. The first build takes longer; later builds reuse the verified library. The script also creates `build/mpx.zip`; that development ZIP requires its local build prefix and Homebrew dependencies. Use `scripts/package.sh` to create a self-contained release instead; see [PACKAGING.md](PACKAGING.md).

Launch from the cloned source directory:

```sh
bin/mpx
bin/mpx '/path/to/video.mkv'
```

For the downloaded app installed in Applications, use `open -a mpx '/path/to/video.mkv'`.

The launcher returns immediately. Each file opens in an empty window if one is available; otherwise it opens a new window. Dragging a file onto a video replaces it. File > New Window, File > Open, Open Recent, Finder's Open With, and the Dock are supported.

The app plays on opening and remembers each file's previous position. Completed videos reopen at the beginning. Closing the last window leaves the app running in the Dock; Command–Q quits.

## Controls

Fully opaque white SF Symbols and text sit over a black rectangle at 65% opacity, with 6-point rounded corners and 8 points of padding around the seek hit area at the top and sides, and 18.5 points beneath and beside the lower control hover boxes. The panel has matching 16-point side and bottom margins inside the video, reduced in very narrow windows. The background expands for the narrow-window layout. The hover timestamp has its own small dark background with 4-point rounded corners above the panel. The overlay appears on mouse movement or playback input and fades away after two seconds. Hovering, interacting, or keyboard focus keeps it visible.

Empty windows are plain black, centred in the screen’s usable area, with 16:9 content at half the screen width. Each window is independent, without tab bars or tab menu options. Opening a file adjusts the window to the video’s display proportions; resizing preserves them, so the video fills the content area without added black bars. Portrait videos fit within the available screen height. The complete encoded frame is preserved; black borders encoded into a video remain visible.

The five playback buttons stay centred beneath the progress line. The time hover box aligns with the visible progress line’s left end, and the utility group’s outer edge aligns with its right end. Time text is centred within its hover box with equal padding on all four sides. The gap from the lower hover boxes to the visible scrub stroke is 18.5 points, matching their side and bottom padding. In narrow windows, time and utilities move to a row above playback instead of shrinking the 44 × 44-point button targets. The cursor remains an arrow over the controls. Buttons have a subtle rounded hover highlight and pressed response. Fullscreen preserves the whole image and may have margins where the screen proportions differ; the controls stay inside the video frame.

| Action | Input |
| --- | --- |
| Play / pause | Space |
| Back / forward 10 seconds | Tap Left / Right |
| Seek / scrub | Click the progress line / drag its position thumb |
| Muted scan backward / forward | Hold Left / Right |
| Start / end | Option–Left / Option–Right |
| Volume | Up / Down, in 5% increments |
| Mute / unmute | Click the speaker button or M |
| Fullscreen | Control–Command–F, double-click video, or fullscreen button |
| Leave fullscreen / cancel scan | Escape |
| Zoom | Pinch, or View > Zoom In / Zoom Out |
| Pan enlarged video | Two-finger scrolling |
| Reset zoom and pan to fit | Command–0 |
| Go to a timestamp | Click elapsed time or Shift–Command–G |
| Open file / new window | Command–O / Command–N |
| Close window / quit app | Command–W / Command–Q |

A rounded progress line sits above the buttons. Its hit area extends equally past the visible stroke on all four sides, with 8-point padding to the panel’s left, right, and top edges. The played section is opaque white; the unplayed section is white at 20% opacity (80% transparency). An opaque white thumb appears when the pointer approaches the current position and remains visible during dragging. A small timestamp above the pointer previews the seek time on hover and follows dragging, staying inside the window at either endpoint. Clicking the line seeks. Dragging previews frames while paused, then restores the previous play/pause state on release, preserving mute. The elapsed-time display follows the dragged position. The line fades with the other controls and stays visible while hovered or dragged.

The speaker is a clickable mute/unmute button with the same hover highlight and 44 × 44-point target as the other buttons. Muting preserves the current volume setting. Up while muted unmutes at 5% and saves that as the new volume; subsequent Up/Down presses adjust it in 5% steps. Muted or 0% volume uses `speaker.slash.fill`. The four nonzero ranges are >0–25% (`speaker.fill`), >25–50% (`speaker.wave.1.fill`), >50–75% (`speaker.wave.2.fill`), and >75–100% (`speaker.wave.3.fill`).

Scanning begins after a 0.4-second hold, starting at 2× and increasing to 4×, 8×, then 16× at one-second intervals. Releasing returns to the previous play/pause and mute states. A tap seeks on release. Reverse scanning uses seek previews; smoothness varies by codec and keyframe spacing.

Zoom ranges from fit to 8× and anchors at the pointer. Panning stops at the image edges. The overlay stays fixed. Audio and subtitle tracks are available in native menus; Subtitles > Open Subtitle File supports external subtitles.

## Dependencies and local data

- Xcode / Swift, Python 3.12 or later, and Homebrew's `mpv` and `pkgconf` are needed to build. `brew install mpv pkgconf python` installs the dependencies if absent.
- Development builds use mpx's pinned patched libmpv and Homebrew dependencies at runtime. The build scripts select the private library automatically. Downloadable release apps include the linked libraries inside the app bundle.
- The libmpv patch corrects Core Audio initialization on macOS 27. Audio-output selection remains automatic; AVFoundation retains its per-player volume/mute workaround if selected.
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

Tests cover time input, scan acceleration, pointer-centred zoom, pan limits, return to fit, resume-file identity, completed-file handling, decoding, resume autoplay, exact paused seeking, playback error reporting, scan state restoration, saved-history reloading, and rendering after paused window resizing. The window tests verify the centred 16:9 empty-window default, matching content proportions on portrait/ultrawide file replacement, native resize ratio configuration, and rendered content without added margins at constrained sizes. Volume tests cover every icon boundary and clicking the speaker to mute/unmute without changing the volume setting. Scrubbing tests cover input clamping, hover-thumb proximity, stable drag position, exact release seeking, pause/mute restoration, and saving the selected position. Overlay tests verify independent centring, alignment and non-overlapping groups in wide and narrow windows, preserved button sizes, and hover-time mapping without seeking. The codec fixtures are H.264/MP4, HEVC/MKV, VP9/WebM, AV1/MKV, MPEG-4/AVI, and FFV1/MKV. All 22 app tests passed on macOS 27.0.1 / Apple silicon on 8 October 2026 with Core Audio selected. Seven packaging tests check provenance rejection, unknown private libraries and checksum-preserving source fallbacks.

GitHub's hosted runner cannot always create accelerated OpenGL. CI may explicitly skip the nine display-dependent tests in that environment; the complete suite and playback inspection must pass locally on a supported physical Mac before approving a release.

Native UI checks confirmed video rendering, overlay appearance, ten-second keyboard skipping, fullscreen, mute, empty-window launching, and saved-position reopening. The CLI also rejects network URLs and returns immediately after launching.

`scripts/test.sh` stages XCTest builds in a temporary directory to avoid Finder metadata breaking test-bundle signatures inside Documents. Zoom and pan geometry are tested automatically. Physical pinch gestures and trackpad feel have been confirmed by the user on the Mac.

See [PACKAGING.md](PACKAGING.md) for release packaging and verification.
