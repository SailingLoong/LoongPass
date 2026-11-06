# ZCode activities implementation plan

**Goal:** Add official ZCode authorization, durable accounts and server-offered activity rewards to LoongPass.

**Architecture:** Reuse the existing private AccountDocumentStore and app-lifetime account-owner pattern. Port the OAuth and activity protocol from LoongPort's `official.rs`, `claim.rs`, `claim_protocol.rs` and `session_checks.rs`; keep the legacy native switch candidate disabled. The activity owner alone schedules requests and persists claim intent before submission.

**Tech stack:** Dart/Flutter, existing macOS file bridge, Foundation for observed request context. No new dependency or Keychain integration.

## Design decisions

- The user already delegated implementation choices and requested simple account/reward management. Use direct official OAuth, consistent with the enabled platform adapters; do not expand the disabled encrypted native-switch prototype merely to run network rewards.
- Separate BigModel and Z.AI identities by provider plus official user ID. Save authorization and its observed device context atomically. Reuse an obtained authorization after transient save failures.
- Discover offers from billing preview and explicit `claim_zcode_plan` marketing actions. Never execute arbitrary marketing URLs/actions or infer night/weekend schedules from local time.
- Read balance before claiming, record the previous user-plan IDs durably, and reconcile against a new matching server plan instance. Uncertain submissions remain read-only across restart and reauthorization.
- Retain activity outcomes by plan and server entitlement period, not calendar day. Captcha/service activation requirements pause the affected activity and explain the required user step.
- Display buckets with their official units and remaining amount. Do not combine tokens, requests and credits or substitute original grant amount for remaining amount.
- Native switching remains separately unavailable until a real transaction and client verification are implemented; this addition must not close active ZCode agents.

## Tasks

- [x] Pin OAuth, activity discovery, durable uncertain claim, provider isolation, restart and expiry behavior with synthetic tests.
- [x] Implement fixed-origin transport/OAuth and pure activity/bucket parsing.
- [x] Implement the saved account owner and background timer using AccountDocumentStore.
- [x] Replace the disabled prototype page with official authorization and activity controls; observe existing native version/device context without reading credentials.
- [x] Run focused tests, repository checks and Universal candidate build. Verify official login, saved identity and restart.
- [x] Verify a real activity grant. A second account received a matching new official entitlement after human verification in beta 24. The first account's earlier unknown automatic attempt remains pending and must not be replayed.
- [x] Record actual evidence and remaining live gaps, preserve source provenance, commit/push authorized changes and remove owned intermediate build artifacts. Initial source commit: `12d2edb`; captcha follow-up source: `1063920`. Future usable balance and the first account's unknown result remain separate acceptance gaps.

## Review focus

## Follow-up: observed HTTP 400 / service code 3007

The real native account returned a definite captcha rejection on 2026-11-06. Keep the same account/device and distinguish this rejection from an uncertain POST. Reconcile existing numeric 400/3007 records without resubmitting; records without evidence remain pending.

Reuse LoongPort's official captcha config and Aliyun SDK protocol in a dedicated ephemeral native window. The activity owner requests human verification only for an explicit manual claim after 3007, retains the single-writer lease, and permits at most one submission with a fresh proof. The web view receives only public captcha configuration, never account tokens or device IDs. Automatic jobs pause for verification. Cancellation preserves the rejection and makes no POST. No new login entry, Keychain integration or device rotation.

- [x] Regression tests for definite rejection, restart recovery, cancellation, proof ownership and uncertain verified submissions.
- [x] Native verification window, existing claim button integration, full checks and one Universal build.
- [x] Real human verification, official receipt/amount/expiry reconciliation and restart verification. Official grant is 500,000,000 tokens, effective 2026-11-06 23:00 and expiring 2026-11-09 09:00 (Asia/Shanghai); current remaining balance is not yet available before activation.

- Lost HTTP/save acknowledgements must not cause another claim POST.
- A different provider with the same user ID must not share credentials or receipts.
- A reused plan ID after entitlement expiry must be eligible again, while a captcha or unresolved result must not be retried by timers.
- Missing/malformed server amounts and mixed units remain explicitly unknown/separate.
- Authorization cancellation/disposal must not publish a late result; transient persistence errors reuse the already obtained token.
