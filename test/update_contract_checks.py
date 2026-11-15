"""The generator must read Unicode configuration under non-UTF-8 locales."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UpdateContractChecks(unittest.TestCase):
    def test_unicode_configuration_works_with_ascii_default_encoding(self):
        environment = dict(os.environ, PYTHONUTF8='0', LC_ALL='C',
                           PYTHONCOERCECLOCALE='0', PYTHONWARNDEFAULTENCODING='1',
                           PYTHONWARNINGS='error::EncodingWarning')
        result = subprocess.run([sys.executable, 'tool/update_contract.py', '--check'],
                                cwd=ROOT, env=environment, capture_output=True,
                                text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
