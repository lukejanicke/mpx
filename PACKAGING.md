# Building, installing and releasing mpx

Local app updates follow **prepare → user test → accept → install → clean**. The user tests a temporary self-contained app, then acceptance triggers installation of that same app and removal of temporary build artifacts. [AGENTS.md](AGENTS.md) makes this lifecycle mandatory for agents working in this repository.

## Local update workflow

**Implementation status:** the lifecycle below is agreed project policy. The existing scripts still use the legacy paths documented under [Package locally](#package-locally); there is no installation/finalisation helper yet. Agents must account for those outputs explicitly until the scripts enforce this workflow. The commands later in this guide describe current low-level tooling, not a completed finalisation command.

### Locations and ownership

Use `build/development.noindex/` as the single transient root in this checkout (`/Users/lukejanicke/Documents/mpx/build/development.noindex/` on the maintainer's Mac). Its user-facing candidate is always `mpx.app`. Place temporary packaging, verification, staging and rollback material beneath this root and remove it when its operation finishes. Do not create accumulating date/version-named development apps or folders such as `mpx 2.app`.

The final installed app is `/Applications/mpx.app`. Reconfirm the existing installation before replacement; an unexpected destination or app identity needs investigation rather than silently installing another copy.

Reusable data may remain separately after finalisation:

| Location | Retained purpose |
| --- | --- |
| `.build/` | Incremental Swift compilation cache. |
| `build/libmpv/` | Current reusable dependency build, its tools and verified inputs; prune obsolete generations only when no retained app, active process or build references them. |
| `build/source-cache/` | Verified dependency source downloads. |
| `build/fixtures/` | Reusable test media. |

These retained locations are not storage for spare app bundles, temporary app ZIPs or installation backups. Remove disposable icon-generation output with the other transient artifacts. A deliberate full cache purge is separate from routine finalisation and makes subsequent builds slower. Public release artifacts follow the separate publishing workflow; do not create local release archives merely to retain a history of development builds.

### Prepare and test

1. Build and package a self-contained candidate before user testing, using the existing library bundling, signing and provenance checks. The ordinary development app depends on `build/libmpv/` and Homebrew and is unsuitable as the final installed app.
2. Run the relevant automated tests and verify the package's signatures and dependency isolation. Record the candidate's version, build number and a content manifest or digest. Version strings alone do not identify an iteration when source changes share a version.
3. Place the candidate at `build/development.noindex/mpx.app`. Launch this specific path and verify the running executable's location so the user tests the intended copy. Keep only one current candidate, quitting it cleanly before replacing it on another iteration.
4. Tell the user the candidate path and what needs manual testing. Wait for explicit acceptance of that candidate. Further changes require another candidate and acceptance.

The project is inside Documents, where Finder/File Provider metadata has previously invalidated app and XCTest signatures. Validate signing and launch before moving all staging into the project; `.noindex` addresses indexing and is not a signature safeguard. If an operation requires system-temporary scratch, record its exact owned path under the transient root before use. Remove it on completion, failure and catchable termination, and check for abandoned owned scratch on the next invocation. Do not silently scatter untracked builds outside the project.

### Install and clean after acceptance

Acceptance authorises replacement of the installed app and the following cleanup together. It does not authorise a public release, push or release tag. No additional routine cleanup confirmation is needed.

1. Confirm the candidate still matches its recorded identity. Install the exact app tested, without rebuilding, repackaging or changing it after acceptance.
2. Quit running copies cleanly. Preserve the previous installed app temporarily for rollback, then replace `/Applications/mpx.app` with the accepted candidate. Avoid overwriting a running executable or force-quitting it without authorisation.
3. Verify the installed app's contents against the candidate, validate its signature and self-contained dependencies, and check launch from the installed path. If replacement or validation fails, restore the previous installation and report the failure. Retain only material needed for recovery and identify its exact paths.
4. After validation succeeds, unregister discarded temporary bundles from Launch Services and delete workflow-owned candidates, temporary packages, test builds, staging and the rollback copy. Include any legacy outputs generated by the current scripts during this update and any recorded external scratch. Preserve the installed app, user preferences and playback history.
5. Verify the transient root is empty or absent, recorded external scratch is gone, and no workflow-created spare app or temporary archive remains. Report the installed path/version and cleanup result. A cleanup failure leaves finalisation incomplete and must be reported.

Normal completion and catchable termination must clean disposable scratch. Forced termination or power loss can prevent cleanup; the next invocation must detect abandoned workflow-owned artifacts, restore an interrupted installation where necessary, and clean only after checking ownership and active use. Serialise lifecycle operations so one invocation cannot remove another's candidate or recovery material. Do not depend on detached background waiters to remove old running apps eventually.

Before deleting pre-existing leftovers, inventory them and obtain explicit authorisation for that one-time deletion set. Do not use broad deletion patterns across Applications or system temporary directories, follow unexpected symlinks, or remove caller-owned data.

### Script integration still required

- Route `scripts/build.sh`, `scripts/package.sh`, `scripts/app_staging.py` and `bin/mpx` through the agreed transient root and candidate path. Account for intermediate apps, ZIPs and icon output as well as the final candidate.
- Add an installation/finalisation helper that verifies candidate identity, manages replacement and rollback, performs scoped cleanup, and checks the resulting state. Share ownership and interruption-recovery rules across the helpers.
- Fix `scripts/test.sh` ownership: it currently creates a new system-temporary scratch directory by default and never removes it, including on failure. Automatically owned scratch should be cleaned on exit. Caller-provided scratch must survive until its owner finishes using it. In particular, the release workflow reuses its test build for packaged-library verification and must clean it only afterward.
- Validate project-local signatures, launching the correct app, normal cleanup, failure/rollback, interrupted-run recovery and the final installed app's independence from development outputs. Preserve the public release workflow while updating paths.

## Versions and releases

Use `MAJOR.MINOR.PATCH` versions and matching Git tags such as `v0.1.5`. The initial public series is `0.x`, indicating an early product. Increment the patch for fixes or small refinements, the minor for new features, and the major for substantial incompatible changes. Move to `1.0.0` when the supported behaviour is considered stable.

`Resources/Info.plist` contains the visible version (`CFBundleShortVersionString`) and a separate integer build number (`CFBundleVersion`). Increase the build number for every released build. Add a dated entry to `CHANGELOG.md` for each version. Published tags and release assets are fixed: ship a new patch version for corrections instead of replacing an existing release.

## Automatic publishing

Pushing an approved `vMAJOR.MINOR.PATCH` tag triggers `.github/workflows/release.yml`. It checks tag/version agreement, builds on GitHub's Apple silicon `xcode-27` runner, runs the tests, packages the app and dependency sources, checks relocation and signatures, and repeats tests against the bundled libraries with reads from `/opt/homebrew` denied. The release is published only after those steps pass.

Hosted macOS VMs may not provide accelerated OpenGL. The workflow explicitly allows display-dependent tests to skip only when creating that display fails; codec decoding, resume/seek, playback errors, geometry logic, overlay layout and timeline tests still run. Other playback/rendering errors remain failures. **Run the complete local test suite and inspect playback on a supported physical Mac before approving a release tag.** The full local suite does not enable these skips by default.

Only push a version tag after the maintainer approves the release. Ordinary commits do not publish an app. The workflow can also be run manually against `main` to perform a preflight build without publishing. It uploads its packages as workflow artifacts for inspection.

Before a release, update the app version, increment its build number, update the changelog, and verify the changes. Commit them with the existing author/signing identity. After approval, create and push the tag:

```sh
git tag -s v0.1.6 -m 'mpx 0.1.6'
git push origin main
git push origin v0.1.6
```

The version above is an example; it must match the version in `Info.plist`. GitHub Actions creates the downloadable release automatically. Check the workflow result and download/check the resulting assets before announcing it.

## Package locally

Requires the normal build tools plus Python 3.12 or later.

```sh
brew install mpv pkgconf python
scripts/package.sh
```

The script currently first makes the ordinary development build at `build/mpx.app` and `build/mpx.zip`, then packages a separate self-contained release under `build/release/`. It does not replace the development app with the bundled release, install into Applications, or remove these retained outputs. For local updates, account for these legacy outputs under the [local update workflow](#local-update-workflow); the intended project-local paths are not yet implemented by this command.

Build, packaging and package-verification staging currently uses system-temporary directories with `.noindex` app folders. Temporary apps are unregistered from Launch Services before normal cleanup. Failed or interrupted builds restore the previous development app if replacement has not completed. When a previous build is still running, the build script starts a background waiter to remove its temporary copy after it exits. Packaging and verification also clean up on normal termination signals. Forced termination such as `kill -9` or a power loss cannot run cleanup, and the current scripts do not recover abandoned staging on the next run. XCTest scratch has the separate cleanup gap described above.

The package contains mpx's pinned patched libmpv and all linked Homebrew dependencies. Its dependency paths are rewritten to resolve inside `mpx.app/Contents/Frameworks`. Each library and the outer app are ad-hoc signed, and the signature is verified before archiving. No Developer ID certificate or notarisation is configured.

`dependencies/mpv/recipe.json` pins mpv 0.41.0, the installed Homebrew VapourSynth and hotplug backports, the Core Audio patch, Meson and Ninja versions, and build options. `scripts/libmpv_build.py` verifies the inputs and builds into a private generation under `build/libmpv/`. Development builds, tests and packaging select that prefix automatically. Builds require Python 3.12 or later. No installed Homebrew library is replaced.

The builder uses the selected Xcode's Apple Clang, Swift and macOS SDK, plus Homebrew's pkg-config. Its cache records the selected tools, resolved dependency locations and pkg-config file hashes, so a Homebrew revision change creates a new generation even when the upstream version is unchanged. Custom compiler, flag, SDK and dependency-search overrides are rejected with an instruction to unset them; `DEVELOPER_DIR` remains supported for selecting Xcode. The builder constructs `PKG_CONFIG_PATH` from installed Homebrew kegs, replacing any inherited value. The receipt records this build environment, but does not lock every dependency or guarantee byte-identical builds.

The corresponding-source archive's `mpv/` folder includes the original sources, all three patches, recipe, standalone builder and build receipt. Its README gives the rebuild command. The packager accepts only the verified private libmpv as an exception to its Homebrew dependency rule; other unknown libraries remain errors. Automatic audio selection and the AVFoundation workaround remain in app source. Channel routing, custom speaker assignments and physical device changes need hardware coverage beyond initialization tests.

Exact installed Homebrew recipes identify the bundled dependency versions. The packager downloads their source archives, patches and build resources, verifies supplied SHA-256 hashes, and pins Git-based resources to commit IDs. Source archives are cached under `build/source-cache/`. The corresponding-source archive includes those downloads, recipes, Homebrew installation receipts, a manifest and licences. The app also includes licence/copyright notices.

For known download failures, the packager has exact checksum-gated fallbacks: Debian mirrors uchardet 0.0.8, and `dependencies/source-fallbacks/` holds unmodified dav1d, libplacebo and x264 archives for the specific versions or commit listed there. It records the selected source in the manifest. Cached archives whose retrieval origin was not recorded have `download_url: null`; their declared source URL and verified checksum remain available. Fallbacks cannot relax or replace the expected source checksum.

The five release assets are:

- `mpx-VERSION-macos-arm64.zip`: the runnable app, without a Homebrew dependency.
- `mpx-VERSION-dependency-sources.tar.gz`: bundled-library sources and build recipes.
- `dependency-sources.json`: exact dependency/source versions and checksums.
- `THIRD-PARTY.md`: dependency and licence inventory.
- `SHA256SUMS.txt`: checksums of the other four assets.

The downloaded app needs Apple silicon and macOS 27 or later. The full original encoded frame is preserved. SF Symbols are system-provided assets subject to Apple's licence, including the existing app-icon restriction documented in the README.

## Verify locally

```sh
(
set -eu
scripts/make-fixtures.sh
export MPX_TEST_VIDEO_PATH="$PWD/build/fixtures/h264.mp4"
export MPX_TEST_FIXTURE_DIRECTORY="$PWD/build/fixtures"
export MPX_EXPECT_AUDIO_OUTPUT=coreaudio
MPX_TEST_SCRATCH_PATH=$(mktemp -d "${TMPDIR:-/tmp}/mpx-tests.XXXXXX")
export MPX_TEST_SCRATCH_PATH
trap 'rm -rf -- "$MPX_TEST_SCRATCH_PATH"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
scripts/test.sh
MPX_LIBMPV_PREFIX=$(python3 scripts/libmpv_build.py)
export MPX_LIBMPV_PREFIX
python3 scripts/verify-package.py \
  build/release/mpx-0.1.9-macos-arm64.zip "$MPX_TEST_SCRATCH_PATH"
(cd build/release && shasum -a 256 -c SHA256SUMS.txt)
)
```

Replace the archive version with the release being checked. This subshell owns a new scratch directory, retains it through both test stages, and removes it on normal exit, failure or catchable termination. It does not delete a caller's existing scratch directory or clean the app/package outputs. For an agent-managed update, also record the allocated path for interruption recovery as described above.

Verification extracts a temporary copy, checks all binary architectures, signatures and dependency paths, and runs both test bundles against the packaged libraries while sandbox rules deny reads from Homebrew and the selected private libmpv prefix. `MPX_LIBMPV_PREFIX` is required when supplying a test directory. Both test bundles must pass dependency checks before either runs; only system libraries, bundled libraries and the selected Xcode's required test runtimes are allowed. Test subprocesses ignore inherited `DYLD_*` overrides. It leaves the user's Homebrew installation unchanged.
