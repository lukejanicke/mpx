# Versions and releases

Use `MAJOR.MINOR.PATCH` versions and matching Git tags such as `v0.1.5`. The initial public series is `0.x`, indicating an early product. Increment the patch for fixes or small refinements, the minor for new features, and the major for substantial incompatible changes. Move to `1.0.0` when the supported behaviour is considered stable.

`Resources/Info.plist` contains the visible version (`CFBundleShortVersionString`) and a separate integer build number (`CFBundleVersion`). Increase the build number for every released build. Add a dated entry to `CHANGELOG.md` for each version. Published tags and release assets are fixed: ship a new patch version for corrections instead of replacing an existing release.

## Automatic publishing

Pushing an approved `vMAJOR.MINOR.PATCH` tag triggers `.github/workflows/release.yml`. It checks tag/version agreement, builds on GitHub's Apple silicon `xcode-27` runner, runs the tests, packages the app and dependency sources, checks relocation and signatures, and repeats tests against the bundled libraries with reads from `/opt/homebrew` denied. The release is published only after those steps pass.

Hosted macOS VMs may not provide accelerated OpenGL. The workflow explicitly allows nine display-dependent tests to skip only when creating that display fails; codec decoding, resume/seek, playback errors, geometry logic, overlay layout and timeline tests still run. Other playback/rendering errors remain failures. **Run the complete 22-test suite and inspect playback on a supported physical Mac before approving a release tag.** The full local suite does not enable these skips by default.

Only push a version tag after the maintainer approves the release. Ordinary commits do not publish an app. The workflow can also be run manually against `main` to perform a preflight build without publishing. It uploads its packages as workflow artifacts for inspection.

Before a release, update the app version, increment its build number, update the changelog, and verify the changes. Commit them with the existing author/signing identity. After approval, create and push the tag:

```sh
git tag -s v0.1.6 -m 'mpx 0.1.6'
git push origin main
git push origin v0.1.6
```

The version above is an example; it must match the version in `Info.plist`. GitHub Actions creates the downloadable release automatically. Check the workflow result and download/check the resulting assets before announcing it.

## Package locally

Requires the normal build tools plus Python 3 (available with Xcode's command-line tools).

```sh
brew install mpv pkgconf python
scripts/package.sh
```

The script first makes the ordinary development build, then packages a separate self-contained release under `build/release/`. It does not replace the development app with the bundled release.

Temporary app bundles live in `.noindex` staging folders and are unregistered from Launch Services before cleanup. Failed or interrupted builds restore the previous development app if replacement has not completed. When a previous build is still running, its temporary copy is removed after it exits. Packaging and verification also clean up on normal termination signals. Forced termination such as `kill -9` or a power loss cannot run cleanup.

The package contains mpx's pinned patched libmpv and all linked Homebrew dependencies. Its dependency paths are rewritten to resolve inside `mpx.app/Contents/Frameworks`. Each library and the outer app are ad-hoc signed, and the signature is verified before archiving. No Developer ID certificate or notarisation is configured.

`dependencies/mpv/recipe.json` pins mpv 0.41.0, the installed Homebrew VapourSynth and hotplug backports, the Core Audio patch, Meson and Ninja versions, and build options. `scripts/libmpv_build.py` verifies the inputs and builds into a private generation under `build/libmpv/`. Development builds, tests and packaging select that prefix automatically. Builds require Python 3.12 or later. No installed Homebrew library is replaced.

The corresponding-source archive's `mpv/` folder includes the original sources, all three patches, recipe, standalone builder and build receipt. Its README gives the rebuild command. The packager accepts only the verified private libmpv as an exception to its Homebrew dependency rule; other unknown libraries remain errors. Automatic audio selection and the AVFoundation workaround remain in app source. Channel routing, custom speaker assignments and physical device changes need hardware coverage beyond initialization tests.

Exact installed Homebrew recipes identify the bundled dependency versions. The packager downloads their source archives, patches and build resources, verifies supplied SHA-256 hashes, and pins Git-based resources to commit IDs. Source archives are cached under `build/source-cache/`. The corresponding-source archive includes those downloads, recipes, Homebrew installation receipts, a manifest and licences. The app also includes licence/copyright notices.

For known download failures, the packager has exact checksum-gated fallbacks: Debian mirrors uchardet 0.0.8, and `dependencies/source-fallbacks/` holds unmodified dav1d, libplacebo and x264 archives for the specific versions or commit listed there. It records the selected source in the manifest. Fallbacks cannot relax or replace the expected source checksum.

The five release assets are:

- `mpx-VERSION-macos-arm64.zip`: the runnable app, without a Homebrew dependency.
- `mpx-VERSION-dependency-sources.tar.gz`: bundled-library sources and build recipes.
- `dependency-sources.json`: exact dependency/source versions and checksums.
- `THIRD-PARTY.md`: dependency and licence inventory.
- `SHA256SUMS.txt`: checksums of the other four assets.

The downloaded app needs Apple silicon and macOS 27 or later. The full original encoded frame is preserved. SF Symbols are system-provided assets subject to Apple's licence, including the existing app-icon restriction documented in the README.

## Verify locally

```sh
scripts/make-fixtures.sh
export MPX_TEST_VIDEO_PATH="$PWD/build/fixtures/h264.mp4"
export MPX_TEST_FIXTURE_DIRECTORY="$PWD/build/fixtures"
export MPX_EXPECT_AUDIO_OUTPUT=coreaudio
export MPX_TEST_SCRATCH_PATH="$(mktemp -d "${TMPDIR:-/tmp}/mpx-tests.XXXXXX")"
scripts/test.sh
export MPX_LIBMPV_PREFIX="$(python3 scripts/libmpv_build.py)"
python3 scripts/verify-package.py \
  build/release/mpx-0.1.8-macos-arm64.zip "$MPX_TEST_SCRATCH_PATH"
(cd build/release && shasum -a 256 -c SHA256SUMS.txt)
```

Replace the archive version with the release being checked. Verification extracts a temporary copy, checks all binary architectures, signatures and dependency paths, and runs both test bundles against the packaged libraries while sandbox rules deny reads from Homebrew and the selected private libmpv prefix. It leaves the user's Homebrew installation unchanged.
