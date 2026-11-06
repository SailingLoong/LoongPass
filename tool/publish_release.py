#!/usr/bin/env python3
"""Publish once; safely resume feed delivery after a completed release upload."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from make_appcast import ROOT, SPARKLE, download_prefix
from release_version import read_release_version

REPO = "SailingLoong/LoongPass"


def main():
    directory = Path(sys.argv[1]).resolve()
    version, build = read_release_version(ROOT)
    tag = "v" + version
    source = (directory / "SOURCE_COMMIT").read_text().strip()
    assert source == subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    existing = subprocess.run(["gh", "api", f"repos/{REPO}/releases/tags/{tag}"], capture_output=True, text=True)
    if existing.returncode:
        if "HTTP 404" not in existing.stderr:
            raise RuntimeError("Cannot inspect existing release")
        subprocess.run(["gh", "release", "create", tag, "--repo", REPO, "--verify-tag", "--prerelease",
                        "--title", "LoongPass " + tag, "--notes-file", str(ROOT / "RELEASE-NOTES.md"),
                        *[str(p) for p in sorted(directory.iterdir()) if p.is_file()]], check=True)
    else:
        release = json.loads(existing.stdout)
        assert not release["draft"] and release["prerelease"] and release["tag_name"] == tag
        assets = {a["name"]: a for a in release["assets"]}
        archive = assets["LoongPass-macOS-universal.zip"]
        with tempfile.TemporaryDirectory(prefix="loongpass-release-resume-") as scratch:
            subprocess.run(["gh", "release", "download", tag, "--repo", REPO, "--dir", scratch,
                            "--pattern", "SOURCE_COMMIT", "--pattern", "SHA256SUMS", "--pattern", "appcast.xml"], check=True)
            saved = Path(scratch)
            assert (saved / "SOURCE_COMMIT").read_text().strip() == source, "Existing release has different source"
            sha = (saved / "SHA256SUMS").read_text().split()[0]
            assert archive["digest"] == "sha256:" + sha, "Existing release archive does not match its checksum"
            feed = (saved / "appcast.xml").read_bytes()
            item = ET.fromstring(feed).find("./channel/item")
            assert item.findtext("{" + SPARKLE + "}version") == build
            enclosure = item.find("enclosure")
            assert int(enclosure.get("length")) == archive["size"]
            assert enclosure.get("url") == download_prefix(version) + archive["name"]
            # Reuse the already-published, signed feed. Rebuilding the same source
            # can produce different ZIP bytes; never overwrite existing assets.
            (directory / "appcast.xml").write_bytes(feed)
        print("Reused verified existing release", tag)
    subprocess.run([sys.executable, str(ROOT / "tool/publish_appcast.py"), str(directory / "appcast.xml")], check=True)


if __name__ == "__main__":
    main()
