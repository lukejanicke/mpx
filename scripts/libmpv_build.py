#!/usr/bin/env python3
"""Build and verify mpx's pinned libmpv without replacing installed libraries.

Print the private prefix on stdout. Build output stays in build.log. This file
and the recipe directory also work from the corresponding-source archive.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile


PROJECT = Path(__file__).resolve().parent.parent
RECIPE = PROJECT / "dependencies/mpv"
PKG_CONFIG = Path("/opt/homebrew/bin/pkg-config")
DEPENDENCY_NAMES = ("libavcodec", "libavfilter", "libavformat", "libavutil", "libavdevice",
                    "libswresample", "libswscale", "libplacebo", "libass", "mujs", "lcms2",
                    "libarchive", "libbluray", "luajit", "rubberband", "uchardet",
                    "vapoursynth", "zimg", "libjpeg", "vulkan")
# This recipe supports the selected Xcode and Homebrew, not custom toolchains
# or flags. Reject overrides rather than silently reusing an incompatible build.
BUILD_OVERRIDES = ("CC", "CXX", "OBJC", "OBJCXX", "AR", "LD", "CC_LD", "CXX_LD",
                   "OBJC_LD", "OBJCXX_LD", "SWIFTC", "SWIFTFLAGS",
                   "CFLAGS", "CXXFLAGS", "CPPFLAGS", "OBJCFLAGS", "OBJCXXFLAGS", "LDFLAGS",
                   "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "TOOLCHAINS", "ARCHFLAGS",
                   "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH",
                   "LIBRARY_PATH", "CMAKE_PREFIX_PATH", "PKG_CONFIG", "PKG_CONFIG_LIBDIR",
                   "PKG_CONFIG_SYSROOT_DIR")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def recipe_hash(folder=RECIPE):
    recipe = json.loads((folder / "recipe.json").read_text())
    patch = folder / recipe["local_patch"]["archive"]
    if sha256(patch) != recipe["local_patch"]["sha256"]:
        raise RuntimeError("Local libmpv patch checksum mismatch")
    return hashlib.sha256((folder / "recipe.json").read_bytes() + patch.read_bytes()
                          + Path(__file__).read_bytes()).hexdigest()


def verify_prefix(prefix, folder=RECIPE):
    prefix = Path(prefix).resolve()
    receipt = json.loads((prefix / "build-receipt.json").read_text())
    if receipt["recipe_sha256"] != recipe_hash(folder):
        raise RuntimeError("libmpv was built with a different recipe")
    library = prefix / "lib/libmpv.2.dylib"
    if sha256(library) != receipt["library_sha256"]:
        raise RuntimeError("Built libmpv checksum mismatch")
    return library.resolve(), receipt


def pkgconfig_path(opt=Path("/opt/homebrew/opt")):
    # Resolve opt aliases to versioned kegs, preserving discovery order while
    # removing aliases. Homebrew revision changes must invalidate the cache.
    return ":".join(dict.fromkeys(str(p.resolve()) for p in sorted(opt.glob("*/lib/pkgconfig"))))


def build_inputs(identity):
    env = dict(os.environ)
    overrides = [name for name in BUILD_OVERRIDES if env.get(name)]
    if overrides:
        raise RuntimeError("Unsupported libmpv build overrides; unset " + ", ".join(overrides))
    # Do not discover compilers or pkg-config through the caller's PATH.
    # DEVELOPER_DIR remains supported: xcrun resolves it to the recorded tools.
    env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    def output(*args):
        return subprocess.check_output(args, env=env, text=True).strip()

    compiler = Path(output("/usr/bin/xcrun", "--sdk", "macosx", "--find", "clang")).resolve(strict=True)
    swift = Path(output("/usr/bin/xcrun", "--sdk", "macosx", "--find", "swiftc")).resolve(strict=True)
    sdk = Path(output("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path")).resolve(strict=True)
    pkgconfig = PKG_CONFIG.resolve(strict=True)
    env.update(CC=str(compiler), OBJC=str(compiler),
               CXX=str(compiler.with_name("clang++")), OBJCXX=str(compiler.with_name("clang++")),
               SDKROOT=str(sdk), PKG_CONFIG=str(pkgconfig), PKG_CONFIG_PATH=pkgconfig_path())
    env["PATH"] = str(compiler.parent) + ":" + env["PATH"]
    inputs = {"recipe_sha256": identity,
              "compiler": output(str(compiler), "--version"), "compiler_path": str(compiler),
              "swift_compiler": output(str(swift), "--version"), "swift_compiler_path": str(swift),
              "sdk": output("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"),
              "sdk_path": str(sdk),
              "pkg_config": {"path": str(pkgconfig), "version": output(str(pkgconfig), "--version")},
              "dependencies": {}, "dependency_files": {},
              "pkg_config_path": env["PKG_CONFIG_PATH"]}
    for name in DEPENDENCY_NAMES:
        inputs["dependencies"][name] = output(str(pkgconfig), "--modversion", name)
        pc = Path(output(str(pkgconfig), "--path", name)).resolve(strict=True)
        inputs["dependency_files"][name] = {"path": str(pc), "sha256": sha256(pc)}
    return env, inputs


def build(folder, root):
    if sys.version_info < (3, 12):
        raise RuntimeError("Building libmpv requires Python 3.12 or later (brew install python)")
    if platform.machine() != "arm64" or sys.platform != "darwin":
        raise RuntimeError("This libmpv recipe requires Apple silicon macOS")
    folder, root = folder.resolve(), root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    recipe = json.loads((folder / "recipe.json").read_text())
    identity = recipe_hash(folder)
    env, inputs = build_inputs(identity)
    key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:16]
    generation = root / key
    prefix = generation / "prefix"
    with (root / "build.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (prefix / "build-receipt.json").is_file():
            verify_prefix(prefix, folder)
            return prefix
        generation.mkdir(exist_ok=True)
        log = (generation / "build.log").open("a")

        def run(args, cwd=None):
            print("$ " + repr(list(map(str, args))), file=log, flush=True)
            result = subprocess.run(list(map(str, args)), cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f"libmpv command failed; see {generation / 'build.log'}")

        print(f"Building pinned libmpv; log: {generation / 'build.log'}", file=sys.stderr)
        downloads = root / "downloads"
        downloads.mkdir(exist_ok=True)
        archives = []
        for item in recipe["sources"]:
            archive = downloads / item["archive"]
            if not archive.exists():
                supplied = folder / item["archive"]
                if supplied.is_file():
                    shutil.copy2(supplied, archive)
                else:
                    partial = archive.with_suffix(archive.suffix + ".part")
                    run(["curl", "-fLsS", "--retry", "2", "--connect-timeout", "20", "--max-time", "300",
                         item["url"], "-o", partial])
                    partial.replace(archive)
            if sha256(archive) != item["sha256"]:
                raise RuntimeError(f"libmpv source checksum mismatch: {archive}")
            archives.append(archive)
        tools = root / f"tools-{recipe['meson']}-{recipe['ninja']}"
        if not (tools / "bin/meson").exists():
            run([sys.executable, "-m", "venv", tools])
            run([tools / "bin/pip", "install", "meson==" + recipe["meson"], "ninja==" + recipe["ninja"]])
        env["PATH"] = str(tools / "bin") + ":" + env["PATH"]
        source = generation / "mpv-0.41.0"
        if not source.exists():
            with tarfile.open(archives[0]) as archive:
                archive.extractall(generation, filter="data")
            for patch in [*archives[1:], folder / recipe["local_patch"]["archive"]]:
                run(["patch", "-p1", "-i", patch], cwd=source)
            (source / ".mpx-patched").write_text(identity)
        if not (source / ".mpx-patched").is_file():
            raise RuntimeError(f"Incomplete source extraction/patching; move aside {generation} and retry")
        work = generation / "compile"
        if not (work / "build.ninja").exists():
            run(["meson", "setup", work, source, "--prefix=" + str(prefix), "--libdir=lib",
                 "--buildtype=release", "--wrap-mode=nofallback", *recipe["options"]])
        run(["meson", "compile", "-C", work, "-j", "4"])
        run(["meson", "install", "-C", work])
        receipt = {**inputs, "version": recipe["version"], "options": recipe["options"],
                   "library_sha256": sha256(prefix / "lib/libmpv.2.dylib")}
        (prefix / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        log.close()
        verify_prefix(prefix, folder)
        return prefix


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe-dir", type=Path, default=RECIPE)
    parser.add_argument("--build-root", type=Path, default=PROJECT / "build/libmpv")
    args = parser.parse_args()
    try:
        print(build(args.recipe_dir, args.build_root))
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
