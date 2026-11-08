# Source provenance

LoongPass uses Flutter for its desktop interface. Current supplier authorization,
renewal, model and request behavior runs the complete native Magpie community
packages through the pinned Magpie Bun host. The exact source commits, package
versions, original and effective hashes are owned by `runtime/upstream.lock.json`;
the retained MIT licenses and reviewed native changes are documented in
`THIRD_PARTY_NOTICES.md` and `runtime/README.md`. The generic LoongPass bridge,
private account facts, durable reward transactions and desktop activation remain
LoongPass application code.

The following records retain the lineage and notices of earlier adaptations and
the app-specific capabilities that remain. They do not mean that the removed
Dart supplier adapters still own current authorization or inference.

- ZCode snapshot and switch rules originate from SailingLoong/LoongPort commit `9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6`, source tree `a64268e64b391d856146ea0ddaef027e3d921715`, under MIT. Copyright notices are retained in `LICENSE` and the native module licenses.
- WorkBuddy authorization and claim contracts derive from the MIT LoongPort and workbuddy-switch modules. Attribution is retained in `WORKBUDDY-LICENSE.txt`.
- WorkBuddy desktop activation is independently implemented against the session format and file-lock protocol consumed by the official 5.9.3 client. The inspected package SHA-256 was `12a2be53ec7db2943a9958f6986d7807adcf083bd79b307d26706d83750effa7`. Runtime admission checks the vendor signature and declared authentication capabilities. Proprietary client source and real account data are excluded from this repository. Static compatibility and synthetic transaction checks are recorded separately from actual account-switch acceptance in `VALIDATION.md`.
- MiniMax OAuth follows the official MIT MiniMax-AI/minimax-code source at `9a935605956c4500e9cb415f29258e2887e97817`. Regional credit-package fields were checked against the installed official MiniMax Code 3.1.10 client.
- Qoder device authorization and campaign contracts originate from the LoongPort adapters and were checked against official Qoder 0.4.8 / Qoder CN 0.5.3 clients and the public campaign page.
- TRAE CN integration uses independently implemented protocol and storage-format readers checked against official TRAE CN 3.4.11. The repository contains application source and synthetic test material. Installed proprietary client programs and account captures are excluded.
- The Loomy reward adapter follows the MIT [iJetLi/dsh-providers-hub](https://github.com/iJetLi/dsh-providers-hub/tree/a5b3cd10dd49c27064c1270da205ca19a5e77d0a) protocol sources (SMS, sessions, daily gift pool and balance fields), cross-checked against [Lamp-Guide](https://github.com/LAGcomcom/Lamp-Guide/tree/7ce6cef347d564cf0caf99bc1c7f8e31d657c93c). The original MIT notices are retained in `REWARDS-LICENSE.txt`. Shared storage, task ownership and intent journaling are implemented in LoongPass. Real-account verification remains separate; no account captures or upstream gateway binaries are included.
- The macOS runner originates from the Flutter template. Its BSD notice and template image attribution are retained in `THIRD_PARTY_NOTICES.md`, `FLUTTER-TEMPLATE-IMAGES-LICENSE`, and `ICON-PROVENANCE.md`.

The beta 18 source handoff was the starting point for this repository. Current acceptance is maintained in `VALIDATION.md`. Native libraries are built from the included Rust sources and dependency lock files.
