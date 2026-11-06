"""Exercise the actual Xcode resource phase with a synthetic app and notices."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin', 'macOS Xcode resource build phase')
class LicenseBundleChecks(unittest.TestCase):
    def test_source_notices_follow_the_app_archive_and_new_licenses_are_discovered(self):
        project = json.loads(subprocess.check_output([
            'plutil', '-convert', 'json', '-o', '-', str(ROOT / 'macos/Runner.xcodeproj/project.pbxproj')
        ]))
        objects = project['objects']
        runner = next(value for value in objects.values()
                      if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'Runner')
        phase = next((objects[key] for key in runner['buildPhases']
                      if objects[key].get('name') == 'Bundle source notices'), None)
        self.assertIsNotNone(phase, 'App target must bundle its source notices before codesigning')
        with tempfile.TemporaryDirectory(prefix='loongpass-license-check-') as directory:
            root = Path(directory)
            (root / 'macos').mkdir()
            (root / 'tool').mkdir()
            shutil.copy2(ROOT / 'tool/bundle_licenses.py', root / 'tool/bundle_licenses.py')
            (root / 'LICENSE').write_text('Application notice')
            (root / 'REWARDS-LICENSE.txt').write_text('Synthetic protocol copyright and license')
            (root / 'THIRD_PARTY_NOTICES.md').write_text('Third party notices')
            (root / 'SOURCE-ORIGIN.md').write_text('Source provenance')
            rust = root / 'THIRD_PARTY_RUST' / 'synthetic-crate'
            rust.mkdir(parents=True)
            (rust / 'LICENSE-MIT').write_text('Synthetic Rust notice')
            output = root / 'build'
            resources = output / 'LoongPass.app/Contents/Resources'
            environment = dict(os.environ, SRCROOT=str(root / 'macos'),
                               TARGET_BUILD_DIR=str(output),
                               UNLOCALIZED_RESOURCES_FOLDER_PATH='LoongPass.app/Contents/Resources')
            subprocess.run(['/bin/sh', '-c', phase['shellScript']], env=environment, check=True)
            (root / 'FUTURE-LICENSE').write_text('New notice without editing build code')
            subprocess.run(['/bin/sh', '-c', phase['shellScript']], env=environment, check=True)
            archive = root / 'app.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                for file in resources.rglob('*'):
                    if file.is_file():
                        zipped.write(file, file.relative_to(output))
            with zipfile.ZipFile(archive) as zipped:
                prefix = 'LoongPass.app/Contents/Resources/Legal/'
                self.assertEqual(zipped.read(prefix + 'REWARDS-LICENSE.txt'), b'Synthetic protocol copyright and license')
                self.assertEqual(zipped.read(prefix + 'FUTURE-LICENSE'), b'New notice without editing build code')
                self.assertEqual(zipped.read(prefix + 'THIRD_PARTY_RUST/synthetic-crate/LICENSE-MIT'), b'Synthetic Rust notice')


if __name__ == '__main__':
    unittest.main()
