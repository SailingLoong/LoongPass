# Icon provenance

## LoongPass application icon

The LoongPass mark uses three application tiles and a check on a blue rounded
square. Its only design source is `assets/branding/loongpass.svg`, based on the
Logo concept created for this project on 2026-11-08.

`tool/generate_branding.py` exports the sidebar/README PNG, every macOS AppIcon
size and the Windows ICO from that SVG. The macOS exports add only transparent
canvas padding. The website mirrors the same SVG and PNG for its header,
footer, favicon and sharing preview; it has no separate drawing. See
`assets/branding/README.md` for generation and consistency checks.

## Supported application icons

`assets/app_icons/` contains the supported products' original icons, converted
to PNG with a maximum dimension of 128 pixels and their aspect ratio preserved.
The artwork is not recolored or redrawn. Sources were checked on 2026-11-07.

| Asset | Official source |
| --- | --- |
| `workbuddy.png` | [WorkBuddy](https://www.workbuddy.cn/), official macOS app 5.9.3, `Contents/Resources/icon.icns` |
| `zcode.png` | [ZCode](https://zcode.z.ai/), official macOS app 3.17.2 (3.17.2.9661), `Contents/Resources/icon.icns` |
| `qoder.png` | [Qoder](https://qoder.com/), official macOS app 0.4.8, `Contents/Resources/icon.icns` |
| `minimax.png` | [MiniMax Code](https://agent.minimax.io/), official macOS app 3.1.10 (3.1.10.206), `Contents/Resources/icon.icns` |
| `trae.png` | [TRAE CN](https://www.trae.cn/), official macOS app 3.4.11, `Contents/Resources/Trae CN.icns` |
| `loomy.png` | [Official Loomy website icon](https://loomy.xunfei.cn/icon.png?5f7e7b8be5d4c76b), retrieved through its [image endpoint](https://loomy.xunfei.cn/_next/image?url=%2Ficon.png&w=128&q=75) |
| `codex.png` | Official ChatGPT/Codex macOS app 26.1103.31037, `Contents/Resources/icon-codex-dark-color.png` |

These product icons and trademarks belong to their respective owners and are
used to identify the applications managed by LoongPass. They are not licensed
under LoongPass's MIT license. Domestic and international entries share the
product artwork; region badges are rendered separately from platform metadata.
