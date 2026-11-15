#!/usr/bin/env python3
"""Generate/check the root distribution manifest from runtime/bridge/package.json."""
import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def repository_manifest(root):
    package = json.loads((root / 'runtime/bridge/package.json').read_text(encoding='utf-8'))

    def relocated(path):
        return './runtime/bridge/' + path.removeprefix('./')

    package['main'] = relocated(package['main'])
    package['exports'] = {name: relocated(path) for name, path in package['exports'].items()}
    package['magpie']['middleware'] = relocated(package['magpie']['middleware'])
    package['files'] = [relocated(path).removeprefix('./') for path in package['files']]
    package['files'].append('docs/magpie-plugin.md')
    return json.dumps(package, ensure_ascii=False, indent=2) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = ROOT / 'package.json'
    expected = repository_manifest(ROOT)
    if args.write:
        target.write_text(expected, encoding='utf-8')
    elif not target.is_file() or target.read_text(encoding='utf-8') != expected:
        parser.exit(1, 'Root package.json is stale; run python3 tool/magpie_package.py --write\n')
    print('Magpie distribution manifest matches runtime/bridge/package.json')


if __name__ == '__main__':
    main()
