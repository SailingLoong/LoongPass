# Inline native updates

The settings page and sidebar consume one native snapshot. Rendering never checks
feeds or downloads packages. Native startup/scheduling and explicit user actions
are the only update triggers. Fresh installations enable background checks and
advance downloads; existing opt-outs and the independent Beta choice persist.

macOS uses Sparkle 2.10.1's official SPUUserDriver. The background automatic
driver's prepared-install continuation is retained through the delegate (return
true), so one click runs the existing verified installation without fetching
again. Sparkle retains its install-on-quit behavior and any OS authorization.
Manual checks also stay inline. Preparation, ready actions and errors are SDK
callbacks; Dart implements no update transport or installer.

Windows retains pinned WinSparkle 0.9.4 commit
a8986caf620262f7d4581b241436ceaa0cc9370f. Its public API lacks a complete custom UI
contract. The previous automatic-install patch is replaced by the bounded bridge
in tool/winsparkle: original checkers/version-skip policy, downloader, EdDSA
verifier and shared installer execution remain upstream-owned. The bridge joins
its workers, retains a verified prepared payload and publishes callbacks without
creating wxWidgets dialogs. Explicit installation re-verifies the staged file.
The bridge is an upstream integration exemption, not another updater runtime;
remove it if upstream offers an equivalent custom UI API.

Shared channel/field/phase constants originate in tool/update_contract.json.
Generated Dart/Swift/C++ forms are checked in CI. Monotonic native revisions keep
late method replies from overwriting newer download/ready events.

Local source verification used Flutter 3.50.0 / Dart 3.14.0 and the official
Sparkle 2.10.1 SPM binary verified against its upstream package checksum. The
complete source suite passed (305 native protocol tests and 256 Flutter tests),
as did the Sparkle user-driver lifecycle checks and atomic/idempotent SDK patch
checks. The actual user application and all account data were untouched.

The Windows CI integration executable uses the actual patched DLL with synthetic
loopback feeds and ephemeral Ed25519 keys. It checks prepared installation once
without a second feed/payload fetch, no updater windows, invalid signatures,
tampered prepared files, skip-policy/manual override and no-update outcomes. The
installer callback records the action and never runs an installer. Mac universal
and Windows package builds, publication verification and their exact results are
recorded with the delivered Beta artifacts; adding these tests is not itself a
claim that CI or a user's installed-client upgrade has passed.

Real-client upgrades, Windows and Intel physical devices, OS authorization and
production account preservation remain separate acceptance layers. No current
running LoongPass is replaced or restarted by these checks. Temporary fixture
bundles/build intermediates are removed after retaining installable archives and
evidence, so testing does not create duplicate application entries.
