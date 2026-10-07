#!/usr/bin/env python3
"""Verify an extracted release and optionally test it without Homebrew access."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from app_staging import temporary_app_directory

from package import dependencies, SYSTEM_PREFIXES


def verify(archive, test_directory=None):
    with temporary_app_directory(prefix="mpx-release-check-") as staging:
        root = Path(staging)
        subprocess.run(["ditto", "-x", "-k", str(archive), str(root)], check=True)
        app = root / "mpx.app"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        with (app / "Contents/Info.plist").open("rb") as stream:
            executable_name = plistlib.load(stream)["CFBundleExecutable"]
        frameworks = app / "Contents/Frameworks"
        binaries = [app / "Contents/MacOS" / executable_name, *frameworks.iterdir()]
        for binary in binaries:
            architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
            if "arm64" not in architectures:
                raise RuntimeError(f"Library does not support Apple silicon: {binary.name}")
            for name in dependencies(binary):
                if name.startswith(SYSTEM_PREFIXES):
                    continue
                if name == "@rpath/" + binary.name:
                    continue  # dylib's own install name
                resolved = name.replace("@executable_path", str(app / "Contents/MacOS")).replace("@loader_path", str(binary.parent))
                if not name.startswith(("@loader_path/", "@executable_path/")) or not Path(resolved).is_file():
                    raise RuntimeError(f"Unresolved/external release dependency: {name}")
        if not (app / "Contents/Resources/LICENSE").is_file():
            raise RuntimeError("Missing mpx licence")
        if not (app / "Contents/Resources/THIRD-PARTY.md").is_file():
            raise RuntimeError("Missing dependency notices")
        print(f"Verified signatures and relocation for {len(binaries)} binaries", flush=True)
        if test_directory:
            test_directory = Path(test_directory)
            xctest = subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()
            for name in ("PlayerLogicTests", "PlaybackIntegrationTests"):
                candidates = list(test_directory.rglob(name + ".xctest"))
                if len(candidates) != 1:
                    raise RuntimeError(f"Expected one {name} bundle in {test_directory}")
                bundle = root / (name + ".xctest")
                shutil.copytree(candidates[0], bundle)
                binary = bundle / "Contents/MacOS" / name
                for linked in dependencies(binary):
                    if "/Cellar/" in linked or "/opt/homebrew/" in linked:
                        original = Path(linked).resolve()
                        replacement = frameworks / original.name
                        if not replacement.is_file():
                            raise RuntimeError(f"Test dependency is not bundled: {linked}")
                        subprocess.run(["install_name_tool", "-change", linked, str(replacement), str(binary)], check=True)
                subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
                profile = '(version 1) (allow default) (deny file-read* (subpath "/opt/homebrew"))'
                subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, xctest, str(bundle)],
                               env=os.environ, timeout=90, check=True)
            print("All tests passed against bundled libraries with Homebrew reads denied", flush=True)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit("Usage: scripts/verify-package.py APP_ZIP [TEST_SCRATCH_DIRECTORY]")
    verify(Path(sys.argv[1]), sys.argv[2] if len(sys.argv) == 3 else None)
