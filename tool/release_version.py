"""Derive release and native macOS versions from pubspec.yaml."""
from pathlib import Path
import re
from typing import NamedTuple


class ReleaseVersion(NamedTuple):
    name: str
    build: str

    @property
    def macos_name(self):
        # Apple uses a numeric marketing version; Sparkle orders by build.
        return self.name.partition("-")[0]


def read_release_version(root: Path):
    value = next(line.split(":", 1)[1].strip() for line in (root / "pubspec.yaml").read_text().splitlines()
                 if line.startswith("version:"))
    version = ReleaseVersion(*value.rsplit("+", 1))
    assert re.fullmatch(r"\d+\.\d+\.\d+", version.macos_name), "Expected numeric macOS marketing version"
    assert version.build.isdecimal() and int(version.build) > 0, "Expected positive build number"
    return version
