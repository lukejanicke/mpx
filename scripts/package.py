#!/usr/bin/env python3
"""Bundle the linked Homebrew libraries, licences and corresponding sources.

Only modifies a staged copy. Refuses unresolved non-system dependencies and
source checksum mismatches; release archives are written after verification.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import zipfile

from app_staging import temporary_app_directory
from libmpv_build import RECIPE, verify_prefix


SYSTEM_PREFIXES = ("/System/Library/", "/usr/lib/")


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def dependencies(binary):
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in run("otool", "-L", str(binary)).splitlines()[1:]]


def inventory(executable, libmpv=None):
    graph, pending = {}, [executable.resolve()]
    while pending:
        binary = pending.pop()
        if binary in graph:
            continue
        linked = {}
        for name in dependencies(binary):
            if name.startswith(SYSTEM_PREFIXES):
                continue
            path = Path(name)
            if not path.is_absolute() or not path.exists():
                raise RuntimeError(f"Unresolved dependency in {binary.name}: {name}")
            path = path.resolve()
            if path == binary:  # dylib's own install name
                continue
            if "/Cellar/" not in str(path) and path != libmpv:
                raise RuntimeError(f"Expected Homebrew or the verified libmpv dependency: {name}")
            linked[name] = path
            pending.append(path)
        graph[binary] = linked
    libraries = sorted(p for p in graph if p != executable.resolve())
    if len({p.name for p in libraries}) != len(libraries):
        raise RuntimeError("Bundled libraries have conflicting filenames")
    return graph, libraries


def formula_metadata(libraries):
    kegs = set()
    for library in libraries:
        cellar = next(p for p in library.parents if p.name == "Cellar")
        relative = library.relative_to(cellar)
        kegs.add(cellar / relative.parts[0] / relative.parts[1])
    # Read the recipe actually installed, rather than today's Homebrew formula.
    ruby = r'''
require "formulary"
require "json"
resources = lambda { |r| {name:r.name, url:r.url, sha256:r.checksum.to_s, specs:r.specs} }
puts JSON.generate(ARGV.map { |root|
  recipe = Dir["#{root}/.brew/*.rb"].first
  f = Formulary.factory(recipe)
  {name:f.name, version:f.pkg_version.to_s, license:f.license, homepage:f.homepage,
   keg:root, recipe:recipe, source:resources.call(f.stable.resource),
   resources:f.resources.map(&resources),
   patches:f.stable.patches.select { |p| p.respond_to?(:resource) }.map { |p| resources.call(p.resource) }}
})
'''
    env = dict(os.environ, HOMEBREW_DEVELOPER="1", HOMEBREW_NO_AUTO_UPDATE="1")
    return json.loads(run("brew", "ruby", "-e", ruby, *map(str, sorted(kegs)), env=env))


def source_url(resource):
    url = resource["url"]
    revision = resource.get("specs", {}).get("revision")
    if url.endswith(".git"):
        if not revision:
            raise RuntimeError(f"Source must be pinned to a commit: {url}")
        if url.startswith("https://github.com/"):
            repo = url[len("https://github.com/"):-4]
            return f"https://codeload.github.com/{repo}/tar.gz/{revision}", ".tar.gz"
        if url.startswith("https://code.videolan.org/"):
            repo = url[:-4]
            name = repo.rsplit("/", 1)[-1]
            return f"{repo}/-/archive/{revision}/{name}-{revision}.tar.gz", ".tar.gz"
        raise RuntimeError(f"Unsupported pinned Git source: {url}")
    path = urllib.parse.urlparse(url).path
    suffix = next((s for s in (".tar.gz", ".tar.xz", ".tar.bz2", ".tgz", ".zip", ".patch")
                   if path.endswith(s)), ".source")
    return url, suffix


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()


def fetch_source(task):
    resource, destination, cache = task
    url, _ = source_url(resource)
    key = hashlib.sha256(url.encode()).hexdigest()
    cached = cache / key
    if not cached.exists():
        temporary = cache / (key + ".part")
        subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--connect-timeout", "20",
                        "--max-time", "300", "--silent", "--show-error", url, "-o", str(temporary)], check=True)
        temporary.rename(cached)
    checksum = sha256(cached)
    expected = resource.get("sha256")
    if expected and checksum != expected:
        raise RuntimeError(f"Source checksum mismatch: {url}")
    shutil.copy2(cached, destination)
    # Git archives are pinned by immutable commit; record their archive checksum.
    return {**resource, "download_url": url, "archive": destination.name, "archive_sha256": checksum}


def is_notice(name):
    return re.match(r"^(copying|copyright|licen[cs]e|notice|authors|gpl|lgpl|ftl)([._-]|$)", name, re.I) is not None


def archive_notices(archive, target):
    """Read notice files without extracting arbitrary archive paths."""
    if tarfile.is_tarfile(archive):
        with tarfile.open(archive) as source:
            for member in source:
                if member.isfile() and member.size < 500_000 and is_notice(Path(member.name).name):
                    digest = hashlib.sha256(member.name.encode()).hexdigest()[:12]
                    output = target / f"{digest}-{Path(member.name).name}"
                    output.write_bytes(source.extractfile(member).read())
    elif zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                if not member.is_dir() and member.file_size < 500_000 and is_notice(Path(member.filename).name):
                    digest = hashlib.sha256(member.filename.encode()).hexdigest()[:12]
                    (target / f"{digest}-{Path(member.filename).name}").write_bytes(source.read(member))


def collect_sources(formulae, root, notices, cache):
    tasks, owners, manifests = [], {}, []
    for formula in formulae:
        name = formula["name"]
        folder = root / name
        folder.mkdir()
        shutil.copy2(formula["recipe"], folder / Path(formula["recipe"]).name)
        shutil.copy2(Path(formula["keg"]) / "INSTALL_RECEIPT.json", folder / "INSTALL_RECEIPT.json")
        manifest = {k: v for k, v in formula.items() if k not in ("keg", "recipe", "source", "resources", "patches")}
        manifest["sources"] = []
        manifests.append(manifest)
        notice_folder = notices / name
        notice_folder.mkdir()
        for existing in Path(formula["keg"]).rglob("*"):
            if existing.is_file() and is_notice(existing.name) and existing.stat().st_size < 500_000:
                relative = existing.relative_to(formula["keg"])
                output = notice_folder / relative
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(existing, output)
        resources = [("source", formula["source"])]
        resources += [(f"resource-{i}-{r['name']}", r) for i, r in enumerate(formula["resources"])]
        resources += [(f"patch-{i}", r) for i, r in enumerate(formula["patches"])]
        for label, resource in resources:
            _, extension = source_url(resource)
            destination = folder / (label + extension)
            tasks.append((resource, destination, cache))
            owners[str(destination)] = (manifest, notice_folder)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        futures = {executor.submit(fetch_source, task): task for task in tasks}
        for future in concurrent.futures.as_completed(futures):
            _, destination, _ = futures[future]
            manifest, notice_folder = owners[str(destination)]
            manifest["sources"].append(future.result())
            archive_notices(destination, notice_folder)
            print(f"Collected source: {manifest['name']}/{destination.name}", flush=True)
    for manifest in manifests:
        manifest["sources"].sort(key=lambda r: r["archive"])
    return manifests


def collect_libmpv(prefix, root, notices):
    library, receipt = verify_prefix(prefix)
    recipe = json.loads((RECIPE / "recipe.json").read_text())
    folder = root / "mpv"
    folder.mkdir()
    notice_folder = notices / "mpv"
    notice_folder.mkdir()
    for name in ("recipe.json", recipe["local_patch"]["archive"]):
        shutil.copy2(RECIPE / name, folder / name)
    shutil.copy2(Path(__file__).with_name("libmpv_build.py"), folder / "libmpv_build.py")
    shutil.copy2(Path(prefix) / "build-receipt.json", folder / "build-receipt.json")
    sources = []
    for item in recipe["sources"]:
        source = Path(prefix).parent.parent / "downloads" / item["archive"]
        if sha256(source) != item["sha256"]:
            raise RuntimeError(f"libmpv corresponding-source checksum mismatch: {source}")
        target = folder / item["archive"]
        shutil.copy2(source, target)
        sources.append({**item, "archive_sha256": sha256(target)})
        archive_notices(target, notice_folder)
    sources.append({**recipe["local_patch"], "archive_sha256": sha256(folder / recipe["local_patch"]["archive"])})
    return {"name": "mpv", "version": recipe["version"], "license": recipe["license"],
            "homepage": recipe["homepage"], "build": receipt, "sources": sources,
            "recipe": "recipe.json", "builder": "libmpv_build.py"}


def main(app_path, output_path):
    app_path, output = Path(app_path).resolve(), Path(output_path).resolve()
    project = Path(__file__).resolve().parent.parent
    output.mkdir(parents=True, exist_ok=True)
    cache = project / "build/source-cache"
    cache.mkdir(parents=True, exist_ok=True)
    with (app_path / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info["CFBundleShortVersionString"]
    executable = app_path / "Contents/MacOS" / info["CFBundleExecutable"]
    architecture = run("lipo", "-archs", str(executable))
    if architecture != "arm64":
        raise RuntimeError(f"This release recipe expects Apple silicon, got {architecture}")
    prefix = os.environ.get("MPX_LIBMPV_PREFIX")
    if not prefix:
        raise RuntimeError("Use scripts/package.sh to select the pinned libmpv")
    libmpv, receipt = verify_prefix(prefix)
    graph, libraries = inventory(executable, libmpv)
    if libmpv not in libraries:
        raise RuntimeError("The app does not link mpx's pinned libmpv; rebuild it")
    formulae = formula_metadata([p for p in libraries if p != libmpv])
    name = f"mpx-{version}-macos-arm64"
    source_name = f"mpx-{version}-dependency-sources"
    with temporary_app_directory(prefix="mpx-package-") as staging:
        staging = Path(staging)
        app = staging / "mpx.app"
        shutil.copytree(app_path, app)
        frameworks = app / "Contents/Frameworks"
        frameworks.mkdir()
        resources = app / "Contents/Resources"
        notices = resources / "Licenses"
        notices.mkdir()
        shutil.copy2(project / "LICENSE", resources / "LICENSE")
        source_root = staging / source_name
        source_root.mkdir()
        source_manifest = collect_sources(formulae, source_root, notices, cache)
        source_manifest.append(collect_libmpv(prefix, source_root, notices))
        source_manifest.sort(key=lambda item: item["name"])
        (source_root / "manifest.json").write_text(json.dumps(source_manifest, indent=2) + "\n")
        shutil.copy2(project / "LICENSE", source_root / "LICENSE")
        homebrew_license = Path(run("brew", "--repository")) / "LICENSE.txt"
        shutil.copy2(homebrew_license, source_root / "HOMEBREW-LICENSE.txt")
        shutil.copy2(homebrew_license, notices / "HOMEBREW-LICENSE.txt")
        (source_root / "README.md").write_text(
            "# mpx dependency sources\n\n"
            "These sources, patches and build recipes correspond to the libraries bundled with this release. "
            "Resources include source embedded into libraries at build time. Upstream licences remain in each archive; "
            "copies of notices are also inside mpx.app/Contents/Resources/Licenses.\n\n"
            "`manifest.json` records exact versions, source locations and checksums. Git resources are pinned to immutable commits. "
            "`INSTALL_RECEIPT.json` records Homebrew's build environment and dependency versions. "
            "The mpv folder contains the pinned upstream archive, both Homebrew backports, the mpx channel-layout patch, "
            "recipe.json, libmpv_build.py and build-receipt.json. With Python 3.12 or later and the listed Homebrew "
            "dependencies installed, run `python3 mpv/libmpv_build.py --recipe-dir mpv --build-root /tmp/mpx-libmpv-rebuild` "
            "from this directory. It verifies and uses the included sources and never replaces Homebrew libraries. "
            "Other `.rb` recipes specify build commands and patches. Rebuild those using Homebrew and the included recipes, "
            "staging each listed resource under the path named in its recipe. mpx's source and release scripts are in "
            "https://github.com/lukejanicke/mpx at the matching release tag. System libraries supplied by macOS are not bundled.\n")
        rows = ["# Third-party libraries", "", "mpx uses libmpv and FFmpeg. The distributed build uses GPLv3-or-later components.", "",
                "Matching dependency source archives and build recipes accompany this release on GitHub.", "",
                "| Library | Version | Licence metadata |", "| --- | --- | --- |"]
        for formula in source_manifest:
            rows.append(f"| {formula['name']} | {formula['version']} | {json.dumps(formula['license'])} |")
        rows += ["", "Complete upstream licence and copyright notices are in `Licenses/` and the source archives.", "",
                 "Apple's SF Symbols are system-provided assets governed by Apple's SDK licence, not mpx's GPL licence. "
                 "The current icon uses play.rectangle; Apple's SDK terms prohibit system-provided symbols in app icons."]
        (resources / "THIRD-PARTY.md").write_text("\n".join(rows) + "\n")
        library_manifest = []
        for binary, links in graph.items():
            is_app = binary == executable.resolve()
            target = app / "Contents/MacOS" / info["CFBundleExecutable"] if is_app else frameworks / binary.name
            if not is_app:
                shutil.copy2(binary, target)
                target.chmod(0o755)
        for binary, links in graph.items():
            is_app = binary == executable.resolve()
            target = app / "Contents/MacOS" / info["CFBundleExecutable"] if is_app else frameworks / binary.name
            if not is_app:
                subprocess.run(["install_name_tool", "-id", "@rpath/" + binary.name, str(target)], check=True)
                library_manifest.append({"file": binary.name, "original": str(binary), "original_sha256": sha256(binary)})
            for original, linked in links.items():
                replacement = ("@executable_path/../Frameworks/" if is_app else "@loader_path/") + linked.name
                subprocess.run(["install_name_tool", "-change", original, replacement, str(target)], check=True)
        (resources / "dependencies.json").write_text(json.dumps(library_manifest, indent=2) + "\n")
        # Verify that relocation removed every non-system absolute dependency.
        for target in [app / "Contents/MacOS" / info["CFBundleExecutable"], *frameworks.iterdir()]:
            for linked in dependencies(target):
                if linked.startswith(SYSTEM_PREFIXES) or linked.startswith("@rpath/"):
                    continue
                resolved = linked.replace("@executable_path", str(app / "Contents/MacOS")).replace("@loader_path", str(target.parent))
                if not linked.startswith("@") or not Path(resolved).is_file():
                    raise RuntimeError(f"Release still has an external dependency: {target.name}: {linked}")
        subprocess.run(["xattr", "-cr", str(app)], check=True)
        for target in frameworks.iterdir():
            subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        app_archive = output / (name + ".zip")
        subprocess.run(["ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(app), str(app_archive)], check=True)
        source_archive = output / (source_name + ".tar.gz")
        with tarfile.open(source_archive, "w:gz") as archive:
            def without_local_owner(member):
                member.uid = member.gid = 0
                member.uname = member.gname = ""
                return member
            archive.add(source_root, arcname=source_name, filter=without_local_owner)
        shutil.copy2(resources / "THIRD-PARTY.md", output / "THIRD-PARTY.md")
        shutil.copy2(source_root / "manifest.json", output / "dependency-sources.json")
        checksums = output / "SHA256SUMS.txt"
        checksums.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in
                                     [app_archive, source_archive, output / "THIRD-PARTY.md", output / "dependency-sources.json"]))
        print(f"Packaged {len(libraries)} libraries from {len(source_manifest)} projects", flush=True)
        print(app_archive, flush=True)
        print(source_archive, flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: scripts/package.py APP_PATH OUTPUT_DIRECTORY")
    main(sys.argv[1], sys.argv[2])
