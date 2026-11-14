#!/usr/bin/env python3
"""Exercise selector changes through the real macOS accessibility bridge."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from build_macos_release import build_lock

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--legacy', action='store_true', help='Confirm the original SDK crash')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This check requires the macOS embedder')
    flutter = os.environ.get('FLUTTER_BIN', 'flutter')
    environment = dict(os.environ, PUB_HOSTED_URL='https://pub.dev')
    lock = (ROOT / 'pubspec.lock').read_text()

    def version(package):
        block = re.search(r'(?ms)^  ' + re.escape(package) + r':\n(.*?)(?=^  \S|\Z)', lock)[1]
        return re.search(r'(?m)^    version: "([^"]+)"', block)[1]

    with build_lock(ROOT), tempfile.TemporaryDirectory(prefix='loongpass-select-semantics-') as scratch:
        fixture = Path(scratch) / 'select_smoke'
        subprocess.run([flutter, 'create', '--empty', '--platforms=macos', '--no-pub',
                        '--org', 'com.sailingloong.smoke', '--project-name', 'select_smoke',
                        str(fixture)], env=environment, check=True)
        (fixture / 'pubspec.yaml').write_text(
            "name: select_smoke\npublish_to: none\nversion: 1.0.0+1\nenvironment:\n"
            "  sdk: '>=3.14.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\n"
            f"  forui: {version('forui')}\n  material_ui: {version('material_ui')}\n"
            "flutter:\n  uses-material-design: true\n")
        shutil.copy2(ROOT / 'pubspec.lock', fixture / 'pubspec.lock')
        shutil.copy2(ROOT / 'lib/select_field_semantics.dart', fixture / 'lib/select_field_semantics.dart')
        source = (ROOT / 'tool/select_semantics_smoke.dart').read_text()
        source = source.replace("'../lib/select_field_semantics.dart'", "'select_field_semantics.dart'")
        (fixture / 'lib/main.dart').write_text(source)
        window = fixture / 'macos/Runner/MainFlutterWindow.swift'
        native = window.read_text()
        needle = 'RegisterGeneratedPlugins(registry: flutterViewController)'
        assert native.count(needle) == 1, 'Unsupported Flutter fixture template'
        # Test-only: force the pinned embedder's bridge without changing OS accessibility settings.
        native = native.replace(needle, needle + '\n    DispatchQueue.main.async {\n'
                                '      flutterViewController.engine.setValue(true, forKey: "semanticsEnabled")\n    }')
        window.write_text(native)
        subprocess.run([flutter, 'pub', 'get', '--offline'], cwd=fixture, env=environment, check=True)
        subprocess.run([flutter, 'build', 'macos', '--release', '--no-pub',
                        '--dart-define=LEGACY_SELECTOR=' + str(args.legacy).lower()],
                       cwd=fixture, env=environment, check=True)
        executable = fixture / 'build/macos/Build/Products/Release/select_smoke.app/Contents/MacOS/select_smoke'
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
        print(result.stdout, end='')
        assert 'Invalid engine handle' not in result.stderr, result.stderr
        if args.legacy:
            assert result.returncode != 0 and 'startEditing' in result.stderr, result.stderr
            print('Confirmed original startEditing crash with native semantics')
        else:
            assert result.returncode == 0, result.stderr
            assert 'NATIVE_SELECTOR_SMOKE_PASS' in result.stdout, result.stderr
            print('Native macOS selector changes passed with accessibility enabled')


if __name__ == '__main__':
    main()
