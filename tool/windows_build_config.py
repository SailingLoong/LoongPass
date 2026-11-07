"""Generate Windows build metadata from the existing release sources."""
import json
import hashlib
from pathlib import Path
import plistlib
import sys
from urllib.parse import urljoin

from release_version import read_release_version
from patch_winsparkle import UPSTREAM_COMMIT

root = Path(__file__).resolve().parents[1]
if len(sys.argv) > 2:
    sdk = Path(sys.argv[2])
    provenance = json.loads((sdk / 'provenance.json').read_text())
    assert provenance['commit'] == UPSTREAM_COMMIT, 'Unexpected WinSparkle source'
    assert provenance['platform'] == 'x64' and provenance['configuration'] == 'Release'
    assert provenance['extension'] == 'win_sparkle_check_update_without_ui_and_install'
    for field, name in [('patchSHA256', 'patch_winsparkle.py'), ('buildScriptSHA256', 'build_winsparkle.ps1')]:
        assert provenance[field] == hashlib.sha256((root / 'tool' / name).read_bytes()).hexdigest(), 'Rebuild WinSparkle SDK for current inputs'
    for name, digest in provenance['files'].items():
        path = (sdk / name).resolve()
        assert path.is_relative_to(sdk.resolve()), 'Invalid SDK provenance path'
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'WinSparkle SDK content mismatch'
    assert {'include/winsparkle.h', 'x64/Release/WinSparkle.dll', 'x64/Release/WinSparkle.lib', 'COPYING'} <= provenance['files'].keys()
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
