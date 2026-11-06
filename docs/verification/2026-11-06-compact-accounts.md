# Compact accounts — beta.26 candidate

Source compiled: `8402a797ce76ef1f6d956b8b0bf8436f19c0507a`.
Device-binding baseline retained: `30b69eb37f38ff777c7cdcce7e98cce01f39313d`.

## Behavior

- WorkBuddy, MiniMax CN/global, Qoder CN/global, TRAE CN and ZCode use one shared
  table: account, balance, upcoming expiry, latest confirmed receipt.
- Default 10 rows, 5/10/20 selectable. Search/filter/sort precede pagination.
  App navigation retains each table's presentation state and does not switch accounts.
- Supported client switching appears on hover or keyboard focus; touch surfaces
  keep the control visible. Other account actions live in a dialog updated from
  its account owner, including operation errors.
- Confirmed receipts survive subsequent unknown attempts. WorkBuddy reads its
  existing append-only journal; MiniMax preserves the previous confirmed operation;
  TRAE projects day-keyed history; Qoder preserves confirmation across campaign
  rearming; ZCode projects current and previous device-binding histories.
- Old missing receipt times remain unknown. ZCode submission/entitlement expiry
  and remaining quota never become awarded amounts or receipt timestamps. TRAE
  positive balance deltas are labelled as net increases. Qoder balance scopes
  remain separate.
- Upcoming expiry excludes elapsed batches when projecting the saved snapshot.
  Known ZCode expiry dates remain visible when remaining quota is unknown; zero
  balances do not participate. No view operation refreshes or claims implicitly.

## Verification

Environment: macOS arm64, Dart 3.13.1, existing Flutter/Xcode toolchain.

- `python3 tool/check.py`: passed. Analyzer clean, 200 Flutter tests passed, all
  standalone Dart checks and Swift/native synthetic checks passed.
- Independent read-only branch review: no Critical issues. Two Important expiry
  projection issues were reproduced by failing tests and fixed; the whole suite
  then passed. No deferred minor findings.
- `tool/render_compact_accounts_test.dart`: four synthetic previews passed at
  1024 and 480 logical pixels, light and dark. Desktop rows measured 36 pixels;
  the first ten rows and pagination fit within the tested 720-pixel viewport.
- `python3 tool/build_macos_release.py`: passed under the existing shared build
  locks using the project native cache. App, App.framework and FlutterMacOS
  binaries verified as arm64 + x86_64; strict deep signature verification passed.
- Bundle build number is 26. Flutter normalizes source build-name
  `1.0.0-beta.26` to macOS short version `1.0.0.26`.
- ZIP integrity passed. The package contains the app, source commit and licences.

Candidate: `LoongPass-1.0.0-beta.26-macos-universal.zip`, 23,765,444 bytes.
SHA-256: `97185e9f2ad366a7e8829351930d125bbbaaf597e6fb57faedfcc0d3bc53078a`.
Package, previews, build/check logs and cleanup receipt are retained outside Git
in this chat's artifact directory.

## Boundaries and cleanup

This task did not launch the candidate against real accounts or perform Intel
hardware acceptance. Real device-binding/account work remains owned by the
parallel task; this branch retains its implementation and synthetic regressions,
not a new protocol audit. Magpie and additional client-switch integrations are
outside this approved UI change.

MiniMax's new optional receipt fields are written by this version's account owner;
older strict readers may not accept a store after new receipt metadata is saved.
Use the new version after upgrading rather than alternating with an old beta.

After preserving the candidate and evidence, removed this worktree's build,
.dart_tool, Flutter ephemeral files and generated native library. With explicit
user approval and lock/open-file checks, also removed the shared native cache.
Removed directories totalled 1,650,928 KiB according to `du`; this is directory
usage, not a measured attributable free-disk delta. Source and the feature branch
are retained until integration; no real account data or other checkout was removed.
