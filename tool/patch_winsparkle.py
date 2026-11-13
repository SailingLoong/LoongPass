"""Apply the bounded custom-UI bridge to pinned WinSparkle 0.9.4.

Accept only exact original source or the exact complete patched tree. Downloads,
signatures, version/skip policy and installer execution remain SDK-owned.
"""
import argparse
import hashlib
import json
from pathlib import Path

UPSTREAM_COMMIT = "a8986caf620262f7d4581b241436ceaa0cc9370f"
BRIDGE = Path(__file__).resolve().parent / 'winsparkle'
PATCHES = json.loads((BRIDGE / 'patches.json').read_text())
EXTENSIONS = ('inline_ui.h', 'inline_ui.cpp.inc')


def patch_tree(root):
    prepared = {}
    states = set()
    for name, (digest, replacements) in PATCHES.items():
        path = root / name
        content = path.read_bytes()
        original = content
        replacements = [(old, new.replace("@INLINE_API_DECLARATIONS@", (BRIDGE / "inline_api.h").read_text())
                          .replace("@INLINE_API_IMPLEMENTATION@", (BRIDGE / "inline_api.cpp.inc").read_text()))
                         for old, new in replacements]
        for old, new in reversed(replacements):
            if new.encode() in original:
                original = original.replace(new.encode(), old.encode(), 1)
        if hashlib.sha256(original).hexdigest() != digest:
            raise ValueError(f'Pinned WinSparkle source drift: {name}')
        patched = original
        for old, new in replacements:
            if patched.count(old.encode()) != 1:
                raise ValueError(f'Ambiguous patch context: {name}')
            patched = patched.replace(old.encode(), new.encode(), 1)
        if content not in (original, patched):
            raise ValueError(f'Unexpected patch location: {name}')
        states.add(content == patched)
        prepared[path] = patched
    for name in EXTENSIONS:
        target = root / 'src' / name
        expected = (BRIDGE / name).read_bytes()
        if target.exists() and target.read_bytes() != expected:
            raise ValueError(f'Custom UI source drift: {name}')
        states.add(target.exists())
        prepared[target] = expected
    if len(states) != 1:
        raise ValueError('Partially patched WinSparkle tree; use a fresh pinned checkout')
    if True in states:
        return False
    # All original files and additions are validated before the first write.
    for path, value in prepared.items():
        path.write_bytes(value)
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, nargs='?')
    parser.add_argument('--upstream-commit', action='store_true')
    args = parser.parse_args()
    if args.upstream_commit:
        print(UPSTREAM_COMMIT)
    else:
        if args.source is None: parser.error('source directory is required')
        print('Applied WinSparkle custom UI bridge' if patch_tree(args.source) else 'WinSparkle bridge already applied')
