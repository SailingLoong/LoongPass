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
    parser.add_argument("--tools", type=Path, required=True)
    args = parser.parse_args()
    key = os.environ.pop("SPARKLE_PRIVATE_KEY", "").strip()
    # Preserve line endings: the signature covers the feed's exact bytes.
    content = args.feed.read_bytes().decode("utf-8")
    root = ET.fromstring(content)
    version = int(root.findtext(VERSION))
    release_name = root.findtext(VERSION.replace("version", "shortVersionString"))
    assert release_name, "Missing release version"
    beta = "-" in release_name
    refs = api("/git/matching-refs/heads/updates")
    old = next((ref["object"]["sha"] for ref in refs if ref["ref"] == "refs/heads/updates"), None)
    base_tree = None
    has_stable = False
    if old:
        previous = api("/contents/appcast.xml?ref=" + old)
        old_content = base64.b64decode(previous["content"]).decode()
        old_version = int(ET.fromstring(old_content).findtext(VERSION))
        if old_content != content and old_version >= version:
            raise RuntimeError("Refusing to replace an equal or newer update feed")
        base_tree = api("/git/commits/" + old)["tree"]["sha"]
        has_stable = any(entry["path"] == "appcast-stable.xml"
                         for entry in api("/git/trees/" + base_tree)["tree"])
        if old_content == content and has_stable:
            print("Signed update feeds are already published:", old)
            return
    entries = [{"path": "appcast.xml", "mode": "100644", "type": "blob", "content": content}]
    if not beta or not has_stable:
        stable = empty_stable_feed(args.tools, key) if beta else content
        entries.append({"path": "appcast-stable.xml", "mode": "100644", "type": "blob", "content": stable})
    tree_data = {"tree": entries}
    if base_tree:
        tree_data["base_tree"] = base_tree  # Keep the last stable release intact for beta publications.
    tree = api("/git/trees", tree_data)
    commit = api("/git/commits", {"message": f"Publish signed macOS update {version}", "tree": tree["sha"], "parents": [old] if old else []})
    if old:
        # A non-force update rejects a concurrent feed publication.
        api("/git/refs/heads/updates", {"sha": commit["sha"], "force": False}, method="PATCH")
    else:
        api("/git/refs", {"ref": "refs/heads/updates", "sha": commit["sha"]})
    print("Published signed update feeds:", commit["sha"])


if __name__ == "__main__":
    main()
