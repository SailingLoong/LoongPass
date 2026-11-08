# Windows TLS repair implementation plan

> **For agentic workers:** Execute inline with superpowers:executing-plans.

**Goal:** Prepare a source-matched Windows security update and prevent old SDKs
from building or publishing future Windows distributions.

**Architecture:** `pubspec.yaml` owns the Flutter pin and Dart SDK constraint.
The existing Flutter action reads that file; a small Python verifier checks
installed metadata against it, and packaging/publishing share that verifier.

**Tech stack:** Flutter stable, Python standard library, existing Windows CI.
**Spec:** `docs/superpowers/specs/2026-11-08-windows-tls.md`.

## Constraints and review focus

- Flutter >=3.47.8 and Dart >=3.13.7, stable only; compare versions numerically.
- Missing or inconsistent SDK evidence fails closed.
- Preserve locked package versions and existing native security checks.
- Do not claim synthetic protocol checks prove real account receipt.
- Do not publish a tag or update production feeds during candidate preparation.

## Task 1: Patch and verify the release toolchain

- [ ] Add behavioral checks for vulnerable, patched, newer, prerelease and
      malformed installed SDK metadata; observe failure before implementation.
- [ ] Centralize the patched SDK requirements in pubspec and its lockfile;
      implement `tool/verify_flutter.py`, wire both CI jobs and Windows
      packaging/publishing to it, and include Windows protocol checks.
- [ ] Run Python checks, verify the installed old SDK is refused, then build the
      Windows candidate in CI with the patched SDK and inspect logs/metadata.
- [ ] Review the diff and CI evidence, integrate the repair into remote main,
      record actual verification boundaries, and clean task environments after
      safely preserving commits and necessary candidate artifacts.
