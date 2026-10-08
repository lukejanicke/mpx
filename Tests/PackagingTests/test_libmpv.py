"""Reject changed build provenance and unrelated private libraries."""
import json
from pathlib import Path
import sys
import tempfile
import hashlib
import subprocess
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from libmpv_build import recipe_hash, sha256, verify_prefix
from package import inventory, fetch_source


class LibmpvProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.recipe = self.root / "recipe"
        self.recipe.mkdir()
        (self.recipe / "fix.patch").write_text("verified patch")
        (self.recipe / "recipe.json").write_text(json.dumps({"local_patch": {"archive": "fix.patch", "sha256": sha256(self.recipe / "fix.patch")}}))
        self.prefix = self.root / "prefix"
        (self.prefix / "lib").mkdir(parents=True)
        self.library = self.prefix / "lib/libmpv.2.dylib"
        self.library.write_bytes(b"verified binary")
        (self.prefix / "build-receipt.json").write_text(json.dumps({"recipe_sha256": recipe_hash(self.recipe), "library_sha256": sha256(self.library)}))

    def test_rejects_modified_patch(self):
        (self.recipe / "fix.patch").write_text("different patch")
        with self.assertRaisesRegex(RuntimeError, "patch checksum"):
            verify_prefix(self.prefix, self.recipe)

    def test_rejects_modified_binary(self):
        self.library.write_bytes(b"different binary")
        with self.assertRaisesRegex(RuntimeError, "libmpv checksum"):
            verify_prefix(self.prefix, self.recipe)

    def test_rejects_receipt_from_different_recipe(self):
        (self.recipe / "recipe.json").write_text((self.recipe / "recipe.json").read_text() + "\n")
        with self.assertRaisesRegex(RuntimeError, "different recipe"):
            verify_prefix(self.prefix, self.recipe)

    def test_only_selected_private_library_is_allowed(self):
        executable = self.root / "app"
        executable.touch()
        unexpected = self.root / "unrelated.dylib"
        unexpected.touch()
        def links(binary):
            return [str(self.library), str(unexpected)] if binary == executable else []
        with patch("package.dependencies", side_effect=links):
            with self.assertRaisesRegex(RuntimeError, "verified libmpv dependency"):
                inventory(executable, self.library)


