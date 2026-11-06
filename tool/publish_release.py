#!/usr/bin/env python3
"""Publish once; safely resume feed delivery after a completed release upload."""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

from make_appcast import ROOT, verify_archive, verify_feed, verify_signatures
from release_version import read_release_version
from make_windows_appcast import INSTALLER, PORTABLE, verify_windows_bundle, verify_windows_feed, verify_portable

REPO = "SailingLoong/LoongPass"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--windows-directory", type=Path, required=True)
    args = parser.parse_args()
    directory = args.directory.resolve()
    key = os.environ.pop("SPARKLE_PRIVATE_KEY").strip()
    assert key, "Publishing verification key is required"
    version, build = read_release_version(ROOT)
    prerelease = "-" in version
    tag = "v" + version
    source = (directory / "SOURCE_COMMIT").read_text().strip()
    assert source == subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    existing = subprocess.run(["gh", "api", f"repos/{REPO}/releases/tags/{tag}"], capture_output=True, text=True)
    if existing.returncode:
        if "HTTP 404" not in existing.stderr:
            raise RuntimeError("Cannot inspect existing release")
        archive = directory / "LoongPass-macOS-universal.zip"
        verify_archive(archive, version, build)
        signature = verify_feed(directory / "appcast.xml", archive, version, build)
        verify_signatures(args.tools, directory / "appcast.xml", archive, signature, key)
        windows = args.windows_directory.resolve()
        verify_windows_bundle(windows, version, build, source)
        windows_signature = verify_windows_feed(windows / "appcast-windows.xml", windows / INSTALLER, version, build)
        verify_signatures(args.tools, windows / "appcast-windows.xml", windows / INSTALLER, windows_signature, key)
        for name in [INSTALLER, PORTABLE, "appcast-windows.xml"]:
            shutil.copy2(windows / name, directory / name)
        for name in ["WINSPARKLE-LICENSE.txt", "WEBVIEW2-LICENSE.txt", "NLOHMANN-LICENSE.txt"]:
            shutil.copy2(ROOT / name, directory / name)
        checksums = []
        for name in [archive.name, INSTALLER, PORTABLE]:
            checksums.append(hashlib.sha256((directory / name).read_bytes()).hexdigest() + "  " + name)
        (directory / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
        subprocess.run(["gh", "release", "create", tag, "--repo", REPO, "--verify-tag", *(["--prerelease"] if prerelease else ["--latest"]),
                        "--title", "LoongPass " + tag, "--notes-file", str(ROOT / "RELEASE-NOTES.md"),
                        *[str(p) for p in sorted(directory.iterdir()) if p.is_file()]], check=True)
    else:
        release = json.loads(existing.stdout)
        assert not release["draft"] and release["prerelease"] == prerelease and release["tag_name"] == tag
        assets = {a["name"]: a for a in release["assets"]}
        archive = assets["LoongPass-macOS-universal.zip"]
        with tempfile.TemporaryDirectory(prefix="loongpass-release-resume-") as scratch:
            subprocess.run(["gh", "release", "download", tag, "--repo", REPO, "--dir", scratch,
                            "--pattern", "SOURCE_COMMIT", "--pattern", "SHA256SUMS", "--pattern", "appcast.xml",
                            "--pattern", "LoongPass-macOS-universal.zip", "--pattern", INSTALLER,
                            "--pattern", PORTABLE, "--pattern", "appcast-windows.xml"], check=True)
            saved = Path(scratch)
            assert (saved / "SOURCE_COMMIT").read_text().strip() == source, "Existing release has different source"
            sha = (saved / "SHA256SUMS").read_text().split()[0]
            assert archive["digest"] == "sha256:" + sha, "Existing release archive does not match its checksum"
            published_archive = saved / archive["name"]
            assert hashlib.sha256(published_archive.read_bytes()).hexdigest() == sha
            assert published_archive.stat().st_size == archive["size"]
            verify_archive(published_archive, version, build)
            signature = verify_feed(saved / "appcast.xml", published_archive, version, build)
            verify_signatures(args.tools, saved / "appcast.xml", published_archive, signature, key)
            checksums = {}
            for line in (saved / "SHA256SUMS").read_text().splitlines():
                digest, filename = line.split("  ", 1)
                checksums[Path(filename).name] = digest
            for name in [INSTALLER, PORTABLE]:
                published = saved / name
                digest = hashlib.sha256(published.read_bytes()).hexdigest()
                assert assets[name]["digest"] == "sha256:" + digest and checksums[name] == digest
                assert published.stat().st_size == assets[name]["size"]
            verify_portable(saved / PORTABLE, version, build)
            windows_signature = verify_windows_feed(saved / "appcast-windows.xml", saved / INSTALLER, version, build)
            verify_signatures(args.tools, saved / "appcast-windows.xml", saved / INSTALLER, windows_signature, key)
            (directory / "appcast-windows.xml").write_bytes((saved / "appcast-windows.xml").read_bytes())
            feed = (saved / "appcast.xml").read_bytes()
            # Reuse the already-published, signed feed. Rebuilding the same source
            # can produce different ZIP bytes; never overwrite existing assets.
            (directory / "appcast.xml").write_bytes(feed)
        print("Reused verified existing release", tag)
    subprocess.run([sys.executable, str(ROOT / "tool/publish_appcast.py"), str(directory / "appcast.xml"),
                    "--tools", str(args.tools), "--windows-feed", str(directory / "appcast-windows.xml")], check=True, env={**os.environ, "SPARKLE_PRIVATE_KEY": key})


if __name__ == "__main__":
    main()
