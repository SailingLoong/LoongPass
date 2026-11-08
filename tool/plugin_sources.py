#!/usr/bin/env python3
"""Verify the source lock, or explicitly sync it from fixed local Git objects."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def verify(root):
    runtime = root / 'runtime'
    manifest = json.loads((runtime / 'upstream.lock.json').read_text())
    if manifest['schema'] != 1:
        raise ValueError('Unknown runtime manifest')
    for entry in manifest['files']:
        path = runtime / entry['target']
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError('Modified upstream source: ' + entry['target'])
    for package in manifest['packages']:
        directory = runtime / package['target']
        meta = json.loads((directory / 'package.json').read_text())
        if package['spec'] != meta['name'] + '@' + meta['version']:
            raise ValueError('Package pin differs from metadata')
        for path in meta['files']:
            if not (directory / path).is_file():
                raise ValueError('Missing package file: ' + path)
    assets = re.findall(r'^    - (.+)$', (root / 'pubspec.yaml').read_text(), re.M)
    for path in [runtime / 'upstream.lock.json',
                 *[runtime / p['target'] for p in manifest['files']],
                 *[runtime / p for p in manifest['localFiles']]]:
        relative = path.relative_to(root).as_posix()
        parent = path.parent.relative_to(root).as_posix() + '/'
        if not path.is_file() or relative not in assets and parent not in assets:
            raise ValueError('Unpackaged runtime file: ' + relative)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sync', action='store_true')
    parser.add_argument('--magpie', type=Path)
    parser.add_argument('--plugins', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.sync:
        manifest = json.loads((root / 'runtime/upstream.lock.json').read_text())
        for entry in manifest['files']:
            source = manifest['sources'][entry['source']]
            repo = getattr(args, entry['source'])
            if repo is None:
                parser.error('--sync requires --magpie and --plugins checkouts')
            data = subprocess.check_output(['git', '-C', str(repo), 'show', source['commit'] + ':' + entry['path']])
            if hashlib.sha256(data).hexdigest() != entry['sha256']:
                raise ValueError('Pinned source hash differs: ' + entry['path'])
            path = root / 'runtime' / entry['target']
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    manifest = verify(root)
    print('Verified', len(manifest['files']), 'pinned files and', len(manifest['packages']), 'complete packages')


if __name__ == '__main__':
    main()
