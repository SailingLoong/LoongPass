"""Verify stable SDK requirements from pubspec before building or publishing."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def version(value):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?: \(stable\))?", str(value))
    if not match:
        raise ValueError("Expected a stable SDK version, got " + str(value))
    return tuple(map(int, match.groups()))


def verify_toolchain(metadata, root=ROOT):
    if not isinstance(metadata, dict) or metadata.get("channel") != "stable":
        raise ValueError("Release builds require stable Flutter SDK evidence")
    pubspec = (root / "pubspec.yaml").read_text()
    flutter = re.search(r"(?m)^  flutter: ['\"]?(\d+\.\d+\.\d+)['\"]?\s*$", pubspec)
    dart = re.search(r"(?m)^  sdk: ['\"]>=(\d+\.\d+\.\d+) <(\d+\.\d+\.\d+)['\"]\s*$", pubspec)
    if not flutter or not dart:
        raise ValueError("pubspec must declare an exact Flutter version and bounded Dart SDK requirement")
    if version(metadata.get("frameworkVersion")) < version(flutter[1]):
        raise ValueError("Flutter SDK is below the required " + flutter[1])
    if not version(dart[1]) <= version(metadata.get("dartSdkVersion")) < version(dart[2]):
        raise ValueError("Dart SDK does not satisfy the required >=" + dart[1] + " <" + dart[2])


def main():
    flutter = os.environ.get("FLUTTER_BIN") or shutil.which("flutter")
    if not flutter:
        raise ValueError("Flutter SDK is unavailable")
    # Windows bootstrap runs pub on stdout on the first invocation, even with
    # --machine. Complete initialization before requesting the JSON document.
    subprocess.run([flutter, "--version"], stdout=sys.stderr, check=True)
    metadata = json.loads(subprocess.check_output([flutter, "--version", "--machine"], text=True))
    verify_toolchain(metadata)
    if len(sys.argv) > 1:
        output = Path(sys.argv[1])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(metadata, indent=2) + "\n")
    print("Verified stable Flutter " + metadata["frameworkVersion"] + " / Dart " + metadata["dartSdkVersion"])


if __name__ == "__main__":
    main()
