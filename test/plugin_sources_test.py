import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import json
import os
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('plugin_sources', ROOT / 'tool/plugin_sources.py')
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)


class SourceIntegrity(unittest.TestCase):
    def test_rejects_declared_package_file_without_a_source_hash(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(ROOT / 'runtime', root / 'runtime')
            shutil.copy(ROOT / 'pubspec.yaml', root)
            lock = root / 'runtime/upstream.lock.json'
            manifest = json.loads(lock.read_text(encoding='utf-8'))
            manifest['files'] = [e for e in manifest['files']
                                 if e['target'] != 'vendor/plugins/minimax/connector-tools.mjs']
            lock.write_text(json.dumps(manifest), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'Unverified package file'):
                sources.verify(root)

    def test_git_line_ending_preferences_do_not_change_provenance(self):
        with patch.dict(os.environ, {
            'GIT_CONFIG_COUNT': '1',
            'GIT_CONFIG_KEY_0': 'core.autocrlf',
            'GIT_CONFIG_VALUE_0': 'true',
        }):
            sources.verify(ROOT)

    def test_patch_must_recover_the_pinned_original(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(ROOT / 'runtime', root / 'runtime')
            shutil.copy(ROOT / 'pubspec.yaml', root)
            lock = root / 'runtime/upstream.lock.json'
            manifest = json.loads(lock.read_text(encoding='utf-8'))
            next(e for e in manifest['files'] if 'upstreamSha256' in e)['upstreamSha256'] = '0' * 64
            lock.write_text(json.dumps(manifest), encoding='utf-8')
            with self.assertRaises(ValueError):
                sources.verify(root)

    def test_rejects_modified_vendor_before_packaging(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(ROOT / 'runtime', root / 'runtime')
            shutil.copy(ROOT / 'pubspec.yaml', root)
            sources.verify(root)
            (root / 'runtime/vendor/plugins/workbuddy/index.mjs').write_text('changed', encoding='utf-8')
            with self.assertRaises(ValueError):
                sources.verify(root)


if __name__ == '__main__':
    unittest.main()
