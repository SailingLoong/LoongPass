#!/usr/bin/env python3
"""Publish the verified release feed to an isolated public metadata branch."""
import base64
import json
from pathlib import Path
import subprocess
import sys
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


def main():
    # Preserve line endings: the signature covers the feed's exact bytes.
    content = Path(sys.argv[1]).read_bytes().decode("utf-8")
    version = int(ET.fromstring(content).findtext(VERSION))
    refs = api("/git/matching-refs/heads/updates")
    old = next((ref["object"]["sha"] for ref in refs if ref["ref"] == "refs/heads/updates"), None)
    if old:
        previous = api("/contents/appcast.xml?ref=" + old)
        old_content = base64.b64decode(previous["content"]).decode()
        if old_content == content:
            print("Signed update feed is already published:", old)
            return
        old_version = int(ET.fromstring(old_content).findtext(VERSION))
        if old_version >= version:
            raise RuntimeError("Refusing to replace an equal or newer update feed")
    tree = api("/git/trees", {"tree": [{"path": "appcast.xml", "mode": "100644", "type": "blob", "content": content}]})
    commit = api("/git/commits", {"message": f"Publish signed macOS update {version}", "tree": tree["sha"], "parents": [old] if old else []})
    if old:
        # A non-force update rejects a concurrent feed publication.
        api("/git/refs/heads/updates", {"sha": commit["sha"], "force": False}, method="PATCH")
    else:
        api("/git/refs", {"ref": "refs/heads/updates", "sha": commit["sha"]})
    print("Published signed update feed:", commit["sha"])


if __name__ == "__main__":
    main()
