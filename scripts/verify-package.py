#!/usr/bin/env python3
"""Verify an extracted release and optionally test it without Homebrew access."""
import os
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

from app_staging import temporary_app_directory

from package import dependencies, SYSTEM_PREFIXES
from libmpv_build import verify_prefix


def runpaths(binary, executable):
    output = subprocess.check_output(["otool", "-arch", "arm64", "-l", str(binary)], text=True)
    paths = []
    for value in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)", output):
        for token, base in (("@loader_path", binary.parent), ("@executable_path", executable.parent)):
            if value == token or value.startswith(token + "/"):
                value = str(base) + value[len(token):]
                break
        path = Path(value)
        if not path.is_absolute():
            raise RuntimeError(f"Unsupported test runtime search path: {value}")
        paths.append(path.resolve())
    return paths


def verify(archive, test_directory=None):
    if test_directory is not None:
        prefix = os.environ.get("MPX_LIBMPV_PREFIX")
        if not prefix:
            raise RuntimeError("MPX_LIBMPV_PREFIX is required when verifying packaged tests")
        prefix = Path(prefix).resolve()
        libmpv, _ = verify_prefix(prefix)
    with temporary_app_directory(prefix="mpx-release-check-") as staging:
        root = Path(staging)
        subprocess.run(["ditto", "-x", "-k", str(archive), str(root)], check=True)
        app = root / "mpx.app"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        with (app / "Contents/Info.plist").open("rb") as stream:
            executable_name = plistlib.load(stream)["CFBundleExecutable"]
        frameworks = app / "Contents/Frameworks"
        bundled_libraries = {path.resolve() for path in frameworks.iterdir()}
        if any(not path.is_file() or not path.is_relative_to(frameworks.resolve())
               for path in bundled_libraries):
            raise RuntimeError("Release libraries must be files inside the bundled Frameworks directory")
        binaries = [app / "Contents/MacOS" / executable_name, *frameworks.iterdir()]
        for binary in binaries:
            architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
            if "arm64" not in architectures:
                raise RuntimeError(f"Library does not support Apple silicon: {binary.name}")
            for name in dependencies(binary):
                if name.startswith(SYSTEM_PREFIXES):
                    continue
                if binary.resolve() in bundled_libraries and name == "@rpath/" + binary.name:
                    continue  # dylib's own install name
                resolved = name.replace("@executable_path", str(app / "Contents/MacOS")).replace("@loader_path", str(binary.parent))
                if not name.startswith(("@loader_path/", "@executable_path/")) or Path(resolved).resolve() not in bundled_libraries:
                    raise RuntimeError(f"Unresolved/external release dependency: {name}")
        if not (app / "Contents/Resources/LICENSE").is_file():
            raise RuntimeError("Missing mpx licence")
        if not (app / "Contents/Resources/THIRD-PARTY.md").is_file():
            raise RuntimeError("Missing dependency notices")
        print(f"Verified signatures and relocation for {len(binaries)} binaries", flush=True)
        if test_directory is not None:
            test_directory = Path(test_directory)
            xctest = Path(subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()).resolve()
            platform = Path(subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip())
            # XCTest bundles need Apple's test runtime in addition to system and
            # release libraries. Resolve only these exact names from this Xcode.
            test_runtime = {
                "@rpath/XCTest.framework/Versions/A/XCTest": platform / "Developer/Library/Frameworks/XCTest.framework/Versions/A/XCTest",
                "@rpath/Testing.framework/Versions/A/Testing": platform / "Developer/Library/Frameworks/Testing.framework/Versions/A/Testing",
                "@rpath/libXCTestSwiftSupport.dylib": platform / "Developer/usr/lib/libXCTestSwiftSupport.dylib",
            }
            test_runtime = {name: path.resolve() for name, path in test_runtime.items()}
            allowed_test_libraries = bundled_libraries | set(test_runtime.values())
            host_runpaths = runpaths(xctest, xctest)
            test_bundles = []
            for name in ("PlayerLogicTests", "PlaybackIntegrationTests"):
                candidates = list(test_directory.rglob(name + ".xctest"))
                if len(candidates) != 1:
                    raise RuntimeError(f"Expected one {name} bundle in {test_directory}")
                bundle = root / (name + ".xctest")
                shutil.copytree(candidates[0], bundle)
                binary = bundle / "Contents/MacOS" / name
                for linked in dependencies(binary):
                    if "/Cellar/" in linked or "/opt/homebrew/" in linked or Path(linked).resolve() == libmpv:
                        original = Path(linked).resolve()
                        replacement = frameworks / original.name
                        if not replacement.is_file():
                            raise RuntimeError(f"Missing bundled test dependency: {linked}")
                        subprocess.run(["install_name_tool", "-change", linked, str(replacement), str(binary)], check=True)
                search_paths = runpaths(binary.resolve(), xctest) + host_runpaths
                for linked in dependencies(binary):
                    if linked.startswith(SYSTEM_PREFIXES):
                        continue
                    if linked in test_runtime:
                        # Preserve these short install names: expanding them can
                        # overflow the test binary's Mach-O header. Refuse missing
                        # runtimes or any shadow copy in the existing search paths.
                        matches = {(folder / linked.removeprefix("@rpath/")).resolve()
                                   for folder in search_paths
                                   if (folder / linked.removeprefix("@rpath/")).is_file()}
                        if matches != {test_runtime[linked]}:
                            raise RuntimeError(f"Unresolved/external Xcode test runtime: {linked}")
                        continue
                    path = Path(linked)
                    if not path.is_absolute() or not path.is_file() or path.resolve() not in allowed_test_libraries:
                        raise RuntimeError(f"Unresolved/external test dependency: {linked}")
                subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
                test_bundles.append(bundle)
            profile = '(version 1) (allow default) (deny file-read* (subpath "/opt/homebrew"))'
            profile += ' (deny file-read* (subpath ' + json.dumps(str(prefix)) + '))'
            # The checked LC_RPATHs must determine loading, not inherited overrides.
            test_environment = {name: value for name, value in os.environ.items() if not name.startswith("DYLD_")}
            for bundle in test_bundles:
                subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, str(xctest), str(bundle)],
                               env=test_environment, timeout=90, check=True)
            print("All tests passed against bundled libraries with Homebrew and private libmpv reads denied", flush=True)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit("Usage: scripts/verify-package.py APP_ZIP [TEST_SCRATCH_DIRECTORY]")
    verify(Path(sys.argv[1]), sys.argv[2] if len(sys.argv) == 3 else None)
