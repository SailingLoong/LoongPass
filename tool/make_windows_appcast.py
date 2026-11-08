"""Sign the CI Windows installer and its source-matched update feed."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile

from make_appcast import ROOT, SPARKLE, download_prefix, verify_signatures
from release_version import read_release_version
from verify_flutter import verify_toolchain

INSTALLER = "LoongPass-Windows-x64-Setup.exe"
PORTABLE = "LoongPass-Windows-x64.zip"


def executable_version(binary):
    assert binary[:2] == b"MZ"
    pe = struct.unpack_from("<I", binary, 0x3c)[0]
    assert binary[pe:pe + 4] == b"PE\0\0"
    assert struct.unpack_from("<H", binary, pe + 4)[0] == 0x8664
    sections = struct.unpack_from("<H", binary, pe + 6)[0]
    optional_size = struct.unpack_from("<H", binary, pe + 20)[0]
    section_table = pe + 24 + optional_size
    for index in range(sections):
        section = section_table + 40 * index
        if binary[section:section + 8].rstrip(b"\0") != b".rsrc":
            continue
        size, offset = struct.unpack_from("<II", binary, section + 16)
        resources = binary[offset:offset + size]
        marker = b"\xbd\x04\xef\xfe\x00\x00\x01\x00"
        position = resources.find(marker)
        assert position >= 0, "Missing Windows version resource"
        high, low = struct.unpack_from("<II", resources, position + 8)
        return high >> 16, high & 0xffff, low >> 16, low & 0xffff
    raise AssertionError("Missing Windows resources")


def verify_portable(archive, version, build):
    with zipfile.ZipFile(archive) as zipped:
        binary = zipped.read("LoongPass.exe")
        expected = tuple(int(part) for part in version.partition("-")[0].split(".")) + (int(build),)
        assert executable_version(binary) == expected
        assert "WinSparkle.dll" in zipped.namelist()
    return binary


def verify_windows_bundle(directory, version, build, source):
    metadata = json.loads((directory / "WINDOWS-BUILD.json").read_text())
    verify_toolchain(metadata.get("flutterToolchain"))
    assert metadata["source"] == source == (directory / "SOURCE_COMMIT.windows").read_text().strip()
    assert metadata["version"] == version and metadata["build"] == build
    assert metadata["architecture"] == "x64"
    binary = verify_portable(directory / PORTABLE, version, build)
    assert hashlib.sha256(binary).hexdigest() == metadata["executableSHA256"]
    checksums = {}
    for line in (directory / "SHA256SUMS.windows").read_text().splitlines():
        digest, name = line.split("  ", 1)
        checksums[name] = digest
    for name in [INSTALLER, PORTABLE]:
        assert hashlib.sha256((directory / name).read_bytes()).hexdigest() == checksums[name]


def verify_windows_feed(feed, installer, version, build):
    items = ET.parse(feed).getroot().findall("./channel/item")
    assert len(items) == 1
    item = items[0]
    assert item.findtext("{" + SPARKLE + "}version") == build
    assert item.findtext("{" + SPARKLE + "}shortVersionString") == version
    enclosure = item.find("enclosure")
    assert enclosure.get("url") == download_prefix(version) + INSTALLER
    assert enclosure.get("{" + SPARKLE + "}os") == "windows-x64"
    assert int(enclosure.get("length")) == installer.stat().st_size
    signature = enclosure.get("{" + SPARKLE + "}edSignature")
    assert len(base64.b64decode(signature, validate=True)) == 64
    return signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--tools", type=Path, required=True)
    args = parser.parse_args()
    directory = args.directory.resolve()
    version, build = read_release_version(ROOT)
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    verify_windows_bundle(directory, version, build, source)
    key = os.environ.pop("SPARKLE_PRIVATE_KEY").strip()
    installer = directory / INSTALLER
    signature = subprocess.check_output(
        [str(args.tools / "sign_update"), "--ed-key-file", "-", "-p", str(installer)],
        input=key, text=True).strip()
    ET.register_namespace("sparkle", SPARKLE)
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "LoongPass Windows"
    ET.SubElement(channel, "link").text = "https://loongpass.com"
    ET.SubElement(channel, "description").text = "Signed Windows x64 updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "LoongPass " + version
    ET.SubElement(item, "{" + SPARKLE + "}version").text = build
    ET.SubElement(item, "{" + SPARKLE + "}shortVersionString").text = version
    ET.SubElement(item, "description").text = (ROOT / "RELEASE-NOTES.md").read_text()
    ET.SubElement(item, "enclosure", {
        "url": download_prefix(version) + INSTALLER,
        "length": str(installer.stat().st_size),
        "type": "application/octet-stream",
        "{" + SPARKLE + "}os": "windows-x64",
        "{" + SPARKLE + "}edSignature": signature,
        "{" + SPARKLE + "}installerArguments": "/SILENT /CLOSEAPPLICATIONS /RELAUNCH=1",
    })
    feed = directory / "appcast-windows.xml"
    ET.ElementTree(root).write(feed, encoding="utf-8", xml_declaration=True)
    subprocess.run([str(args.tools / "sign_update"), "--ed-key-file", "-", str(feed)],
                   input=key, text=True, check=True)
    verify_windows_feed(feed, installer, version, build)
    verify_signatures(args.tools, feed, installer, signature, key)
    print("Verified signed source-matched Windows installer and feed")


if __name__ == "__main__":
    main()
