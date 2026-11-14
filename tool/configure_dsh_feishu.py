#!/usr/bin/env python3
"""Prepare an initialized DSH profile for its native Teams and Feishu plugins."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "tool/configure_dsh_feishu.mjs"
LIST_OPTIONS = {
    "sender-allowlist": "senderAllowlist",
    "approvers": "approvers",
    "group-allowlist": "groupAllowlist",
}


def profile_patch(name):
    if not name or name in {".", ".."} or re.search(r"[/\\\x00-\x1f\x7f]", name):
        raise ValueError("Use a single DSH profile name")
    home = Path(os.environ.get("DSH_HOME") or Path.home() / ".dsh").expanduser()
    profile = home / "profiles" / name
    patch = profile / "cordis.patch.yml"
    if profile.is_symlink() or any(path.is_symlink() or not path.is_file()
                                   for path in (profile / "package.json", patch)):
        raise ValueError("Use an existing profile initialized by dsh plugin")
    return patch


def find_bun():
    configured = os.environ.get("LOONGPASS_BUN")
    if configured:
        executable = shutil.which(str(Path(configured).expanduser()))
        if executable:
            return executable
        raise ValueError("LOONGPASS_BUN must identify an executable Bun runtime")
    executable = shutil.which("bun")
    if executable:
        return executable
    pin = json.loads((ROOT / "runtime/upstream.lock.json").read_bytes())["bun"]
    version = pin["version"]
    architecture = platform.machine().lower()
    if sys.platform == "darwin":
        name = "bun-darwin-aarch64" if architecture == "arm64" else "bun-darwin-x64"
        caches = [Path.home() / "Library/Caches/LoongPass/native-plugin-runtime",
                  Path.home() / ".cache/loongpass-runtime-tests"]
    elif os.name == "nt":
        name = "bun-windows-aarch64" if architecture == "arm64" else "bun-windows-x64-baseline"
        local = Path(os.environ.get("LOCALAPPDATA", ""))
        caches = [local / "LoongPass/NativePluginRuntime", local / "LoongPass/RuntimeTests"]
    else:
        caches = []
    for cache in caches:
        candidate = cache / "bun" / version / name / ("bun.exe" if os.name == "nt" else "bun")
        if candidate.is_file() and os.access(candidate, os.X_OK):
            try:
                saved = json.loads(candidate.with_name("verified.json").read_bytes())
                digest = hashlib.sha256()
                with candidate.open("rb") as runtime:
                    for chunk in iter(lambda: runtime.read(1 << 20), b""):
                        digest.update(chunk)
                if saved["archive"] != pin["archives"][name + ".zip"] or saved["executable"] != digest.hexdigest():
                    raise ValueError()
            except (OSError, ValueError, KeyError, TypeError):
                raise ValueError("Cached Bun runtime checksum verification failed") from None
            return str(candidate)
    raise ValueError("Use LoongPass's installed Bun runtime, set LOONGPASS_BUN, or put Bun on PATH")


def configure(arguments):
    patch = profile_patch(arguments.profile)
    request = dict(vars(arguments), profileDirectory=str(patch.parent.resolve()))
    result = subprocess.run([find_bun(), str(WORKER)], input=json.dumps(request),
                            capture_output=True, text=True)
    try:
        response = json.loads(result.stdout)
    except ValueError:
        raise ValueError("The Bun profile worker could not complete") from None
    if result.returncode != 0:
        raise ValueError(response.get("error", "The Bun profile worker could not complete"))
    return response["changed"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--profile", required=True, help="Existing dedicated DSH profile name")
    parser.add_argument("--workspace", required=True, help="Existing default working directory")
    parser.add_argument("--model", required=True, help="Explicit PROVIDER/MODEL")
    parser.add_argument("--workspace-roots", dest="workspaceRoots", nargs="*",
                        help="Allowed existing directories for /cd")
    parser.add_argument("--app-id", dest="appId", help="Feishu cli_ application ID")
    for option, key in LIST_OPTIONS.items():
        parser.add_argument("--" + option, dest=key, nargs="*",
                            help="Exact IDs. Omit to preserve existing values, pass no IDs to clear")
    arguments, unknown = parser.parse_known_args()
    if unknown:
        parser.error("Unsupported arguments")
    try:
        changed = configure(arguments)
    except ValueError as error:
        parser.exit(1, f"Profile configuration failed. {error}\n")
    except (OSError, TypeError, KeyError):
        parser.exit(1, "Profile configuration failed. Check profile files and Bun runtime access\n")
    print("Profile configuration updated" if changed else "Profile configuration already matches")


if __name__ == "__main__":
    main()
