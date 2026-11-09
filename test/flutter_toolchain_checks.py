"""Check the release SDK gate with advisory-derived boundary versions."""
from pathlib import Path
from contextlib import redirect_stdout
from io import StringIO
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool"))

from verify_flutter import verify_toolchain
import verify_flutter
from make_windows_appcast import verify_windows_bundle


def metadata(flutter, dart, channel="stable"):
    return {"frameworkVersion": flutter, "dartSdkVersion": dart, "channel": channel}


class FlutterToolchainChecks(unittest.TestCase):
    def test_ci_reads_pinned_version_without_an_installed_sdk(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pubspec.yaml").write_text(
                "environment:\n  sdk: '>=3.14.0 <4.0.0'\n  flutter: '3.50.2'\n")
            output = StringIO()
            with patch.object(verify_flutter, "ROOT", root), \
                    patch.object(sys, "argv", ["verify_flutter.py", "--required-version"]), \
                    patch.object(verify_flutter.subprocess, "run") as run, \
                    patch.object(verify_flutter.subprocess, "check_output") as check_output, \
                    redirect_stdout(output):
                verify_flutter.main()
            self.assertEqual(output.getvalue(), "3.50.2\n")
            run.assert_not_called()
            check_output.assert_not_called()

    def test_fresh_windows_sdk_bootstrap_finishes_before_machine_output_is_read(self):
        ready = False

        def initialize(command, **kwargs):
            nonlocal ready
            if command != ["synthetic-flutter", "--version"]:
                raise AssertionError("Unexpected SDK initialization")
            ready = True
            return subprocess.CompletedProcess(command, 0)

        def machine_output(command, **kwargs):
            data = json.dumps(metadata("3.47.9", "3.13.7"))
            return data if ready else "Resolving dependencies...\nGot dependencies!\n" + data

        output = StringIO()
        with patch.dict(os.environ, FLUTTER_BIN="synthetic-flutter"), \
                patch.object(sys, "argv", ["verify_flutter.py"]), \
                patch.object(verify_flutter.subprocess, "run", side_effect=initialize), \
                patch.object(verify_flutter.subprocess, "check_output", side_effect=machine_output), \
                redirect_stdout(output):
            verify_flutter.main()
        self.assertIn("3.47.9 / Dart 3.13.7", output.getvalue())

    def test_vulnerable_sdks_and_mixed_cached_versions_are_refused(self):
        for flutter, dart in [("3.47.1", "3.13.1"), ("3.47.7", "3.13.6"),
                              ("3.47.8", "3.13.1"), ("3.47.1", "3.13.7")]:
            with self.subTest(flutter=flutter, dart=dart), self.assertRaises(ValueError):
                verify_toolchain(metadata(flutter, dart), ROOT)

    def test_patched_and_newer_stable_versions_are_allowed(self):
        for flutter, dart in [("3.47.9", "3.13.7"),
                              ("3.50.0", "3.14.0"), ("3.100.0", "3.100.0")]:
            with self.subTest(flutter=flutter, dart=dart):
                verify_toolchain(metadata(flutter, dart), ROOT)

    def test_prerelease_and_unusable_evidence_are_refused(self):
        invalid = [{}, metadata("3.50.0-0.1.pre", "3.14.0-315.1.beta", "beta"),
                   metadata("3.47.8", "3.13.7", "master"),
                   metadata("3.47.8", "3.13.7-1.0.dev"),
                   metadata("unknown", "3.13.7"), metadata("3.47.8", "4.0.0")]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                verify_toolchain(value, ROOT)

    def test_publishing_refuses_missing_or_vulnerable_toolchain_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for value in [None, metadata("3.47.1", "3.13.1")]:
                (root / "WINDOWS-BUILD.json").write_text(json.dumps({"flutterToolchain": value}))
                with self.subTest(value=value), self.assertRaises(ValueError):
                    verify_windows_bundle(root, "1.0.1", "32", "synthetic-source")


if __name__ == "__main__":
    unittest.main()
