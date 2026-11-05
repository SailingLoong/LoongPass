# Source provenance

LoongPass uses Flutter for its macOS interface and retains the licenses of the following source adaptations.

- ZCode snapshot and switch rules originate from SailingLoong/LoongPort commit `9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6`, source tree `a64268e64b391d856146ea0ddaef027e3d921715`, under MIT. Copyright notices are retained in `LICENSE` and the native module licenses.
- WorkBuddy authorization and claim contracts derive from the MIT LoongPort and workbuddy-switch modules. Attribution is retained in `WORKBUDDY-LICENSE.txt`.
- MiniMax OAuth follows the official MIT MiniMax-AI/minimax-code source at `9a935605956c4500e9cb415f29258e2887e97817`. Regional credit-package fields were checked against the installed official MiniMax Code 3.1.10 client.
- Qoder device authorization and campaign contracts originate from the LoongPort adapters and were checked against official Qoder 0.4.8 / Qoder CN 0.5.3 clients and the public campaign page.
- TRAE CN integration uses independently implemented protocol and storage-format readers checked against official TRAE CN 3.4.11. The repository contains application source and synthetic test material. Installed proprietary client programs and account captures are excluded.
- The macOS runner originates from the Flutter template. Its BSD notice and template image attribution are retained in `THIRD_PARTY_NOTICES.md`, `FLUTTER-TEMPLATE-IMAGES-LICENSE`, and `ICON-PROVENANCE.md`.

The beta 18 source handoff was the starting point for this repository. Current acceptance is maintained in `VALIDATION.md`. Native libraries are built from the included Rust sources and dependency lock files.
