#!/usr/bin/env python3
"""Publish the verified release feed to an isolated public metadata branch."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPO = "repos/SailingLoong/LoongPass"
VERSION = ".//{http://www.andymatuschak.org/xml-namespaces/sparkle}version"


def api(path, data=None, method=None):
    command = ["gh", "api", REPO + path]
    if method:
        command.extend(["--method", method])
    if data is not None:
        command.extend(["--input", "-"])
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError("GitHub metadata request failed")
    return json.loads(result.stdout)


def empty_stable_feed(tools, key):
    assert key, "A signing key is required to initialize the stable feed"
    with tempfile.TemporaryDirectory(prefix="loongpass-stable-feed-") as directory:
        feed = Path(directory) / "appcast-stable.xml"
        feed.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
                        '<rss version="2.0"><channel><title>LoongPass</title>'
                        '<link>https://loongpass.com</link>'
                        '<description>Stable macOS updates</description></channel></rss>\n')
        for options in [[], ["--verify"]]:
            subprocess.run([str(tools / "sign_update"), "--ed-key-file", "-", *options, str(feed)],
                           input=key, text=True, check=True)
        return feed.read_bytes().decode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed", type=Path)
    parser.add_argument("--windows-feed", type=Path)
    parser.add_argument("--tools", type=Path, required=True)
    args = parser.parse_args()
    key = os.environ.pop("SPARKLE_PRIVATE_KEY", "").strip()
    incoming = {"appcast.xml": args.feed}
    if args.windows_feed:
        incoming["appcast-windows.xml"] = args.windows_feed
    refs = api("/git/matching-refs/heads/updates")
    old = next((ref["object"]["sha"] for ref in refs if ref["ref"] == "refs/heads/updates"), None)
    base_tree = None
    existing = set()
    if old:
        base_tree = api("/git/commits/" + old)["tree"]["sha"]
        existing = {entry["path"] for entry in api("/git/trees/" + base_tree)["tree"]}
    entries = []
    builds = []
    for filename, path in incoming.items():
        # The signature covers exact UTF-8 bytes, including original line endings.
        content = path.read_bytes().decode("utf-8")
        root = ET.fromstring(content)
        version = int(root.findtext(VERSION))
        release_name = root.findtext(VERSION.replace("version", "shortVersionString"))
        assert release_name, "Missing release version"
        beta = "-" in release_name
        stable_name = filename.replace(".xml", "-stable.xml")
        has_stable = stable_name in existing
        if filename in existing:
            previous = api("/contents/" + filename + "?ref=" + old)
            old_content = base64.b64decode(previous["content"]).decode("utf-8")
            old_version = int(ET.fromstring(old_content).findtext(VERSION))
            if old_content != content and old_version >= version:
                raise RuntimeError("Refusing to replace an equal or newer update feed")
            if old_content == content and has_stable:
                continue
        entries.append({"path": filename, "mode": "100644", "type": "blob", "content": content})
        if not beta or not has_stable:
            stable = empty_stable_feed(args.tools, key) if beta else content
            entries.append({"path": stable_name, "mode": "100644", "type": "blob", "content": stable})
        builds.append(str(version))
    if not entries:
        print("Signed update feeds are already published:", old)
        return
    tree_data = {"tree": entries}
    if base_tree:
        tree_data["base_tree"] = base_tree
    tree = api("/git/trees", tree_data)
    commit = api("/git/commits", {"message": "Publish signed desktop update " + ", ".join(builds),
                                "tree": tree["sha"], "parents": [old] if old else []})
    if old:
        # A non-force update rejects a concurrent publication of either platform.
        api("/git/refs/heads/updates", {"sha": commit["sha"], "force": False}, method="PATCH")
    else:
        api("/git/refs", {"ref": "refs/heads/updates", "sha": commit["sha"]})
    print("Published signed update feeds:", commit["sha"])


if __name__ == "__main__":
    main()
