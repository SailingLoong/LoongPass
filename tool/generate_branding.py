#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["cairosvg>=2.7", "pillow>=11"]
# ///
"""Export every LoongPass brand asset from assets/branding/loongpass.svg."""
import argparse
import hashlib
from io import BytesIO
from pathlib import Path
import re

import cairosvg
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/branding/loongpass.svg"


def png(image):
    output = BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--website-root", type=Path,
                        help="Also sync the website's assets and cache versions")
    parser.add_argument("--check", action="store_true",
                        help="Verify exports without writing files")
    args = parser.parse_args()
    source = SOURCE.read_bytes()
    mark = Image.open(BytesIO(cairosvg.svg2png(
        bytestring=source, output_width=1024, output_height=1024))).convert("RGBA")
    outputs = {ROOT / "assets/branding/loongpass.png": png(mark.resize(
        (512, 512), Image.Resampling.LANCZOS))}

    # macOS supplies a full icon canvas; retain its conventional transparent inset.
    mac = Image.new("RGBA", (1024, 1024))
    mac.alpha_composite(mark.resize((824, 824), Image.Resampling.LANCZOS), (100, 100))
    for size in (16, 32, 64, 128, 256, 512, 1024):
        path = ROOT / f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png"
        outputs[path] = png(mac.resize((size, size), Image.Resampling.LANCZOS))

    ico = BytesIO()
    mark.save(ico, format="ICO", sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    outputs[ROOT / "windows/runner/resources/app_icon.ico"] = ico.getvalue()

    if args.website_root:
        public = args.website_root.resolve() / "public"
        html_path = public / "index.html"
        html = html_path.read_text()
        version = hashlib.sha256(source).hexdigest()[:12]
        html = re.sub(r"(/icon\.(?:svg|png))(?:\?v=[a-f0-9]+)?",
                      lambda match: f"{match[1]}?v={version}", html)
        outputs[public / "icon.svg"] = source
        outputs[public / "icon.png"] = outputs[ROOT / "assets/branding/loongpass.png"]
        outputs[html_path] = html.encode()

    stale = []
    for path, data in outputs.items():
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                stale.append(str(path))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if stale:
        raise SystemExit("Regenerate brand assets:\n" + "\n".join(stale))
    print(f"{'Verified' if args.check else 'Exported'} {len(outputs)} assets from {SOURCE}")


if __name__ == "__main__":
    main()
