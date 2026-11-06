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
- [ ] Verify a real activity grant. One automatic attempt is pending; repeated official balance checks have not exposed a new entitlement. Do not replay it.
- [x] Record actual evidence and remaining live gaps, preserve source provenance, commit/push authorized changes and remove owned intermediate build artifacts. Main source commit: `12d2edb`; only the real reward receipt remains pending.

## Review focus

- Lost HTTP/save acknowledgements must not cause another claim POST.
- A different provider with the same user ID must not share credentials or receipts.
- A reused plan ID after entitlement expiry must be eligible again, while a captcha or unresolved result must not be retried by timers.
- Missing/malformed server amounts and mixed units remain explicitly unknown/separate.
- Authorization cancellation/disposal must not publish a late result; transient persistence errors reuse the already obtained token.
