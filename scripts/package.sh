#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
export PATH="/opt/homebrew/bin:$PATH"
scripts/build.sh
python3 scripts/package.py build/mpx.app build/release
