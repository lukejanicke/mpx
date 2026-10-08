"""Cache inputs follow the selected toolchain and installed dependency revision."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import libmpv_build as builder


class BuildInputsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.compiler = self.root / "Xcode/usr/bin/clang"
        self.compiler.parent.mkdir(parents=True)
        self.compiler.touch()
        self.swift = self.compiler.with_name("swiftc")
        self.swift.touch()
        self.sdk = self.root / "Xcode/SDKs/MacOSX27.sdk"
        self.sdk.mkdir(parents=True)
        self.pkgconfig = self.root / "pkgconf/3.0.7/bin/pkg-config"
        self.pkgconfig.parent.mkdir(parents=True)
        self.pkgconfig.touch()
        self.opt = self.root / "opt"
        self.opt.mkdir()
        for revision in ("1.0_1", "1.0_2"):
            pc = self.root / "Cellar/example" / revision / "lib/pkgconfig/example.pc"
            pc.parent.mkdir(parents=True)
            pc.write_text("Version: 1.0\n")
        self.alias = self.opt / "example"
        self.alias.symlink_to(self.root / "Cellar/example/1.0_1", target_is_directory=True)
        self.compiler_version = "Apple clang version 21.0.0"
        self.swift_version = "Apple Swift version 6.5"
        original_path = builder.pkgconfig_path
        for mock in (patch.dict(os.environ, {}, clear=True),
                     patch.object(builder, "DEPENDENCY_NAMES", ("example",)),
                     patch.object(builder, "PKG_CONFIG", self.pkgconfig),
                     patch.object(builder, "pkgconfig_path", side_effect=lambda: original_path(self.opt)),
                     patch.object(builder.subprocess, "check_output", side_effect=self.output)):
            mock.start()
            self.addCleanup(mock.stop)

    def output(self, args, *, env, text):
        if args == ("/usr/bin/xcrun", "--sdk", "macosx", "--find", "clang"):
            return str(self.compiler)
        if args == ("/usr/bin/xcrun", "--sdk", "macosx", "--find", "swiftc"):
            return str(self.swift)
        if args == ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"):
            return str(self.sdk)
        if args == ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"):
            return "27.0"
        if args == (str(self.compiler), "--version"):
            return self.compiler_version
        if args == (str(self.swift), "--version"):
            return self.swift_version
        if args == (str(self.pkgconfig), "--version"):
            return "3.0.7"
        if args == (str(self.pkgconfig), "--modversion", "example"):
            return "1.0"
        if args == (str(self.pkgconfig), "--path", "example"):
            return str(self.alias / "lib/pkgconfig/example.pc")
        raise AssertionError(f"Unexpected tool lookup: {args}")

    @staticmethod
    def key(inputs):
        return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()

    def test_rejects_unsupported_overrides_before_cache_lookup(self):
        for name in builder.BUILD_OVERRIDES:
            with self.subTest(name=name), patch.dict(os.environ, {name: "custom"}):
                with self.assertRaisesRegex(RuntimeError, "unset " + name):
                    builder.build_inputs("recipe")
        builder.subprocess.check_output.assert_not_called()

    def test_uses_and_records_selected_tools_instead_of_caller_paths(self):
        with patch.dict(os.environ, {"PATH": "/custom/bin", "PKG_CONFIG_PATH": "/custom/pkgconfig"}):
            env, inputs = builder.build_inputs("recipe")
        self.assertEqual(env["CC"], str(self.compiler))
        self.assertEqual(env["OBJC"], str(self.compiler))
        self.assertEqual(env["SDKROOT"], str(self.sdk))
        self.assertEqual(env["PKG_CONFIG"], str(self.pkgconfig))
        self.assertNotIn("/custom", env["PATH"])
        self.assertEqual(env["PKG_CONFIG_PATH"], str(self.alias.resolve() / "lib/pkgconfig"))
        self.assertEqual(inputs["compiler"], self.compiler_version)
        self.assertEqual(inputs["compiler_path"], env["CC"])
        self.assertEqual(inputs["swift_compiler_path"], str(self.swift))
        self.assertEqual(inputs["swift_compiler"], self.swift_version)
        self.assertEqual(inputs["sdk_path"], env["SDKROOT"])
        self.assertEqual(inputs["pkg_config"]["path"], env["PKG_CONFIG"])
        _, ordinary_inputs = builder.build_inputs("recipe")
        self.assertEqual(self.key(inputs), self.key(ordinary_inputs))

    def test_same_upstream_version_with_new_homebrew_revision_changes_key(self):
        _, before = builder.build_inputs("recipe")
        self.alias.unlink()
        self.alias.symlink_to(self.root / "Cellar/example/1.0_2", target_is_directory=True)
        _, after = builder.build_inputs("recipe")
        self.assertEqual(before["dependencies"], after["dependencies"])
        self.assertNotEqual(before["pkg_config_path"], after["pkg_config_path"])
        self.assertNotEqual(before["dependency_files"]["example"]["path"], after["dependency_files"]["example"]["path"])
        self.assertNotEqual(self.key(before), self.key(after))

    def test_changed_pkgconfig_contents_change_key_without_version_change(self):
        _, before = builder.build_inputs("recipe")
        (self.alias / "lib/pkgconfig/example.pc").write_text("Version: 1.0\nCflags: -DCHANGED\n")
        _, after = builder.build_inputs("recipe")
        self.assertEqual(before["dependencies"], after["dependencies"])
        self.assertNotEqual(self.key(before), self.key(after))

    def test_updated_selected_compiler_changes_key(self):
        _, before = builder.build_inputs("recipe")
        self.compiler_version = "Apple clang version 21.0.1"
        _, after = builder.build_inputs("recipe")
        self.assertNotEqual(self.key(before), self.key(after))

    def test_updated_selected_swift_compiler_changes_key(self):
        _, before = builder.build_inputs("recipe")
        self.swift_version = "Apple Swift version 6.5.1"
        _, after = builder.build_inputs("recipe")
        self.assertNotEqual(self.key(before), self.key(after))


if __name__ == "__main__":
    unittest.main()
