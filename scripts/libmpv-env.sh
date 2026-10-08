#!/bin/sh
# Source after setting project_dir. The private prefix comes first so SwiftPM
# and the packager select the same verified libmpv; Homebrew stays unchanged.
MPX_LIBMPV_PREFIX=$(python3 "$project_dir/scripts/libmpv_build.py")
export MPX_LIBMPV_PREFIX
dependency_pkgconfig=$(python3 -c 'import sys; sys.path.insert(0, "scripts"); from libmpv_build import pkgconfig_path; print(pkgconfig_path())')
export PKG_CONFIG_PATH="$MPX_LIBMPV_PREFIX/lib/pkgconfig:$dependency_pkgconfig"
