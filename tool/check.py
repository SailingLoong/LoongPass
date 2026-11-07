#!/usr/bin/env python3
"""Run repository checks with synthetic credentials and isolated stores."""
from pathlib import Path
import os
import plistlib
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
flutter = os.environ.get("FLUTTER_BIN", "flutter")
dart = str(Path(flutter).with_name("dart")) if "/" in flutter else "dart"


def run(arguments):
    subprocess.run(arguments, cwd=root, check=True)


for entitlement in (root / "macos/Runner").glob("*.entitlements"):
    assert not plistlib.loads(entitlement.read_bytes()).get("com.apple.security.app-sandbox"), entitlement

run([dart, "analyze", "lib", "test"])
run([flutter, "test", "--no-pub", "--reporter", "expanded"])
for check in sorted((root / "test").glob("*checks.dart")):
    run([dart, str(check)])
for check in sorted((root / "tool").glob("workbuddy_*checks.dart")):
    run([dart, str(check)])
for check in sorted((root / "test").glob("*checks.py")):
    run([sys.executable, str(check)])

if os.uname().sysname == "Darwin":
    with tempfile.TemporaryDirectory(prefix="loongpass-native-checks-") as scratch:
        zcode_context = str(Path(scratch) / "zcode-context-checks")
        run(["xcrun", "swiftc", "macos/Runner/ZcodeRequestContext.swift", "tool/zcode_request_context_checks.swift", "-o", zcode_context])
        run([zcode_context])
        zcode_captcha = str(Path(scratch) / "zcode-captcha-checks")
        run(["xcrun", "swiftc", "macos/Runner/ZcodeCaptchaWindow.swift", "tool/zcode_captcha_checks.swift", "-o", zcode_captcha])
        run([zcode_captcha])
        executable = str(Path(scratch) / "account-file-checks")
        run(["xcrun", "swiftc", "macos/Runner/AppDataDirectory.swift", "macos/Runner/AccountFile.swift", "tool/account_file_checks.swift", "-o", executable])
        run([executable])
        migration = str(Path(scratch) / "app-data-directory-checks")
        run(["xcrun", "swiftc", "macos/Runner/AppDataDirectory.swift", "macos/Runner/AccountFile.swift",
             "tool/app_data_directory_checks.swift", "-o", migration])
        run([migration])
        desktop = str(Path(scratch) / "workbuddy-desktop-checks")
        run(["xcrun", "swiftc", "macos/Runner/AppDataDirectory.swift", "macos/Runner/AccountFile.swift",
             "macos/Runner/WorkBuddyDesktopTransaction.swift", "tool/workbuddy_desktop_checks.swift", "-o", desktop])
        run([desktop])
        processes = str(Path(scratch) / "workbuddy-process-checks")
        run(["xcrun", "swiftc", "macos/Runner/AppDataDirectory.swift", "macos/Runner/AccountFile.swift",
             "macos/Runner/WorkBuddyDesktopTransaction.swift", "macos/Runner/WorkBuddyProcesses.swift",
             "tool/workbuddy_process_checks.swift", "-o", processes])
        run([processes])
