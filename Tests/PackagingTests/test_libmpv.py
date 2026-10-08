"""Reject changed build provenance and unrelated private libraries."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from libmpv_build import recipe_hash, sha256, verify_prefix
from package import inventory


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


if __name__ == "__main__":
    unittest.main()
