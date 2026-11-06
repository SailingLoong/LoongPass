"""Generate Windows build metadata from the existing release sources."""
import json
from pathlib import Path
import plistlib
import sys
from urllib.parse import urljoin

from release_version import read_release_version

root = Path(__file__).resolve().parents[1]
release = read_release_version(root)
info = plistlib.loads((root / "macos/Runner/Info.plist").read_bytes())
values = {
    "LOONGPASS_RELEASE_NAME": release.name,
    "LOONGPASS_BUILD_NUMBER": release.build,
    "LOONGPASS_UPDATE_PUBLIC_KEY": info["SUPublicEDKey"],
    "LOONGPASS_BETA_FEED": urljoin(info["SUFeedURL"], "appcast-windows.xml"),
    "LOONGPASS_STABLE_FEED": urljoin(info["SUFeedURL"], "appcast-windows-stable.xml"),
}
Path(sys.argv[1]).write_text("#pragma once\n" + "".join(
    f"#define {key} {json.dumps(value)}\n" for key, value in values.items()))
