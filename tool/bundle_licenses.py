#!/usr/bin/env python3
"""Copy authoritative source notices into app resources before Xcode signs it."""
from pathlib import Path
import shutil
import sys


def bundle_licenses(root: Path, resources: Path):
    target = resources / 'Legal'
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    notices = {root / name for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'SOURCE-ORIGIN.md')}
    notices.update(root.glob('*-LICENSE*'))
    for source in sorted(notices):
        shutil.copy2(source, target / source.name)
    rust = root / 'THIRD_PARTY_RUST'
    if rust.is_dir():
        shutil.copytree(rust, target / rust.name)


if __name__ == '__main__':
    bundle_licenses(Path(sys.argv[1]), Path(sys.argv[2]))
