import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('plugin_sources', ROOT / 'tool/plugin_sources.py')
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)


class SourceIntegrity(unittest.TestCase):
    def test_rejects_modified_vendor_before_packaging(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(ROOT / 'runtime', root / 'runtime')
            shutil.copy(ROOT / 'pubspec.yaml', root)
            sources.verify(root)
            (root / 'runtime/vendor/plugins/workbuddy/index.mjs').write_text('changed')
            with self.assertRaises(ValueError):
                sources.verify(root)


if __name__ == '__main__':
    unittest.main()
