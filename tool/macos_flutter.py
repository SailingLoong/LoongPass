"""Use the stable SDK with Flutter's two upstream semantics fixes on macOS."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urljoin, urlparse, unquote

PATCH = Path(__file__).with_name("flutter_macos_semantics.patch")
SOURCE = Path("packages/flutter/lib/src/semantics/semantics.dart")
BASE = "4a891b8710de0c69111347b82dbe1b5e77f072faa3e30436087e5eddc29d3a95"
FIXED = "187c8ceebea7c66826db7f3e8ce4807113e54ba41e6a18e80bf15007a24eb887"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def macos_flutter():
    executable = shutil.which(os.environ.get("FLUTTER_BIN") or "flutter")
    if not executable:
        raise SystemExit("Install the Flutter SDK pinned in pubspec.yaml.")
    sdk = Path(executable).resolve().parents[1]
    source_hash = digest(sdk / SOURCE)
    if source_hash == FIXED:
        return sdk / "bin/flutter"
    if source_hash != BASE:
        raise SystemExit("Unsupported Flutter semantics source. Review the macOS backports before changing SDKs.")

    revision = subprocess.check_output(["git", "-C", sdk, "rev-parse", "HEAD"], text=True).strip()
    cache = Path.home() / "Library/Caches/LoongPass/toolchains"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / f"flutter-{revision[:12]}-{FIXED[:12]}"
    with (cache / "prepare-flutter.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not target.exists():
            with tempfile.TemporaryDirectory(dir=cache) as stage:
                clone = Path(stage) / "sdk"
                subprocess.run(["git", "clone", "--local", "--quiet", "--no-checkout", sdk, clone], check=True)
                subprocess.run(["git", "-C", clone, "checkout", "--quiet", "-B", "stable", revision], check=True)
                subprocess.run(["git", "-C", clone, "remote", "set-url", "origin",
                                "https://github.com/flutter/flutter.git"], check=True)
                subprocess.run(["git", "-C", clone, "apply", PATCH], check=True)
                if digest(clone / SOURCE) != FIXED:
                    raise SystemExit("Flutter backport source verification failed.")
                # APFS copy-on-write keeps the Dart SDK and engine binaries isolated and reusable.
                if (sdk / "bin/cache").is_dir():
                    subprocess.run(["cp", "-cR", sdk / "bin/cache", clone / "bin/cache"], check=True)
                clone.rename(target)
        if digest(target / SOURCE) != FIXED:
            raise SystemExit(f"Modified LoongPass Flutter cache: {target}")
    return target / "bin/flutter"


def resolve_framework(root, flutter, *, refresh=False, environment=None):
    """Make the package consumed by the Dart compiler match the selected SDK."""
    config = root / ".dart_tool/package_config.json"
    expected = Path(flutter).resolve().parents[1] / "packages/flutter"

    def matches():
        if not config.is_file():
            return False
        packages = json.loads(config.read_text())["packages"]
        package = next((p for p in packages if p["name"] == "flutter"), None)
        if not package:
            return False
        uri = urlparse(urljoin(config.as_uri(), package["rootUri"]))
        return uri.scheme == "file" and Path(unquote(uri.path)).resolve() == expected

    if refresh or not matches():
        subprocess.run([flutter, "pub", "get", "--enforce-lockfile"], cwd=root, env=environment, check=True)
    if not matches():
        raise SystemExit("The app's package configuration does not select the verified Flutter framework.")


if __name__ == "__main__":
    print(macos_flutter().parent)
