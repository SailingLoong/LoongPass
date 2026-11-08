#!/usr/bin/env python3
"""Run repository checks with synthetic credentials and isolated stores."""
from pathlib import Path
import os
import plistlib
import subprocess
import sys
import tempfile
from plugin_sources import verify as verify_plugin_sources

root = Path(__file__).resolve().parents[1]
flutter = os.environ.get("FLUTTER_BIN", "flutter")
dart = str(Path(flutter).with_name("dart")) if "/" in flutter else "dart"


def run(arguments):
    subprocess.run(arguments, cwd=root, check=True)


for entitlement in (root / "macos/Runner").glob("*.entitlements"):
    assert not plistlib.loads(entitlement.read_bytes()).get("com.apple.security.app-sandbox"), entitlement

verify_plugin_sources(root)
run([sys.executable, 'test/plugin_sources_test.py'])
if not os.environ.get('LOONGPASS_BUN'):
    cache = (Path(os.environ['LOCALAPPDATA']) / 'LoongPass/RuntimeTests'
             if os.name == 'nt' else Path.home() / '.cache/loongpass-runtime-tests')
    os.environ['LOONGPASS_BUN'] = subprocess.check_output(
        [dart, 'tool/prepare_bun.dart', str(cache)], cwd=root, text=True).strip()

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
        client_info = str(Path(scratch) / "workbuddy-client-info-checks")
        run(["xcrun", "swiftc", "macos/Runner/AppDataDirectory.swift", "macos/Runner/AccountFile.swift",
             "macos/Runner/WorkBuddyDesktopTransaction.swift", "tool/workbuddy_client_info_checks.swift", "-o", client_info])
        run([client_info])
        processes = str(Path(scratch) / "workbuddy-process-checks")
        run(["xcrun", "swiftc", "macos/Runner/AppDataDirectory.swift", "macos/Runner/AccountFile.swift",
             "macos/Runner/WorkBuddyDesktopTransaction.swift", "macos/Runner/DesktopClientProcesses.swift",
             "tool/workbuddy_process_checks.swift", "-o", processes])
        run([processes])
        codex_accounts = str(Path(scratch) / "codex-accounts-checks")
        run(["xcrun", "swiftc", "macos/Runner/AppDataDirectory.swift", "macos/Runner/AccountFile.swift",
             "macos/Runner/CodexAccounts.swift", "macos/Runner/CodexLocalSettings.swift", "tool/codex_accounts_checks.swift", "-o", codex_accounts])
        run([codex_accounts])
        for name in ["codex_local_settings", "codex_settings_transaction"]:
            executable = str(Path(scratch) / (name + "-checks"))
            run(["xcrun", "swiftc", "macos/Runner/AppDataDirectory.swift", "macos/Runner/AccountFile.swift",
                 "macos/Runner/CodexAccounts.swift", "macos/Runner/CodexLocalSettings.swift", "tool/" + name + "_checks.swift", "-o", executable])
            run([executable])
        codex_runtime = str(Path(scratch) / "codex-runtime-checks")
        run(["xcrun", "swiftc", "macos/Runner/CodexAppServer.swift", "tool/codex_runtime_checks.swift", "-o", codex_runtime])
        run([codex_runtime])
        codex_activation = str(Path(scratch) / "codex-activation-checks")
        run(["xcrun", "swiftc", "macos/Runner/CodexAppServer.swift", "macos/Runner/CodexActivation.swift",
             "tool/codex_activation_checks.swift", "-o", codex_activation])
        run([codex_activation])
        codex_processes = str(Path(scratch) / "codex-process-checks")
        run(["xcrun", "swiftc", "macos/Runner/DesktopClientProcesses.swift", "macos/Runner/CodexAppServer.swift",
             "macos/Runner/CodexDesktopClient.swift", "tool/codex_process_checks.swift", "-o", codex_processes])
        run([codex_processes])
