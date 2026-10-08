#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
export PATH="/opt/homebrew/bin:$PATH"
if ! pkg-config --exists mpv; then
    echo 'mpx needs libmpv. Install it with: brew install mpv' >&2
    exit 1
fi
. "$project_dir/scripts/libmpv-env.sh"
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
stage_parent=$(mktemp -d "${TMPDIR:-/tmp}/mpx-build.XXXXXX")
stage_dir="$stage_parent/staging.noindex"
mkdir -p "$stage_dir"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    # Restore the old app if replacement was interrupted after moving it aside.
    if [ -d "$stage_dir/previous-mpx.app" ] && [ ! -d "$project_dir/build/mpx.app" ]; then
        mv "$stage_dir/previous-mpx.app" "$project_dir/build/mpx.app"
    fi
    for bundle in "$stage_dir/mpx.app" "$stage_dir/previous-mpx.app"; do
        if [ -d "$bundle" ]; then
            "$lsregister" -u "$bundle" >/dev/null 2>&1 || true
        fi
    done
    previous_binary="$stage_dir/previous-mpx.app/Contents/MacOS/mpx-app"
    if [ -f "$previous_binary" ] && /usr/sbin/lsof -t "$previous_binary" >/dev/null 2>&1; then
        # Release mapped pages only after the running previous build exits.
        (
            while /usr/sbin/lsof -t "$previous_binary" >/dev/null 2>&1; do
                sleep 2
            done
            rm -rf "$stage_parent"
        ) </dev/null >/dev/null 2>&1 &
    else
        rm -rf "$stage_parent"
    fi
    exit "$status"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
app_dir="$stage_dir/mpx.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/mpx-app" "$app_dir/Contents/MacOS/mpx-app"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
swift scripts/make-icon.swift "$project_dir/build"
iconutil -c icns build/AppIcon.iconset -o "$app_dir/Contents/Resources/AppIcon.icns"
# Documents may be File Provider managed; Finder metadata invalidates signatures.
xattr -dr com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app_dir" 2>/dev/null || true
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "$project_dir/build/mpx.zip"
# Replace the bundle without overwriting a running executable's mapped pages.
# Keep the previous build in the staging directory until the player exits.
if [ -d "$project_dir/build/mpx.app" ]; then
    mv "$project_dir/build/mpx.app" "$stage_dir/previous-mpx.app"
fi
if ! mv "$app_dir" "$project_dir/build/mpx.app"; then
    if [ -d "$stage_dir/previous-mpx.app" ]; then
        mv "$stage_dir/previous-mpx.app" "$project_dir/build/mpx.app"
    fi
    exit 1
fi
printf 'Built %s/build/mpx.app\n' "$project_dir"
