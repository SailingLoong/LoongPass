# ZCode account device binding implementation plan

**Goal:** Reauthorize the requested existing account with one unused imported device, preserve the successful account and old uncertain attempts, and prevent future accounts from silently sharing the native device.

**Architecture:** The existing ZCode account owner keeps the device pool, current binding and binding history in its private atomic account document. A login freezes its selected device and optional expected account identity. Only a matching official authorization result commits a replacement binding. No new Keychain integration, generated IDs or native-client mutation.

**Scope decision:** Follow the user's explicit rebind request using the existing LoongPort pool. Merely editing a request header would leave authorization and account ownership inconsistent; rotating IDs after rejections would not establish a stable binding. One selected ID is used throughout one official flow.

## Tasks

- [x] Add failing owner tests for occupied device rejection, unused pool selection, fixed-device OAuth, expected identity, cancellation/save retry, preservation of old uncertain journals and prevention of retired-device reuse.
- [x] Extend `lib/zcode_activity_accounts.dart` so imported device choice and successful binding publication belong to the account owner. Preserve prior contexts and journals on an explicit replacement; balance reconciliation still precedes any new claim.
- [x] Reuse `lib/zcode_accounts_panel.dart` authorization interaction for existing-account refresh and explicit device rebinding; show binding conflict errors and pool availability without exposing tokens.
- [x] Import the user's existing device pool locally after checking LoongPort ownership metadata and taking the existing LoongPass file lock. Do not mutate LoongPort or the official ZCode client.
- [ ] Run focused checks and the repository suite, review the diff, create one Universal candidate, and verify the requested account's official reauthorization, different device, identity, new claim result and restart persistence.
- [ ] Push only source/configuration/docs to main, preserve private evidence, and clean owned build intermediates.

## Review focus

- A wrong account returned by the website must not overwrite either saved account.
- Cancellation, expired authorization and failed publication leave the old account and journal intact.
- A new device does not erase the old pending request; it is retained with the old binding. Reusing that device remains disallowed.
- Occupancy is validated before OAuth and again before publication/claim, including case normalization and another owner's update.
- The successful account's grant and device remain unchanged; a local free slot does not assert server eligibility.

## Implementation verification

2026-11-06: `tool/check.py` passed, including static analysis, 187 Flutter tests, the standalone device-binding checks and the existing platform/native checks. Independent read-only review found no outstanding issue. The 20 existing IDs were imported while LoongPass was stopped, under its lifetime file lock, with a private backup and atomic readback. Both account records remained unchanged by import.

Actual replacement authorization, claim receipt and restart verification remain pending. This code/test checkpoint does not establish that the server has accepted a different binding or granted another reward.
