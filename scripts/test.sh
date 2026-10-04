#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
export PATH="/opt/homebrew/bin:$PATH"
# Avoid inherited Finder metadata on XCTest bundles inside Documents.
test_dir=${MPX_TEST_SCRATCH_PATH:-$(mktemp -d "${TMPDIR:-/tmp}/mpx-tests.XXXXXX")}
swift test --scratch-path "$test_dir"
printf 'Test build artifacts: %s\n' "$test_dir"
