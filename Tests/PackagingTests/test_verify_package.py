"""Packaged tests must use release libraries, never a development prefix."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("verify_package", SCRIPTS / "verify-package.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class PackagedTestIsolationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.staging = self.root / "staging"
        self.frameworks = self.staging / "mpx.app/Contents/Frameworks"
        self.prefix = self.root / "private prefix"
        self.library = self.prefix / "lib/libmpv.2.dylib"
        self.tests = self.root / "tests"
        self.platform = self.root / "Xcode/MacOSX.platform"
        self.xctest = self.platform / "Developer/Library/Xcode/Agents/xctest"
        self.runtime = {
            "@rpath/XCTest.framework/Versions/A/XCTest": self.platform / "Developer/Library/Frameworks/XCTest.framework/Versions/A/XCTest",
            "@rpath/Testing.framework/Versions/A/Testing": self.platform / "Developer/Library/Frameworks/Testing.framework/Versions/A/Testing",
            "@rpath/libXCTestSwiftSupport.dylib": self.platform / "Developer/usr/lib/libXCTestSwiftSupport.dylib",
        }
        self.links = {}
        self.runpaths = {self.xctest: ["@executable_path/../../Frameworks", "@executable_path/../../../usr/lib"]}
        self.commands = []
        self.test_environments = []
        self.output = io.StringIO()
        self.homebrew = "/opt/homebrew/Cellar/example/1.0/lib/libexample.dylib"
        self.integration = self.staging / "PlaybackIntegrationTests.xctest/Contents/MacOS/PlaybackIntegrationTests"
        files = [self.library, *self.runtime.values(), self.frameworks / self.library.name,
                 self.frameworks / "libexample.dylib", self.staging / "mpx.app/Contents/MacOS/mpx-app",
                 self.staging / "mpx.app/Contents/Resources/LICENSE",
                 self.staging / "mpx.app/Contents/Resources/THIRD-PARTY.md"]
        for name in ("PlayerLogicTests", "PlaybackIntegrationTests"):
            files.append(self.tests / (name + ".xctest/Contents/MacOS/" + name))
            self.links[self.staging / (name + ".xctest/Contents/MacOS/" + name)] = [
                "/usr/lib/libSystem.B.dylib", *self.runtime]
            self.runpaths[self.staging / (name + ".xctest/Contents/MacOS/" + name)] = [
                "@loader_path", "@loader_path/../Frameworks"]
        self.links[self.integration] += [str(self.library), self.homebrew]
        for path in files:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        (self.staging / "mpx.app/Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": "mpx-app"}))

        self.enterContext(patch.dict(verifier.os.environ, {"MPX_LIBMPV_PREFIX": str(self.prefix)}))
        self.staging_mock = self.enterContext(patch.object(verifier, "temporary_app_directory"))
        self.staging_mock.return_value.__enter__.return_value = self.staging
        self.prefix_mock = self.enterContext(patch.object(verifier, "verify_prefix", return_value=(self.library, {})))
        self.run_mock = self.enterContext(patch.object(verifier.subprocess, "run", side_effect=self.run_command))
        self.enterContext(patch.object(verifier.subprocess, "check_output", side_effect=self.command_output))
        self.enterContext(patch.object(verifier, "dependencies", side_effect=lambda binary: list(self.links.get(binary, []))))
        self.enterContext(redirect_stdout(self.output))

    def run_command(self, args, **kwargs):
        self.commands.append(args)
        if args[0] == "/usr/bin/sandbox-exec":
            self.test_environments.append(kwargs["env"])
        if args[0] == "install_name_tool":
            _, _, old, new, binary = args
            self.links[Path(binary)] = [new if name == old else name for name in self.links[Path(binary)]]

    def command_output(self, args, **kwargs):
        if args[0] == "lipo":
            return "arm64\n"
        if args == ["xcrun", "--find", "xctest"]:
            return str(self.xctest) + "\n"
        if args == ["xcrun", "--show-sdk-platform-path"]:
            return str(self.platform) + "\n"
        if args[:4] == ["otool", "-arch", "arm64", "-l"]:
            return "\n".join(f"Load command {i}\n          cmd LC_RPATH\n      cmdsize 40\n         path {path} (offset 12)"
                             for i, path in enumerate(self.runpaths[Path(args[4])]))
        self.fail(f"Unexpected command: {args}")

    def verify(self):
        verifier.verify(self.root / "release.zip", self.tests)

    def assert_tests_not_run(self):
        self.assertFalse(any(args[0] == "/usr/bin/sandbox-exec" for args in self.commands))
        self.assertNotIn("All tests passed", self.output.getvalue())

    def test_missing_prefix_fails_before_staging_or_commands(self):
        with patch.dict(verifier.os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "MPX_LIBMPV_PREFIX is required"):
                self.verify()
        self.prefix_mock.assert_not_called()
        self.staging_mock.assert_not_called()
        self.run_mock.assert_not_called()

    def test_invalid_prefix_fails_before_staging_or_commands(self):
        self.prefix_mock.side_effect = RuntimeError("Built libmpv checksum mismatch")
        with self.assertRaisesRegex(RuntimeError, "libmpv checksum mismatch"):
            self.verify()
        self.staging_mock.assert_not_called()
        self.run_mock.assert_not_called()

    def test_relocates_selected_library_and_preserves_verified_xcode_runtime(self):
        with patch.dict(verifier.os.environ, {"DYLD_LIBRARY_PATH": str(self.root), "MPX_EXPECT_AUDIO_OUTPUT": "coreaudio"}):
            self.verify()
        self.prefix_mock.assert_called_once_with(self.prefix)
        self.assertIn(str(self.frameworks / self.library.name), self.links[self.integration])
        self.assertIn(str(self.frameworks / "libexample.dylib"), self.links[self.integration])
        self.assertTrue(set(self.runtime).issubset(self.links[self.integration]))
        self.assertFalse(any(args[0] == "install_name_tool" and args[2] in self.runtime for args in self.commands))
        self.assertNotIn(str(self.library), self.links[self.integration])
        runs = [args for args in self.commands if args[0] == "/usr/bin/sandbox-exec"]
        self.assertEqual(len(runs), 2)
        for args in runs:
            self.assertIn('(deny file-read* (subpath "/opt/homebrew"))', args[2])
            self.assertIn('(deny file-read* (subpath ' + json.dumps(str(self.prefix)) + '))', args[2])
        for environment in self.test_environments:
            self.assertNotIn("DYLD_LIBRARY_PATH", environment)
            self.assertEqual(environment["MPX_EXPECT_AUDIO_OUTPUT"], "coreaudio")
        last_relocation = max(i for i, args in enumerate(self.commands) if args[0] == "install_name_tool")
        first_test = next(i for i, args in enumerate(self.commands) if args[0] == "/usr/bin/sandbox-exec")
        self.assertLess(last_relocation, first_test)

    def test_rejects_unknown_private_link_before_any_tests_run(self):
        unknown = self.root / "other/libprivate.dylib"
        unknown.parent.mkdir()
        unknown.touch()
        self.links[self.integration].append(str(unknown))
        with self.assertRaisesRegex(RuntimeError, "Unresolved/external test dependency"):
            self.verify()
        self.assert_tests_not_run()

    def test_rejects_unknown_rpath_link_before_any_tests_run(self):
        self.links[self.integration].append("@rpath/libprivate.dylib")
        with self.assertRaisesRegex(RuntimeError, "Unresolved/external test dependency"):
            self.verify()
        self.assert_tests_not_run()

    def test_rejects_shadow_xcode_runtime_in_search_path(self):
        shadow_root = self.root / "shadow"
        shadow = shadow_root / "XCTest.framework/Versions/A/XCTest"
        shadow.parent.mkdir(parents=True)
        shadow.touch()
        self.runpaths[self.integration].append(str(shadow_root))
        with self.assertRaisesRegex(RuntimeError, "Unresolved/external Xcode test runtime"):
            self.verify()
        self.assert_tests_not_run()

    def test_rejects_xcode_runtime_missing_from_search_paths(self):
        self.runpaths[self.xctest] = []
        with self.assertRaisesRegex(RuntimeError, "Unresolved/external Xcode test runtime"):
            self.verify()
        self.assert_tests_not_run()

    def test_rechecks_links_after_relocation(self):
        self.run_mock.side_effect = lambda args, **kwargs: self.commands.append(args)
        with self.assertRaisesRegex(RuntimeError, "Unresolved/external test dependency"):
            self.verify()
        self.assert_tests_not_run()

    def test_rejects_release_link_outside_bundled_libraries(self):
        external = self.staging / "mpx.app/Contents/libexternal.dylib"
        external.touch()
        executable = self.staging / "mpx.app/Contents/MacOS/mpx-app"
        self.links[executable] = ["@loader_path/../libexternal.dylib"]
        with self.assertRaisesRegex(RuntimeError, "Unresolved/external release dependency"):
            self.verify()
        self.assert_tests_not_run()


if __name__ == "__main__":
    unittest.main()
