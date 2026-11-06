#!/usr/bin/env python3
"""Serialize universal macOS builds and reuse the native compiler cache."""
import fcntl
from contextlib import ExitStack
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def verify_app(app):
    for binary in ["Contents/MacOS/LoongPass", "Contents/Frameworks/App.framework/App",
                   "Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"]:
        path = app / binary
        architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(path)], text=True).split()
        if set(architectures) != {"arm64", "x86_64"}:
            raise SystemExit("Expected universal binary: " + binary)
        for architecture in architectures:
            signed = subprocess.run(["codesign", "-d", "--arch", architecture,
                                     "--entitlements", ":-", str(path)], capture_output=True, check=True)
            entitlements = plistlib.loads(signed.stdout) if signed.stdout.strip() else {}
            if entitlements.get("com.apple.security.get-task-allow"):
                raise SystemExit("Release binary permits debugger attachment: " + binary)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def main():
    root = Path(__file__).resolve().parents[1]
    cache = Path.home() / "Library/Caches/LoongPass"
    cache.mkdir(parents=True, exist_ok=True)
    with ExitStack() as locks:
        for path in [Path("/tmp/dot-heavy-build.lock"), cache / "macos-build.lock"]:
            lock = locks.enter_context(path.open("a"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SystemExit("Another build owns the shared or project build lock.")
        if shutil.disk_usage(root).free < 8 * 1024**3:
            raise SystemExit("At least 8 GiB of free space is required for packaging.")
        environment = os.environ.copy()
        environment.pop("CI", None)
        environment.pop("FLUTTER_MACOS_ARM64_ONLY", None)
        environment["CARGO_BUILD_JOBS"] = "2"
        environment.setdefault("CARGO_TARGET_DIR", str(cache / "native-macos"))
        flutter = os.environ.get("FLUTTER_BIN", "flutter")
        version_line = next(line for line in (root / "pubspec.yaml").read_text().splitlines()
                            if line.startswith("version: "))
        version, build = version_line.removeprefix("version: ").split("+")
        result = subprocess.run([flutter, "--suppress-analytics", "build", "macos", "--release",
                                 "--no-pub", "--build-name=" + version,
                                 "--build-number=" + build], cwd=root, env=environment)
        if result.returncode:
            return result.returncode
        app = root / "build/macos/Build/Products/Release/LoongPass.app"
        verify_app(app)
        print("Verified universal macOS app:", app)
        return 0


if __name__ == "__main__":
    sys.exit(main())
