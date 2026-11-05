#!/usr/bin/env python3
"""Run repository checks with synthetic credentials and isolated stores."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
flutter = os.environ.get("FLUTTER_BIN", "flutter")
dart = str(Path(flutter).with_name("dart")) if "/" in flutter else "dart"


def run(arguments):
    subprocess.run(arguments, cwd=root, check=True)


run([dart, "analyze", "lib", "test"])
run([flutter, "test", "--no-pub", "--reporter", "expanded"])
for check in sorted((root / "test").glob("*checks.dart")):
    run([dart, str(check)])
for check in sorted((root / "tool").glob("workbuddy_*checks.dart")):
    run([dart, str(check)])

if os.uname().sysname == "Darwin":
    with tempfile.TemporaryDirectory(prefix="loongpass-native-checks-") as scratch:
        executable = str(Path(scratch) / "account-file-checks")
        run(["xcrun", "swiftc", "macos/Runner/AccountFile.swift", "tool/account_file_checks.swift", "-o", executable])
        run([executable])
        desktop = str(Path(scratch) / "workbuddy-desktop-checks")
        run(["xcrun", "swiftc", "macos/Runner/AccountFile.swift",
             "macos/Runner/WorkBuddyDesktopTransaction.swift", "tool/workbuddy_desktop_checks.swift", "-o", desktop])
        run([desktop])
