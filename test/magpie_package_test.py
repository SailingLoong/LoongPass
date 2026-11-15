"""Exercise the distributed plugin without building or accessing the desktop app."""
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class MagpiePackageTest(unittest.TestCase):
    def test_package_loads_from_its_tarball_and_excludes_account_and_app_files(self):
        # Catches an incorrect relocated entry, missing middleware, or an overly
        # broad files allowlist shipping desktop/runtime/account material.
        checked = subprocess.run(
            ['python3', 'tool/magpie_package.py', '--check'], cwd=ROOT,
            capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        with tempfile.TemporaryDirectory(prefix='loongpass-package-test-') as scratch:
            stage = Path(scratch) / 'source'
            stage.mkdir()
            for name in ('package.json', 'README.md', 'LICENSE'):
                shutil.copyfile(ROOT / name, stage / name)
            shutil.copytree(ROOT / 'runtime/bridge', stage / 'runtime/bridge')
            (stage / 'docs').mkdir()
            shutil.copyfile(ROOT / 'docs/magpie-plugin.md', stage / 'docs/magpie-plugin.md')
            for name in ('accounts.json', 'runtime/bridge/accounts.json',
                         'runtime/vendor/private.json', 'build/LoongPass.app/private.json'):
                target = stage / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('{"synthetic_private_fixture": true}')
            packed = subprocess.run(
                ['npm', 'pack', '--ignore-scripts', '--json', '--pack-destination', scratch],
                cwd=stage, check=True, capture_output=True, text=True)
            archive = Path(scratch) / json.loads(packed.stdout)[0]['filename']
            extracted = Path(scratch) / 'unpacked'
            with tarfile.open(archive) as package:
                self.assertEqual(set(package.getnames()), {
                    'package/package.json', 'package/README.md', 'package/LICENSE',
                    'package/docs/magpie-plugin.md',
                    'package/runtime/bridge/index.mjs', 'package/runtime/bridge/routing.mjs',
                })
                package.extractall(extracted, filter='data')
            loaded = subprocess.run(['node', '--input-type=module', '-e', '''
                import { readFileSync } from 'node:fs';
                import { resolve } from 'node:path';
                import { pathToFileURL } from 'node:url';
                const p = JSON.parse(readFileSync('package.json', 'utf8'));
                const entry = await import(pathToFileURL(resolve(p.exports['.'])));
                const hooks = await entry.default({});
                const middleware = await import(pathToFileURL(resolve(p.magpie.middleware)));
                const cfg = {}; hooks.config(cfg);
                console.log(JSON.stringify({ provider: hooks.auth.provider,
                  name: cfg.provider.loongpass.name, middleware: typeof middleware.onRequest }));
            '''], cwd=extracted / 'package', check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(loaded.stdout), {
                'provider': 'loongpass', 'name': 'LoongPass', 'middleware': 'function'})


if __name__ == '__main__':
    unittest.main()
