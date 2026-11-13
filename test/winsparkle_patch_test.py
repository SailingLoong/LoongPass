"""Check the patch against a local pinned upstream tree, without building Windows.

Usage: python test/winsparkle_patch_test.py --source PATH
The tree is read-only; each check uses an automatically removed temporary copy.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PATCH = Path(__file__).resolve().parents[1] / "tool/patch_winsparkle.py"
FILES = ("src/ui.cpp", "src/dll_api.cpp", "include/winsparkle.h", "src/updatedownloader.cpp")
SOURCE = None


class PatchChecks(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="loongpass-sdk-check-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for name in FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / name, target)

    def run_patch(self):
        return subprocess.run([sys.executable, str(PATCH), str(self.root)],
                              capture_output=True, text=True)

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()}

    def test_applies_once_and_repeated_execution_preserves_bytes(self):
        original = self.snapshot()
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        patched = self.snapshot()
        self.assertTrue(all(patched[name] != original[name] for name in FILES))
        api = patched["src/dll_api.cpp"].decode()
        self.assertIn("win_sparkle_check_update_inline", api)
        self.assertIn("InlineCheck(manual != 0)", api)
        self.assertNotIn("AutomaticInstallUpdateChecker", api)
        self.assertIn("if (InlineAvailable(info)) return;", patched["src/ui.cpp"].decode())
        self.assertTrue((self.root / "src/inline_ui.cpp.inc").is_file())
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), patched)

    def test_drift_is_rejected_before_any_file_changes(self):
        path = self.root / FILES[-1]
        path.write_bytes(path.read_bytes() + b"\n// unexpected drift\n")
        before = self.snapshot()
        self.assertNotEqual(self.run_patch().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_partial_patch_is_rejected_without_repairing_other_files(self):
        original = self.snapshot()
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / FILES[-1]).write_bytes(original[FILES[-1]])
        before = self.snapshot()
        self.assertNotEqual(self.run_patch().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_changed_bridge_addition_is_rejected_without_touching_sources(self):
        self.assertEqual(self.run_patch().returncode, 0)
        path = self.root / "src/inline_ui.cpp.inc"
        path.write_bytes(path.read_bytes() + b"\n// unexpected drift\n")
        before = self.snapshot()
        self.assertNotEqual(self.run_patch().returncode, 0)
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    SOURCE = args.source
    unittest.main(argv=[sys.argv[0]])
