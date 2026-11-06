"""Synthetic publishing checks; no GitHub access or signing credentials."""
from pathlib import Path
import base64
import hashlib
import importlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tool"))


def module(name):
    return importlib.import_module(name)


make = module("make_appcast")
publish = module("publish_appcast")
release = module("publish_release")


def feed(build=29, length=123, url=None, short_version="1.0.0-beta.29"):
    url = url or "https://loongpass.com/api/download/v1.0.0-beta.29/LoongPass-macOS-universal.zip"
    return f'''<rss xmlns:sparkle="{make.SPARKLE}"><channel><item>
    <sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
    <enclosure url="{url}" length="{length}" sparkle:edSignature="synthetic-signature"/>
    </item></channel></rss>'''


class PublishingChecks(unittest.TestCase):
    def test_resume_does_not_publish_feed_rejected_by_signature_verifier(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "macos/Runner").mkdir(parents=True)
            (root / "pubspec.yaml").write_text("version: 1.0.0-beta.29+29\n")
            info = {"CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "29",
                    "SUPublicEDKey": "synthetic-public-key", "SURequireSignedFeed": True,
                    "SUVerifyUpdateBeforeExtraction": True,
                    "SUFeedURL": "https://loongpass.com/updates/appcast.xml"}
            (root / "macos/Runner/Info.plist").write_bytes(plistlib.dumps(info))
            output = root / "dist"; output.mkdir()
            archive = output / "LoongPass-macOS-universal.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("LoongPass.app/Contents/Info.plist", plistlib.dumps(info))
            content = archive.read_bytes()
            digest = hashlib.sha256(content).hexdigest()
            (output / "SOURCE_COMMIT").write_text("source-head")
            (output / "appcast.xml").write_text(feed(length=len(content)))
            published = []

            def external(command, **kwargs):
                if command[:2] == ["gh", "api"]:
                    data = {"draft": False, "prerelease": True, "tag_name": "v1.0.0-beta.29",
                            "assets": [{"name": archive.name, "digest": "sha256:" + digest, "size": len(content)}]}
                    return subprocess.CompletedProcess(command, 0, json.dumps(data), "")
                if command[:3] == ["gh", "release", "download"]:
                    saved = Path(command[command.index("--dir") + 1])
                    (saved / "SOURCE_COMMIT").write_text("source-head")
                    (saved / "SHA256SUMS").write_text(digest + "  " + archive.name + "\n")
                    (saved / "appcast.xml").write_text(feed(length=len(content)))
                    (saved / archive.name).write_bytes(content)
                elif Path(command[0]).name == "sign_update":
                    raise subprocess.CalledProcessError(1, command, stderr="Invalid signature")
                elif any(str(part).endswith("publish_appcast.py") for part in command):
                    published.append(command)
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch.object(release, "ROOT", root), patch.object(make, "ROOT", root), \
                    patch.object(sys, "argv", ["publish_release", str(output), "--tools", str(root)]), \
                    patch.dict(make.os.environ, {"SPARKLE_PRIVATE_KEY": "synthetic-key"}), \
                    patch.object(release.subprocess, "check_output", return_value="source-head"), \
                    patch.object(release.subprocess, "run", side_effect=external):
                with self.assertRaises(subprocess.CalledProcessError):
                    release.main()
            self.assertEqual(published, [])

    def test_feed_must_match_exact_source_and_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "LoongPass-macOS-universal.zip"
            archive.write_bytes(b"x" * 123)
            manifest = Path(directory) / "appcast.xml"
            manifest.write_text(feed())
            self.assertEqual(make.verify_feed(manifest, archive, "1.0.0-beta.29", "29"), "synthetic-signature")
            for value in [feed(build=28), feed(short_version="1.0.1"), feed(length=122), feed(url="https://example.invalid/package.zip")]:
                manifest.write_text(value)
                with self.assertRaises(AssertionError):
                    make.verify_feed(manifest, archive, "1.0.0-beta.29", "29")

    def test_prerelease_archive_uses_native_version_without_losing_release_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "macos/Runner").mkdir(parents=True)
            (root / "pubspec.yaml").write_text("version: 1.0.0-beta.29+29\n")
            (root / "RELEASE-NOTES.md").write_text("Synthetic release notes")
            info = {"CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "29",
                    "SUPublicEDKey": "synthetic-public-key", "SURequireSignedFeed": True,
                    "SUVerifyUpdateBeforeExtraction": True,
                    "SUFeedURL": "https://loongpass.com/updates/appcast.xml"}
            (root / "macos/Runner/Info.plist").write_bytes(plistlib.dumps(info))
            output = root / "dist"; output.mkdir()
            archive = output / "LoongPass-macOS-universal.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("LoongPass.app/Contents/Info.plist", plistlib.dumps(info))
            original = archive.read_bytes()

            def sparkle(command, **kwargs):
                if Path(command[0]).name == "generate_appcast":
                    (output / "appcast.xml").write_text(feed(length=len(original), short_version="1.0.0"))

            with patch.object(make, "ROOT", root), patch.object(sys, "argv", ["make_appcast", str(output), "--tools", str(root)]), \
                    patch.dict(make.os.environ, {"SPARKLE_PRIVATE_KEY": "synthetic-key"}), \
                    patch.object(make.subprocess, "run", side_effect=sparkle):
                make.main()
                self.assertEqual(make.verify_feed(output / "appcast.xml", archive, "1.0.0-beta.29", "29"), "synthetic-signature")
            self.assertEqual(archive.read_bytes(), original)
            self.assertFalse(archive.with_suffix(".md").exists())

    def test_publisher_refuses_rollback_and_equal_version(self):
        for build in [29, 30]:
            with tempfile.TemporaryDirectory() as directory:
                manifest = Path(directory) / "appcast.xml"; manifest.write_text(feed())
                with patch.object(sys, "argv", ["publish", str(manifest), "--tools", directory]), patch.object(publish, "api", side_effect=[
                    [{"ref": "refs/heads/updates", "object": {"sha": "old-head"}}],
                    {"content": base64.b64encode(feed(build=build, length=999).encode()).decode()},
                ]) as api:
                    with self.assertRaises(RuntimeError): publish.main()
                    self.assertEqual(api.call_count, 2)

    def publish_fixture(self, content, *, stable=True, same=False):
        calls = []
        previous = content if same else feed(build=28)
        def api(path, data=None, method=None):
            calls.append((path, data, method))
            if path == "/git/matching-refs/heads/updates":
                return [{"ref": "refs/heads/updates", "object": {"sha": "old-head"}}]
            if path.startswith("/contents/appcast.xml?"):
                return {"content": base64.b64encode(previous.encode()).decode()}
            if path == "/git/commits/old-head":
                return {"tree": {"sha": "old-tree"}}
            if path == "/git/trees/old-tree":
                return {"tree": [{"path": "appcast.xml"}] + ([{"path": "appcast-stable.xml"}] if stable else [])}
            if path == "/git/trees": return {"sha": "new-tree"}
            if path == "/git/commits": return {"sha": "new-head"}
            if path == "/git/refs/heads/updates": return {}
            raise AssertionError(path)
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "appcast.xml"; manifest.write_bytes(content.encode())
            with patch.object(sys, "argv", ["publish", str(manifest), "--tools", directory]), \
                    patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": "synthetic-key"}), \
                    patch.object(publish, "api", side_effect=api), \
                    patch.object(publish, "empty_stable_feed", return_value="signed-empty-feed", create=True):
                publish.main()
        return calls

    def test_beta_preserves_existing_stable_feed_and_refuses_concurrent_overwrite(self):
        calls = self.publish_fixture(feed())
        tree = next(data for path, data, _ in calls if path == "/git/trees")
        self.assertEqual(tree["base_tree"], "old-tree")
        self.assertEqual([item["path"] for item in tree["tree"]], ["appcast.xml"])
        commit = next(data for path, data, _ in calls if path == "/git/commits")
        self.assertEqual(commit["parents"], ["old-head"])
        self.assertEqual(calls[-1], ("/git/refs/heads/updates", {"sha": "new-head", "force": False}, "PATCH"))

    def test_first_beta_bootstraps_stable_feed_even_when_inclusive_feed_is_unchanged(self):
        calls = self.publish_fixture(feed(), stable=False, same=True)
        tree = next(data for path, data, _ in calls if path == "/git/trees")
        items = {entry["path"]: entry["content"] for entry in tree["tree"]}
        self.assertEqual(items["appcast-stable.xml"], "signed-empty-feed")

    def test_stable_release_updates_both_channels_with_identical_signed_bytes(self):
        content = feed(short_version="1.0.0").replace("\n", "\r\n")
        calls = self.publish_fixture(content)
        tree = next(data for path, data, _ in calls if path == "/git/trees")
        self.assertEqual({item["path"]: item["content"] for item in tree["tree"]},
                         {"appcast.xml": content, "appcast-stable.xml": content})

    def test_same_signed_bytes_are_idempotent_even_with_crlf(self):
        calls = self.publish_fixture(feed().replace("\n", "\r\n"), same=True)
        self.assertFalse(any(data for _, data, _ in calls))

    def test_empty_feed_must_pass_signature_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            def reject_verification(command, **kwargs):
                if "--verify" in command: raise subprocess.CalledProcessError(1, command)
                return subprocess.CompletedProcess(command, 0)
            with patch.object(publish.subprocess, "run", side_effect=reject_verification) as signer:
                with self.assertRaises(subprocess.CalledProcessError):
                    publish.empty_stable_feed(Path(directory), "synthetic-key")
                self.assertEqual(signer.call_count, 2)


if __name__ == "__main__":
    unittest.main()
