#!/usr/bin/env python3
"""Install the pinned Feishu channel through DSH's native plugin manager."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = ROOT / "integrations" / "dsh-feishu"


def run(dsh, profile, *arguments):
    subprocess.run([dsh, "plugin", "--profile", profile, *arguments], check=True)


def verify_files(directory, expected):
    for name, digest in expected.items():
        path = directory / name
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != digest:
            raise ValueError(f"Unexpected upstream content in {name}")


def install(dsh, profile):
    if not profile or profile in {".", "..", "node_modules"} or any(
        separator in profile for separator in ("/", "\\")
    ):
        raise ValueError("Use a single DSH profile name")
    source = json.loads((INTEGRATION / "upstream.json").read_text())
    if not source["originalFiles"] or source["originalFiles"].keys() != source["patchedFiles"].keys():
        raise ValueError("Incomplete upstream verification manifest")
    verify_files(INTEGRATION, {"dsh-lark-channel.patch": source["patchSha256"]})
    profile_dir = Path(os.environ.get("DSH_HOME") or Path.home() / ".dsh") / "profiles" / profile
    package = profile_dir / "package.json"
    if package.exists():
        existing = json.loads(package.read_text())
        dependencies = existing.get("dependencies", {})
        installed = dependencies.get(source["package"])
        if installed is not None and installed != source["version"]:
            raise ValueError("This profile uses another channel version. Choose a dedicated profile.")

    profile_dir.mkdir(parents=True, exist_ok=True)
    policy = profile_dir / "pnpm-workspace.yaml"
    if not policy.exists():
        # Match the channel's native provisioner. Dependency build scripts are skipped.
        with policy.open("x") as output:
            output.write("packages:\n  - .\nnodeLinker: hoisted\nautoInstallPeers: false\n"
                         "strictDepBuilds: false\nallowBuilds:\n  protobufjs: false\n")

    spec = f"{source['package']}@{source['version']}"
    run(dsh, profile, "add", "--save-exact", spec)
    with tempfile.TemporaryDirectory(prefix="loongpass-dsh-feishu-") as temporary:
        editable = Path(temporary) / "channel"
        run(dsh, profile, "patch", spec, "--ignore-existing", "--edit-dir", str(editable))
        verify_files(editable, source["originalFiles"])
        subprocess.run(
            ["git", "apply", "--check", str(INTEGRATION / "dsh-lark-channel.patch")],
            cwd=editable, check=True,
        )
        subprocess.run(
            ["git", "apply", str(INTEGRATION / "dsh-lark-channel.patch")],
            cwd=editable, check=True,
        )
        verify_files(editable, source["patchedFiles"])
        run(dsh, profile, "patch-commit", "--patches-dir", "patches", str(editable))
    verify_files(profile_dir / "node_modules" / source["package"], source["patchedFiles"])
    print(f"Installed {spec} with the LoongPass compatibility patch in {profile_dir}")
    print("Configure this profile before starting its Feishu channel.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="loongpass-feishu")
    parser.add_argument("--dsh", help="Path to the official DSH executable")
    arguments = parser.parse_args()
    dsh = arguments.dsh or shutil.which("dsh")
    desktop_cli = Path("/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh")
    if not dsh and desktop_cli.is_file():
        dsh = str(desktop_cli)
    if not dsh:
        parser.error("Install DeepSeek Harness or pass --dsh")
    try:
        install(dsh, arguments.profile)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Feishu channel installation failed. {error}\n")


if __name__ == "__main__":
    main()
