#!/usr/bin/env python3
"""Serialize universal macOS builds and reuse the native compiler cache."""
import fcntl
from contextlib import ExitStack, contextmanager
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from release_version import read_release_version
from plugin_sources import verify as verify_plugin_sources


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


@contextmanager
def build_lock(root):
    """Use the shared machine/project locks for every native build."""
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
        yield cache


def main():
    root = Path(__file__).resolve().parents[1]
    verify_plugin_sources(root)
    with build_lock(root) as cache:
        environment = os.environ.copy()
        environment.pop("CI", None)
        environment.pop("FLUTTER_MACOS_ARM64_ONLY", None)
        environment["CARGO_BUILD_JOBS"] = "2"
        environment.setdefault("CARGO_TARGET_DIR", str(cache / "native-macos"))
        flutter = os.environ.get("FLUTTER_BIN", "flutter")
        release = read_release_version(root)
        result = subprocess.run([flutter, "--suppress-analytics", "build", "macos", "--release",
                                 "--no-pub", "--build-name=" + release.macos_name,
                                 "--build-number=" + release.build], cwd=root, env=environment)
        if result.returncode:
            return result.returncode
        app = root / "build/macos/Build/Products/Release/LoongPass.app"
        verify_app(app)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert info["CFBundleShortVersionString"] == release.macos_name
        assert info["CFBundleVersion"] == release.build
        print("Verified universal macOS app:", app)
        return 0


if __name__ == "__main__":
    sys.exit(main())
