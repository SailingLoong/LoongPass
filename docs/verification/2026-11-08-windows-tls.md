# Windows HTTPS SDK security repair

## Finding and repair

The [Dart advisory GHSA-frr6-h895-5pxp](https://github.com/dart-lang/sdk/security/advisories/GHSA-frr6-h895-5pxp)
requires rebuilding affected Windows applications with stable Flutter >=3.47.8 /
Dart >=3.13.7. The [1.0.0 Windows job](https://github.com/SailingLoong/LoongPass/actions/runs/42346394632/job/128324966022)
used Flutter 3.47.1. LoongPass has credential-bearing `dart:io` HTTPS requests.
This establishes affected software, not evidence of intercepted credentials.
macOS is outside this advisory's affected scope.

`pubspec.yaml` now owns the stable Flutter pin (3.47.8) and Dart bounds
(>=3.13.7 <4.0.0); both CI jobs read that pin. Build/package SDK checks and
initial Windows signing/publishing use the same verifier. Windows artifacts
retain the installed SDK metadata. No account, authentication, certificate
validation or reward behavior was changed for this repair.

## Evidence

- Minimal 1.0.1+32 candidate: `04cf41ac5eb32a2da3d6231cc1f5155d05908b71`,
  based on immutable v1.0.0 source without subsequent mainline features.
- [Candidate CI](https://github.com/SailingLoong/LoongPass/actions/runs/42459895082)
  passed with actual Flutter 3.47.8 / Dart 3.13.7: 155 Windows Flutter tests,
  seven synthetic authorization/reward protocol programs, native storage and
  TRAE CNG authorization checks, installer and portable packaging.
- [Mainline integration CI](https://github.com/SailingLoong/LoongPass/actions/runs/42459955840)
  passed: 185 Windows Flutter tests plus Windows build/native/protocol/package
  checks; 267 macOS Flutter tests plus the complete source/protocol/native check
  command. The PR run does not build or package a macOS Universal binary.
- Five SDK-gate tests cover vulnerable/mixed caches, stable boundary/newer
  versions, prerelease/missing evidence, initial publishing refusal and fresh
  Windows SDK bootstrap. Twelve appcast checks and the license bundle check
  passed. Actual installed local Flutter 3.47.1 was refused by the verifier.
- The initial Windows attempt stopped before compilation because the Flutter
  Windows bootstrap prints pub output before JSON. Its regression reproduced
  the failure; initialization now finishes before reading machine metadata.
- Downloaded candidate: source/build metadata, both package SHA-256 values,
  Windows x64 executable version `1.0.1.32`, and absence of native test programs
  were verified. Installer SHA-256:
  `15c021b033ab6c228dee0b98c80144d44d42b2a94a8df8ab6551b62e7bd3fab6`.

## Remaining acceptance and release boundary

No production tag, public release assets or update feed were changed. The
candidate still needs real Windows official login, identity/save/restart
restoration and a permitted reward's official receipt/balance comparison.
Synthetic exchanges do not prove those outcomes. Windows update download,
signature verification and installation also require release acceptance.

SDK metadata records the installed SDK in the clean hosted build; it is not
independent compiler attestation for an arbitrary stale, manually supplied
Release directory. SDK patch provenance follows the official advisory rather
than an independently reproduced compromised-CA attack.

The minimal candidate is Windows-only. Tagging its old release-based source
would also invoke the existing combined macOS publishing job, so publishing
that source is not an approved release procedure. Preserve mainline changes,
including LobsterAI removal, when selecting the final production release.
