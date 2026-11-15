# Hourly updates and visible downloads

Native Sparkle and WinSparkle continue to own update checks, package validation,
download/preparation and installation. The shared update contract owns the
3600-second policy, generates bridge constants and mirrors Sparkle's official
Info.plist setting. The Flutter owner consumes native revisions, byte counters
and actual check timestamps. Its one-second transfer sampler schedules no network
work and clears rates between transfers and on completion; unknown totals remain
indeterminate. Settings and the expanded sidebar show percentage and speed.

Sparkle 2.10.1's unattended automatic driver does not forward byte progress to
SPUUserDriver. LoongPass therefore uses its public scheduled custom-user-driver
path: the user driver accepts the download immediately and retains the ready
continuation. Sparkle still performs validation, preparation and installation on
application termination. Its automaticallyChecksForUpdates preference owns the
combined LoongPass switch. A one-time migration preserves an old opt-out of either
checks or downloads; the SDK's separate unattended-driver selection is disabled
without turning off the user's combined preference on subsequent launches.

References: [scheduled driver selection](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUUpdater.m),
[automatic driver's callback boundary](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUAutomaticUpdateDriver.m),
[ready and install-on-termination contract](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUUserDriver.h).
The SDK and its security checks are unmodified.

Platform-order settings now use a dedicated drag-only Forui item, preserving
keyboard and accessibility ordering without an application-open callback.
Navigation click/long-press behavior was explicitly assigned to other work and
is unchanged by this task.

Local verification used Flutter 3.50.0 / Dart 3.14.0 and the pinned Sparkle SDK:

- Complete repository checks passed: 348 Flutter tests, 310 native plugin tests,
  static analysis, generated contract checks and the native adapter checks.
- A new integration probe compiles the actual AppUpdater, Flutter bridge and
  Sparkle, then uses an isolated loopback transfer. It reproduced the missing
  automatic byte callbacks before the fix, and passed afterward on first launch
  and restart. Both historical opt-outs remain off. An empty feed verifies the
  SDK schedules the next check approximately 3,600,000 ms after the last check.
- The loopback payload is inert and has no valid installation signature. The
  probe exits after observing progress and cannot install or replace an app;
  it tests callback integration, not a production signed upgrade.
- Widget cases verify exact MiB/s and KiB/s values, stalls, transfer resets,
  late revisions, unknown totals, native check times and opt-out display.
- Rendered settings were inspected in light/dark themes, narrow windows and
  doubled text size. Mouse sorting, no navigation on click, keyboard ordering
  and persisted platform order passed.

These checks do not assert Windows physical-device behavior, a complete signed
production upgrade or preservation of live account data during installation.
