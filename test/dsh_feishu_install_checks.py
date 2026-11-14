"""Check native patch installation, verification and repeatable recovery."""

from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("install_dsh_feishu", ROOT / "tool/install_dsh_feishu.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


class DshFeishuInstallChecks(unittest.TestCase):
    def test_native_patch_flow_is_repeatable_and_keeps_patch_directory_relative(self):
        with tempfile.TemporaryDirectory(prefix="loongpass-install-check-") as temporary:
            root = Path(temporary)
            integration = root / "integration"
            integration.mkdir()
            patch_file = integration / "dsh-lark-channel.patch"
            patch_file.write_text("diff --git a/index.js b/index.js\n--- a/index.js\n+++ b/index.js\n"
                                  "@@ -1 +1 @@\n-before\n+after\n")
            manifest = {
                "package": "dsh-lark-channel", "version": "0.0.7",
                "patchSha256": hashlib.sha256(patch_file.read_bytes()).hexdigest(),
                "originalFiles": {"index.js": hashlib.sha256(b"before\n").hexdigest()},
                "patchedFiles": {"index.js": hashlib.sha256(b"after\n").hexdigest()},
            }
            (integration / "upstream.json").write_text(json.dumps(manifest))
            home = root / "home"
            profile = home / "profiles" / "feishu-test"
            installed = profile / "node_modules" / "dsh-lark-channel"
            calls = []

            def native_command(dsh, name, *arguments):
                calls.append(arguments)
                self.assertEqual((dsh, name), ("synthetic-dsh", "feishu-test"))
                if arguments[0] == "add":
                    (profile / "package.json").write_text(json.dumps({
                        "dependencies": {"dsh-lark-channel": "0.0.7"},
                    }))
                elif arguments[0] == "patch":
                    editable = Path(arguments[arguments.index("--edit-dir") + 1])
                    editable.mkdir()
                    (editable / "index.js").write_text("before\n")
                elif arguments[0] == "patch-commit":
                    self.assertEqual(arguments[1:3], ("--patches-dir", "patches"))
                    shutil.copytree(Path(arguments[-1]), installed, dirs_exist_ok=True)
                else:
                    self.fail(f"Unexpected native command {arguments[0]}")

            with patch.dict(os.environ, {"DSH_HOME": str(home)}), \
                    patch.object(INSTALL, "INTEGRATION", integration), \
                    patch.object(INSTALL, "run", side_effect=native_command), \
                    redirect_stdout(io.StringIO()):
                INSTALL.install("synthetic-dsh", "feishu-test")
                policy = (profile / "pnpm-workspace.yaml").read_bytes()
                INSTALL.install("synthetic-dsh", "feishu-test")
            self.assertEqual((installed / "index.js").read_text(), "after\n")
            self.assertEqual((profile / "pnpm-workspace.yaml").read_bytes(), policy)
            self.assertEqual([call[0] for call in calls], ["add", "patch", "patch-commit"] * 2)
            self.assertTrue(all(not Path(call[-1]).exists() for call in calls if call[0] == "patch-commit"))

    def test_content_mismatch_and_conflicting_version_fail_without_native_mutation(self):
        with tempfile.TemporaryDirectory(prefix="loongpass-install-check-") as temporary:
            root = Path(temporary)
            (root / "file").write_text("unexpected")
            with self.assertRaisesRegex(ValueError, "Unexpected upstream content"):
                INSTALL.verify_files(root, {"file": "0" * 64})
            profile = root / "profiles" / "existing"
            profile.mkdir(parents=True)
            package = profile / "package.json"
            package.write_text('{"dependencies":{"dsh-lark-channel":"0.0.8"}}')
            original = package.read_bytes()
            with patch.dict(os.environ, {"DSH_HOME": str(root)}), patch.object(INSTALL, "run") as native:
                with self.assertRaisesRegex(ValueError, "another channel version"):
                    INSTALL.install("synthetic-dsh", "existing")
                native.assert_not_called()
            self.assertEqual(package.read_bytes(), original)
            self.assertFalse((profile / "pnpm-workspace.yaml").exists())

    def test_public_patch_manifest_matches_its_source(self):
        manifest = json.loads((INSTALL.INTEGRATION / "upstream.json").read_text())
        self.assertTrue(manifest["originalFiles"])
        self.assertEqual(manifest["originalFiles"].keys(), manifest["patchedFiles"].keys())
        INSTALL.verify_files(INSTALL.INTEGRATION, {"dsh-lark-channel.patch": manifest["patchSha256"]})

    def test_empty_home_uses_native_default_for_existing_profile_checks(self):
        with tempfile.TemporaryDirectory(prefix="loongpass-install-check-") as temporary:
            home = Path(temporary)
            profile = home / ".dsh/profiles/existing"
            profile.mkdir(parents=True)
            package = profile / "package.json"
            package.write_text('{"dependencies":{"dsh-lark-channel":"0.0.8"}}')
            with patch.dict(os.environ, {"DSH_HOME": ""}), \
                    patch.object(INSTALL.Path, "home", return_value=home), \
                    patch.object(INSTALL, "run") as native:
                with self.assertRaisesRegex(ValueError, "another channel version"):
                    INSTALL.install("synthetic-dsh", "existing")
                native.assert_not_called()
            self.assertFalse((profile / "pnpm-workspace.yaml").exists())


if __name__ == "__main__":
    unittest.main()
