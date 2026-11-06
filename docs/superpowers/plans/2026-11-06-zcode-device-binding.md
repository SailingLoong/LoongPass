# ZCode account device binding implementation plan

**Goal:** Reauthorize the requested existing account with one unused imported device, preserve the successful account and old uncertain attempts, and prevent future accounts from silently sharing the native device.

**Architecture:** The existing ZCode account owner keeps the device pool, current binding and binding history in its private atomic account document. A login freezes its selected device and optional expected account identity. Only a matching official authorization result commits a replacement binding. No new Keychain integration, generated IDs or native-client mutation.

**Scope decision:** Follow the user's explicit rebind request using the existing LoongPort pool. Merely editing a request header would leave authorization and account ownership inconsistent; rotating IDs after rejections would not establish a stable binding. One selected ID is used throughout one official flow.

## Tasks

- [x] Add failing owner tests for occupied device rejection, unused pool selection, fixed-device OAuth, expected identity, cancellation/save retry, preservation of old uncertain journals and prevention of retired-device reuse.
- [x] Extend `lib/zcode_activity_accounts.dart` so imported device choice and successful binding publication belong to the account owner. Preserve prior contexts and journals on an explicit replacement; balance reconciliation still precedes any new claim.
- [x] Reuse `lib/zcode_accounts_panel.dart` authorization interaction for existing-account refresh and explicit device rebinding; show binding conflict errors and pool availability without exposing tokens.
- [x] Import the user's existing device pool locally after checking LoongPort ownership metadata and taking the existing LoongPass file lock. Do not mutate LoongPort or the official ZCode client.
- [x] Run focused checks and the repository suite, review the diff, create Universal candidates, and verify the user's selected new accounts with independent devices, official identities, real rewards and restart persistence. The original targeted account's rebind was not completed after the user chose different accounts.
- [x] Push only source/configuration/docs to main, preserve private evidence, and clean owned build intermediates. Shared native cache ownership was explicitly transferred to the next beta 28 build.

## Review focus

- A wrong account returned by the website must not overwrite either saved account.
- Cancellation, expired authorization and failed publication leave the old account and journal intact.
- A new device does not erase the old pending request; it is retained with the old binding. Reusing that device remains disallowed.
- Occupancy is validated before OAuth and again before publication/claim, including case normalization and another owner's update.
- The successful account's grant and device remain unchanged; a local free slot does not assert server eligibility.

## Implementation verification

2026-11-06: `tool/check.py` passed, including static analysis, 187 Flutter tests, the standalone device-binding checks and the existing platform/native checks. Independent read-only review found no outstanding issue. The 20 existing IDs were imported while LoongPass was stopped, under its lifetime file lock, with a private backup and atomic readback. Both account records remained unchanged by import.

At this initial code/test checkpoint, actual replacement authorization, claim receipt and restart verification were pending. Later live results are recorded below and in `ZCODE-ACTIVITIES.md`; the original targeted account's unknown result is still preserved.

## Follow-up: automatic official verification

The user subsequently chose to authorize any of their accounts rather than target the original account, and explicitly requested automatic noninteractive verification with a human window only when needed. A new account was saved on one imported device, received an exact 500,000,000-token official balance after verification, and survived restart without another intent; the two original account cores remained unchanged. The original account's device replacement remains unverified.

Live SDK initialization returned HTTP 200, `Code: Success`, `CaptchaType: TRACELESS`. Calling the documented `startTracelessVerification` returned a nonempty proof with no button click or puzzle interaction; the diagnostic discarded it and sent no claim. Use that official API, as already supported by LoongPort, instead of simulated clicks. Keep verification invocation in the account task owner through an injected bridge; the native window manages only the SDK and human interaction. Try once after a fresh explicit 3007 rejection, preserve paused/unknown records, and do not repeat prompts on later timer ticks. This removes the two-button race without adding another entry point or a parallel claim owner.

Implementation checks: the complete repository check passed (187 Flutter tests plus standalone and native checks). The actual modified native module obtained an official proof without showing a sheet. The official behavior result was T001, not test-mode or QPS failover. Review identified that a slow/no-response SDK must not open the human window; timeout now ends quietly, and the final native/JavaScriptCore cases passed again.

2026-11-07: the beta 27 Universal candidate from `19632db` completed real new-account authorization, independent device assignment, restart recovery, automatic reward and independent official receipt matching. No claim/verification button was clicked. The new account had exactly 500,000,000 token remaining, expiring at 2026-11-09 09:00 Asia/Shanghai. A further restart and automatic startup tick preserved all four accounts' credential/binding/claim hashes. Human-puzzle interaction and Intel runtime remain unverified; no user action is currently required for the completed noninteractive path.
