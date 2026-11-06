#!/usr/bin/env python3
"""Generate and verify a signed Sparkle feed using the source-pinned SDK tools."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from urllib.parse import urlsplit
from release_version import ReleaseVersion, read_release_version

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "https://github.com/SailingLoong/LoongPass"


def download_prefix(version):
    info = plistlib.loads((ROOT / "macos/Runner/Info.plist").read_bytes())
    feed = urlsplit(info["SUFeedURL"])
    assert feed.scheme == "https" and feed.hostname and not feed.username and not feed.password
    return f"{feed.scheme}://{feed.netloc}/api/download/v{version}/"


def verify_feed(path, archive, version, build):
    items = ET.parse(path).getroot().findall("./channel/item")
    assert len(items) == 1, "Expected one source-matched update"
    item = items[0]
    assert item.findtext("{" + SPARKLE + "}version") == build
    assert item.findtext("{" + SPARKLE + "}shortVersionString") == version
    enclosure = item.find("enclosure")
    assert enclosure is not None
    assert enclosure.get("url") == download_prefix(version) + archive.name
    assert int(enclosure.get("length")) == archive.stat().st_size
    assert enclosure.get("{" + SPARKLE + "}edSignature"), "Unsigned package"
    return enclosure.get("{" + SPARKLE + "}edSignature")


def verify_archive(archive, version, build):
    with zipfile.ZipFile(archive) as zipped:
        info = plistlib.loads(zipped.read("LoongPass.app/Contents/Info.plist"))
    expected = plistlib.loads((ROOT / "macos/Runner/Info.plist").read_bytes())
    assert info["CFBundleVersion"] == build
    assert info["CFBundleShortVersionString"] == ReleaseVersion(version, build).macos_name
    assert info["SUPublicEDKey"] == expected["SUPublicEDKey"]
    assert info["SURequireSignedFeed"] and info["SUVerifyUpdateBeforeExtraction"]


def verify_signatures(tools, feed, archive, signature, key):
    for file, extra in [(feed, []), (archive, [signature])]:
        subprocess.run([str(tools / "sign_update"), "--ed-key-file", "-", "--verify", str(file), *extra],
                       input=key, text=True, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--tools", type=Path)
    args = parser.parse_args()
    tools = args.tools or next(ROOT.glob("build/macos/SourcePackages/artifacts/**/bin/generate_appcast")).parent
    release = read_release_version(ROOT)
    version, build = release
    archive = args.directory.resolve() / "LoongPass-macOS-universal.zip"
    verify_archive(archive, version, build)
    key = os.environ.pop("SPARKLE_PRIVATE_KEY").strip()
    assert key, "Publishing key is required"
    notes = archive.with_suffix(".md")
    notes.write_text((ROOT / "RELEASE-NOTES.md").read_text())
    feed = archive.parent / "appcast.xml"
    subprocess.run([str(tools / "generate_appcast"), "--ed-key-file", "-",
                    "--maximum-deltas", "0", "--versions", build,
                    "--download-url-prefix", download_prefix(version),
                    "--embed-release-notes", "--link", f"{REPOSITORY}/releases/tag/v{version}",
                    "-o", str(feed), str(archive.parent)], input=key, text=True, check=True)
    # Apple requires a numeric bundle version; the signed display version retains
    # the prerelease suffix so the native channel policy can identify beta items.
    ET.register_namespace("sparkle", SPARKLE)
    tree = ET.parse(feed)
    tree.find("./channel/item/{" + SPARKLE + "}shortVersionString").text = version
    tree.write(feed, encoding="utf-8", xml_declaration=True)
    subprocess.run([str(tools / "sign_update"), "--ed-key-file", "-", str(feed)],
                   input=key, text=True, check=True)
    signature = verify_feed(feed, archive, version, build)
    verify_signatures(tools, feed, archive, signature, key)
    notes.unlink()  # Embedded notes are covered by the feed signature.
    print("Verified signed feed and source-matched update archive")


if __name__ == "__main__":
    main()
