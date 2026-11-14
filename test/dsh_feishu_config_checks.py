"""Exercise profile preparation against isolated native-profile fixtures."""
from pathlib import Path
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tool/configure_dsh_feishu.py"
SPEC = importlib.util.spec_from_file_location("configure_dsh_feishu", TOOL)
CONFIGURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIGURE)


class DshFeishuConfigChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="loongpass-dsh-config-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "dsh"
        self.profile = self.home / "profiles" / "test-feishu"
        self.profile.mkdir(parents=True)
        (self.profile / "package.json").write_text(json.dumps({
            "name": "dsh-profile-test-feishu", "private": True,
            "dependencies": {"dsh-lark-channel": "0.0.7"},
            "dsh": {"profile": {"bundles": ["@deepseek-ai/dsh-base", "dsh-lark-channel"]}},
        }))
        self.patch = self.profile / "cordis.patch.yml"
        self.patch.write_text("# Native profile patch\n[]\n")
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()

    def run_tool(self, *extra, profile="test-feishu", workspace=None, model="magpie/loongpass/model"):
        return subprocess.run([
            sys.executable, "-B", str(TOOL), "--profile", profile,
            "--workspace", str(self.workspace if workspace is None else workspace),
            "--model", model, *extra,
        ], capture_output=True, text=True, env=dict(os.environ, DSH_HOME=str(self.home)))

    def configs(self):
        lines = self.patch.read_text().splitlines()
        owned = lines[lines.index(CONFIGURE.BEGIN):lines.index(CONFIGURE.END)]
        return [json.loads(line.split(":", 1)[1]) for line in owned
                if line.startswith("  config: {")]

    def arguments(self):
        return SimpleNamespace(profile="test-feishu", workspace=str(self.workspace),
                               model="magpie/loongpass/model", app_id=None,
                               workspace_roots=None, sender_allowlist=None,
                               approvers=None, group_allowlist=None)

    def assert_rejected_unchanged(self, result, before):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.patch.read_bytes(), before)
        self.assert_no_temporary_files()

    def assert_no_temporary_files(self):
        self.assertEqual(sorted(path.name for path in self.profile.iterdir()
                                if path.name != ".loongpass-feishu-config.lock"),
                         ["cordis.patch.yml", "package.json"])

    def hold_profile_lock(self):
        script = """
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('configure', sys.argv[1])
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)
with configure.profile_lock(Path(sys.argv[2])):
    print('locked', flush=True)
    sys.stdin.read()
"""
        process = subprocess.Popen([sys.executable, "-B", "-c", script, str(TOOL), str(self.patch)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
        self.addCleanup(cleanup)
        self.assertEqual(process.stdout.readline().strip(), "locked")
        return process

    def test_prepares_native_rows_and_identical_rerun_keeps_file_identity(self):
        result = self.run_tool("--app-id", "cli_synthetic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.configs(), [
            {"defaultEnabled": True},
            {"cwd": str(self.workspace), "workspaceRoots": [str(self.workspace)],
             "provider": "magpie", "model": "loongpass/model", "appId": "cli_synthetic",
             "senderAllowlist": [], "approvers": [], "groupAllowlist": []},
        ])
        before = self.patch.read_bytes(), self.patch.stat().st_ino, self.patch.stat().st_mtime_ns
        result = self.run_tool("--app-id", "cli_synthetic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.patch.read_bytes(), self.patch.stat().st_ino,
                          self.patch.stat().st_mtime_ns), before)

    def test_preserves_foreign_rows_permissions_and_omitted_optional_values(self):
        prefix = ('# Native profile\r\n- id: magpie\r\n  config:\r\n'
                  '    providers: [{id: loongpass, name: "模型"}]\r\n'
                  '- id: custom-plugin\r\n  config: {enabled: true}\r\n').encode()
        suffix = b'- id: another-plugin\r\n  config: {answer: 42}\r\n'
        self.patch.write_bytes(prefix)
        self.patch.chmod(0o640)
        result = self.run_tool("--app-id", "cli_synthetic", "--sender-allowlist", "ou_sender",
                               "--approvers", "ou_approver", "--group-allowlist", "oc_group")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.patch.write_bytes(self.patch.read_bytes() + suffix)
        result = self.run_tool(model="magpie/loongpass/other-model")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.patch.read_bytes().startswith(prefix))
        self.assertTrue(self.patch.read_bytes().endswith(suffix))
        self.assertEqual(self.patch.stat().st_mode & 0o777, 0o640)
        config = self.configs()[1]
        self.assertEqual(config["model"], "loongpass/other-model")
        self.assertEqual(config["appId"], "cli_synthetic")
        self.assertEqual(config["senderAllowlist"], ["ou_sender"])
        self.assertEqual(config["approvers"], ["ou_approver"])
        self.assertEqual(config["groupAllowlist"], ["oc_group"])

    def test_explicit_empty_lists_retain_upstream_empty_list_semantics(self):
        result = self.run_tool("--sender-allowlist", "ou_sender", "--group-allowlist", "oc_group")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_tool("--sender-allowlist", "--group-allowlist", "--workspace-roots")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.configs()[1]["senderAllowlist"], [])
        self.assertEqual(self.configs()[1]["groupAllowlist"], [])
        self.assertEqual(self.configs()[1]["workspaceRoots"], [])

    def test_ignores_ids_and_dynamic_values_inside_unrelated_plugin_config(self):
        original = ('- id: magpie\n  config:\n    models:\n'
                    '      - id: agent-team\n        alias: lark-channel\n'
                    '- id: another\n  config: {id: lark-channel, insert: "!!js example"}\n'
                    '- insert:\n    - id: foreign-plugin\n      config:\n'
                    '        id: agent-team\n        items:\n          - !!js process.env.ITEM\n')
        self.patch.write_text(original)
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.patch.read_text().startswith(original))
        self.assertEqual(self.configs()[0], {"defaultEnabled": True})

    def test_rejects_existing_unowned_target_rows_losslessly(self):
        examples = [
            '- id: agent-team\n  config: {defaultEnabled: false}\n',
            '- id: "lark-channel"\n  config: {appSecret: synthetic-private-value}\n',
            '- {id: agent-team, config: {defaultEnabled: false}}\n',
            '- "id": "agent\\u002dteam"\n  config: {}\n',
            '- insert:\n    - id: lark-channel\n      config: {}\n',
            '- id: !!js process.env.PLUGIN_ID\n  config: {}\n',
            '- id: *plugin\n  config: {}\n',
            '- insert: !!js process.env.PATCH_ENTRIES\n',
            '- insert: *entries\n',
            '- <<: *plugin\n  config: {}\n',
            '- &plugin {id: agent-team}\n',
            '[{id: lark-channel, config: {}}]\n',
        ]
        for content in examples:
            with self.subTest(content=content):
                self.patch.write_text(content)
                before = self.patch.read_bytes()
                result = self.run_tool()
                self.assert_rejected_unchanged(result, before)
                self.assertNotIn("synthetic-private-value", result.stdout + result.stderr)

    def test_refuses_uninitialized_profile_and_profile_path_escape(self):
        before = self.patch.read_bytes()
        for name in ("../test-feishu", "test/feishu", "..", "test\\feishu", "missing", "bad\nname"):
            with self.subTest(name=name):
                self.assert_rejected_unchanged(self.run_tool(profile=name), before)
        self.assertFalse((self.home / "profiles" / "missing").exists())
        package = self.profile / "package.json"
        package.write_text('{"name": "not-a-native-profile"}')
        self.assert_rejected_unchanged(self.run_tool(), before)

    def test_unset_or_empty_dsh_home_uses_the_native_home_default(self):
        (self.root / ".dsh").symlink_to(self.home, target_is_directory=True)
        for environment in ({}, {"DSH_HOME": ""}):
            with self.subTest(environment=environment), \
                    patch.dict(os.environ, environment, clear=True), \
                    patch.object(CONFIGURE.Path, "home", return_value=self.root):
                self.assertEqual(CONFIGURE.profile_patch("test-feishu").resolve(), self.patch)

    def test_refuses_non_native_yaml_layout_without_reformatting(self):
        for content in ('  - id: other\n    config: {}\n',
                        '---\n  - id: other\n    config: {}\n',
                        '- id: other\n---\n- id: another\n',
                        '[]\n- id: other\n'):
            with self.subTest(content=content):
                self.patch.write_text(content)
                before = self.patch.read_bytes()
                self.assert_rejected_unchanged(self.run_tool(), before)

    def test_requires_existing_directory_and_explicit_provider_model(self):
        before = self.patch.read_bytes()
        for workspace in (self.root / "missing", self.profile / "package.json"):
            self.assert_rejected_unchanged(self.run_tool(workspace=workspace), before)
        for model in ("model", "/model", "provider/", "provider/\n- id: other", "provider/\x7fmodel"):
            self.assert_rejected_unchanged(self.run_tool(model=model), before)

    def test_serializes_path_and_value_characters_without_yaml_injection(self):
        workspace = self.root / 'project "quoted"\n- id: lark-channel # 演示'
        workspace.mkdir()
        model = 'provider/model" # {config: false}'
        result = self.run_tool(workspace=workspace, model=model)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.configs()[1]
        self.assertEqual(config["cwd"], str(workspace))
        self.assertEqual(config["workspaceRoots"], [str(workspace)])
        self.assertEqual(config["model"], model.partition("/")[2])
        self.assertEqual(sum(line.startswith("- ") for line in self.patch.read_text().splitlines()), 2)
        before = self.patch.read_bytes()
        self.assertEqual(self.run_tool(workspace=workspace, model=model).returncode, 0)
        self.assertEqual(self.patch.read_bytes(), before)

    def test_rejects_non_exact_ids_and_never_echoes_unknown_secret_arguments(self):
        before = self.patch.read_bytes()
        for option, value in (("--sender-allowlist", "ou_one,ou_two"),
                              ("--approvers", "*"), ("--group-allowlist", "ou_user"),
                              ("--app-id", "cli_value\n- id: other"),
                              ("--app-secret", "synthetic-private-value")):
            result = self.run_tool(option, value)
            self.assert_rejected_unchanged(result, before)
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_refuses_corrupted_or_customized_owned_blocks(self):
        self.assertEqual(self.run_tool().returncode, 0)
        original = self.patch.read_text()
        variants = [
            original + original,
            original.replace(CONFIGURE.END, ""),
            original.replace('"defaultEnabled": true', '"defaultEnabled": false'),
            original.replace('"senderAllowlist": []', '"appSecret": "synthetic-private-value", "senderAllowlist": []'),
            original + "  disabled: true\n",
        ]
        for content in variants:
            with self.subTest(content=content):
                self.patch.write_text(content)
                before = self.patch.read_bytes()
                result = self.run_tool()
                self.assert_rejected_unchanged(result, before)
                self.assertNotIn("synthetic-private-value", result.stdout + result.stderr)

    def test_does_not_follow_symlinked_patch_or_profile(self):
        elsewhere = self.root / "elsewhere.yml"
        before = self.patch.read_bytes()
        self.patch.rename(elsewhere)
        self.patch.symlink_to(elsewhere)
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertTrue(self.patch.is_symlink())
        self.assertEqual(elsewhere.read_bytes(), before)
        alias = self.home / "profiles" / "alias"
        alias.symlink_to(self.profile, target_is_directory=True)
        self.assertNotEqual(self.run_tool(profile="alias").returncode, 0)
        self.assertEqual(elsewhere.read_bytes(), before)

    def test_atomic_write_failure_keeps_original_and_cleans_temporary_files(self):
        before = self.patch.read_bytes()
        with patch.dict(os.environ, {"DSH_HOME": str(self.home)}), \
                patch.object(CONFIGURE.os, "replace", side_effect=OSError("simulated write failure")):
            with self.assertRaises(OSError):
                CONFIGURE.configure(self.arguments())
        self.assertEqual(self.patch.read_bytes(), before)
        self.assert_no_temporary_files()

    def test_detects_native_edit_before_atomic_replace(self):
        native_update = b"- id: native-plugin\n  config: {enabled: true}\n"
        with patch.dict(os.environ, {"DSH_HOME": str(self.home)}), \
                patch.object(CONFIGURE.os, "fsync", side_effect=lambda _: self.patch.write_bytes(native_update)):
            with self.assertRaisesRegex(ValueError, "changed during configuration"):
                CONFIGURE.configure(self.arguments())
        self.assertEqual(self.patch.read_bytes(), native_update)
        self.assert_no_temporary_files()

    def test_concurrent_tool_writer_is_rejected_without_removing_its_lock(self):
        holder = self.hold_profile_lock()
        lock = self.profile / ".loongpass-feishu-config.lock"
        inode = lock.stat().st_ino
        before = self.patch.read_bytes()
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertEqual(self.patch.read_bytes(), before)
        self.assertEqual(lock.stat().st_ino, inode)
        self.assertIsNone(holder.poll())
        holder.communicate(timeout=5)

    def test_abrupt_process_exit_releases_profile_lock_for_retry(self):
        holder = self.hold_profile_lock()
        holder.kill()
        holder.communicate(timeout=5)
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.configs()[0], {"defaultEnabled": True})
        self.assert_no_temporary_files()


if __name__ == "__main__":
    unittest.main()