class SourceMirrorTests(unittest.TestCase):
    def test_interrupted_origin_write_does_not_publish_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            data = b"verified mirrored source"
            checksum = hashlib.sha256(data).hexdigest()
            primary, mirror = "https://primary/source.tar.xz", "https://mirror/source.tar.xz"
            key = hashlib.sha256(primary.encode()).hexdigest()
            origin = cache / (key + ".url")
            origin.write_text("https://obsolete/source.tar.xz")
            resource = {"url": primary, "sha256": checksum}

            def download(args, **kwargs):
                if primary in args:
                    raise subprocess.CalledProcessError(22, args)
                Path(args[-1]).write_bytes(data)

            with patch("package.SOURCE_MIRRORS", {primary: (checksum, mirror)}), patch("package.subprocess.run", side_effect=download):
                with patch.object(Path, "write_text", side_effect=OSError("interrupted metadata write")):
                    with self.assertRaisesRegex(OSError, "interrupted metadata write"):
                        fetch_source((resource, root / "first.tar.xz", cache))
            self.assertFalse((cache / key).exists())
            self.assertFalse(origin.exists())
            with patch("package.SOURCE_MIRRORS", {primary: (checksum, mirror)}), patch("package.subprocess.run", side_effect=download):
                result = fetch_source((resource, root / "second.tar.xz", cache))
            self.assertEqual(result["url"], primary)
            self.assertEqual(result["download_url"], mirror)
            self.assertEqual(result["archive_sha256"], checksum)

    def test_cache_without_origin_still_requires_correct_source_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            primary = "https://primary/source.tar.xz"
            key = hashlib.sha256(primary.encode()).hexdigest()
            cached = cache / key
            data = b"verified source"
            checksum = hashlib.sha256(data).hexdigest()
            cached.write_bytes(data)
            resource = {"url": primary, "sha256": checksum}
            for origin in (None, "", "\n"):
                with self.subTest(origin=origin):
                    if origin is not None:
                        (cache / (key + ".url")).write_text(origin)
                    result = fetch_source((resource, root / "source.tar.xz", cache))
                    self.assertIsNone(result["download_url"])
                    self.assertEqual(result["archive_sha256"], checksum)
            cached.write_bytes(b"corrupt source")
            with self.assertRaisesRegex(RuntimeError, "Source checksum mismatch"):
                fetch_source((resource, root / "corrupt.tar.xz", cache))

    def test_git_archive_cannot_be_an_html_response(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            def download(args, **kwargs):
                Path(args[-1]).write_bytes(b"<html>unexpected response</html>")
            with patch("package.subprocess.run", side_effect=download):
                with self.assertRaisesRegex(RuntimeError, "Invalid source archive"):
                    fetch_source(({"url": "https://github.com/example/source.git", "specs": {"revision": "a" * 40}}, root / "archive.tar.gz", cache))

    def test_invalid_primary_response_uses_exact_repository_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            data = b"original source"
            checksum = hashlib.sha256(data).hexdigest()
            snapshot = root / (checksum + ".tar.bz2")
            snapshot.write_bytes(data)
            primary = "https://primary/source.tar.bz2"
            def download(args, **kwargs):
                Path(args[-1]).write_bytes(data if snapshot.as_uri() in args else b"unexpected response")
            with patch("package.SOURCE_FALLBACKS", {primary: checksum}), patch("package.FALLBACK_DIRECTORY", root), patch("package.subprocess.run", side_effect=download):
                result = fetch_source(({"url": primary, "sha256": checksum}, root / "archive.tar.bz2", cache))
                self.assertEqual(result["archive_sha256"], checksum)
                self.assertTrue(result["download_url"].startswith("repository:"))
                self.assertNotIn(directory, result["download_url"])

    def test_transport_failure_uses_identical_archive_and_records_mirror(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            data = b"same source archive"
            checksum = hashlib.sha256(data).hexdigest()
            primary, mirror = "https://primary/source.tar.xz", "https://mirror/source.tar.xz"
            def download(args, **kwargs):
                if primary in args:
                    raise subprocess.CalledProcessError(22, args)
                Path(args[-1]).write_bytes(data)
            with patch("package.SOURCE_MIRRORS", {primary: (checksum, mirror)}), patch("package.subprocess.run", side_effect=download):
                resource = {"url": primary, "sha256": checksum}
                result = fetch_source((resource, root / "archive.tar.xz", cache))
                self.assertEqual(result["download_url"], mirror)
                self.assertEqual(result["archive_sha256"], checksum)
                cached = fetch_source((resource, root / "second.tar.xz", cache))
                self.assertEqual(cached["download_url"], mirror)

    def test_mirror_cannot_bypass_source_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            checksum = hashlib.sha256(b"expected source").hexdigest()
            primary, mirror = "https://primary/source.tar.xz", "https://mirror/source.tar.xz"
            def download(args, **kwargs):
                if primary in args:
                    raise subprocess.CalledProcessError(22, args)
                Path(args[-1]).write_bytes(b"wrong source")
            with patch("package.SOURCE_MIRRORS", {primary: (checksum, mirror)}), patch("package.subprocess.run", side_effect=download):
                with self.assertRaisesRegex(RuntimeError, "Source checksum mismatch"):
                    fetch_source(({"url": primary, "sha256": checksum}, root / "archive.tar.xz", cache))
                self.assertFalse((cache / hashlib.sha256(primary.encode()).hexdigest()).exists())


if __name__ == "__main__":
    unittest.main()
