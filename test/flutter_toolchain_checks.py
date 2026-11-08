"""Check the release SDK gate with advisory-derived boundary versions."""
from pathlib import Path
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool"))

from verify_flutter import verify_toolchain
from make_windows_appcast import verify_windows_bundle


def metadata(flutter, dart, channel="stable"):
    return {"frameworkVersion": flutter, "dartSdkVersion": dart, "channel": channel}


class FlutterToolchainChecks(unittest.TestCase):
    def test_vulnerable_sdks_and_mixed_cached_versions_are_refused(self):
        for flutter, dart in [("3.47.1", "3.13.1"), ("3.47.7", "3.13.6"),
                              ("3.47.8", "3.13.1"), ("3.47.1", "3.13.7")]:
            with self.subTest(flutter=flutter, dart=dart), self.assertRaises(ValueError):
                verify_toolchain(metadata(flutter, dart), ROOT)

    def test_patched_and_newer_stable_versions_are_allowed(self):
        for flutter, dart in [("3.47.8", "3.13.7"), ("3.47.9", "3.13.7"),
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
