#!/usr/bin/env python3
"""Check version/tag agreement and extract its changelog entry for a release."""
from pathlib import Path
import plistlib
import re
import sys


def main(tag, output):
    match = re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag)
    if not match:
        raise SystemExit("Release tags must use vMAJOR.MINOR.PATCH")
    version = tag[1:]
    with Path("Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info["CFBundleShortVersionString"] != version:
        raise SystemExit("Release tag and app version differ")
    changelog = Path("CHANGELOG.md").read_text()
    heading = re.search(r"^## \[" + re.escape(version) + r"\] - \d{4}-\d{2}-\d{2}\s*$", changelog, re.M)
    if not heading:
        raise SystemExit("Add a dated changelog entry for this release")
    notes = changelog[heading.end():].split("\n## ", 1)[0].strip()
    if not notes:
        raise SystemExit("Release notes are empty")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(f"mpx {version}\n\n{notes}\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: scripts/release-notes.py vVERSION OUTPUT_FILE")
    main(sys.argv[1], sys.argv[2])
