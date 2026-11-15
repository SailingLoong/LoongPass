#!/usr/bin/env python3
"""Exercise the real native updater and SDK against an isolated loopback feed."""
import base64
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    flutter = Path(os.environ.get('FLUTTER_BIN') or shutil.which('flutter')).resolve()
    flutter_framework = flutter.parents[1] / 'bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64'
    sparkle = Path(os.environ.get('SPARKLE_FRAMEWORK_ROOT', ROOT / 'build/macos/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'))
    identifier = 'com.sailingloong.smoke.update-' + uuid.uuid4().hex
    payload = bytes(2 * 1024 * 1024)
    signature = base64.b64encode(bytes(64)).decode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.path == '/appcast.xml':
                item = (f'<item><title>2.0</title>'
                        f'<sparkle:version>2</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString>'
                        f'<enclosure url="http://127.0.0.1:{self.server.server_port}/payload.zip" length="{len(payload)}" '
                        f'type="application/octet-stream" sparkle:edSignature="{signature}"/>'
                        f'</item>') if self.server.offer else ''
                data = (f'<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                        f'<title>Native update fixture</title>{item}</channel></rss>').encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(data)
            else:
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                try:
                    for offset in range(0, len(payload), 131072):
                        self.wfile.write(payload[offset:offset + 131072])
                        self.wfile.flush()
                        time.sleep(0.08)
                except (BrokenPipeError, ConnectionResetError):
                    pass

    with tempfile.TemporaryDirectory(prefix='loongpass-update-integration-') as scratch:
        contents = Path(scratch) / 'NativeUpdateFixture.app/Contents'
        executable = contents / 'MacOS/NativeUpdateFixture'
        executable.parent.mkdir(parents=True)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        info = plistlib.loads((ROOT / 'macos/Runner/Info.plist').read_bytes())
        info.update(CFBundleIdentifier=identifier, CFBundleName='NativeUpdateFixture',
                    CFBundleExecutable=executable.name, CFBundleVersion='1', CFBundleShortVersionString='1.0',
                    SUFeedURL=f'http://127.0.0.1:{server.server_port}/appcast.xml',
                    LoongPassStableFeedURL=f'http://127.0.0.1:{server.server_port}/appcast.xml',
                    SUPublicEDKey=base64.b64encode(bytes(32)).decode(),
                    SURequireSignedFeed=False, LSUIElement=True,
                    NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
        # The inert payload has no valid signature and can never install. This
        # test ends after observing actual download callbacks, before extraction.
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        try:
            subprocess.run(['xcrun', 'swiftc', '-F', str(flutter_framework), '-F', str(sparkle),
                            '-framework', 'FlutterMacOS', '-framework', 'Sparkle',
                            '-Xlinker', '-rpath', '-Xlinker', str(flutter_framework),
                            '-Xlinker', '-rpath', '-Xlinker', str(sparkle),
                            'macos/Runner/UpdateContract.swift', 'macos/Runner/AppUpdateUserDriver.swift',
                            'macos/Runner/AppUpdater.swift', 'tool/app_update_integration_checks.swift',
                            '-o', str(executable)], cwd=ROOT, check=True)
            for mode in ['fresh', 'restart', 'checks-off', 'downloads-off', 'schedule']:
                server.offer = mode != 'schedule'
                subprocess.run([str(executable), mode], check=True, timeout=15)
        finally:
            server.shutdown()
            subprocess.run(['defaults', 'delete', identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(Path.home() / 'Library/Caches' / identifier, ignore_errors=True)


if __name__ == '__main__':
    main()
