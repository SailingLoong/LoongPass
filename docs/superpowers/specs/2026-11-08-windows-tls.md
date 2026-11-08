# Windows TLS security repair

Windows 1.0.0 was compiled with Flutter 3.47.1 and uses credential-bearing
`dart:io` HTTPS requests. GHSA-frr6-h895-5pxp requires rebuilding with stable
Flutter >=3.47.8 / Dart >=3.13.7. macOS is outside this advisory's scope.
There is no evidence in this investigation of credential interception.

Use the existing stable Flutter build and publishing pipeline. Pin Flutter in
`pubspec.yaml`, enforce the patched Dart minimum, verify the actual SDK before
building/packaging, and preserve that evidence in Windows build metadata.
Checks must reject vulnerable, prerelease, missing and inconsistent versions.
Keep authentication and certificate validation behavior unchanged.

Prepare 1.0.1+32 from the immutable v1.0.0 source, without unrelated mainline
features. Replacing same-version assets would bypass installed users' update
ordering and invalidate existing checksums, so use a higher release version.
An SDK-only dependency update without rebuilt binaries cannot fix installed apps.
Run existing synthetic authorization/reward checks on Windows. Real official
login, account restoration and reward receipt require separate device evidence.
Keep the public release/feed unchanged until the candidate is reviewed.
